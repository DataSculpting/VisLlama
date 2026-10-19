# Load synthetic ELF runtime/driver libraries through the production helper.
# These ABI/identity/privacy checks do not validate a CUDA GPU or llama.cpp build.
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use JSON::PP qw(decode_json);
use VisLlama::Platform::CUDA ();
use VisLlama::GPUIsolation ();
use VisLlama::Builds ();
use VisLlama::Context qw(%CFG);
use VisLlama::Util ();
plan skip_all=>'Linux native ELF helper' unless $^O eq 'linux';
my $root=tempdir(CLEANUP=>1);mkdir "$root/bin";mkdir "$root/lib";
my $source="$RealBin/fixtures/linux/cuda-stub.c";
for my $job (["$root/lib/libcudart.so.12"], ["$root/lib/libcuda.so.1",'-DDRIVER']) {
 my $out=VisLlama::Util::capture_command('cc','-shared','-fPIC',$source,@{$job}[1..$#$job],'-o',$job->[0]);
 die "Fixture compiler failure: $out" if $?;
}
my $out=VisLlama::Util::capture_command('cc','-shared','-fPIC',"$RealBin/fixtures/linux/backend-stub.c",'-L'.$root.'/lib','-l:libcudart.so.12','-Wl,-rpath,$ORIGIN','-o',"$root/lib/libggml-cuda.so");
die "Backend fixture compile failed: $out" if $?;
my $exe="$root/bin/llama-server";
$out=VisLlama::Util::capture_command('cc','-DSERVER',$source,'-L'.$root.'/lib','-l:libggml-cuda.so','-Wl,-rpath,$ORIGIN/../lib','-o',$exe);
die "Executable fixture compile failed: $out" if $?;
local $ENV{LD_LIBRARY_PATH}="$root/lib";
my ($backend,$runtime)=VisLlama::Platform::CUDA::linkage($exe);
is($backend,"$root/lib/libggml-cuda.so",'Real executable loader resolves its backend');
is($runtime,"$root/lib/libcudart.so.12",'Real backend dependency resolves its CUDA runtime');
my $helper;
{no warnings 'redefine';local *VisLlama::Paths::app_base_dir=sub {$root};$helper=VisLlama::Platform::CUDA::helper();}
ok(-x $helper,'Private native helper built without CUDA SDK');
# LD_LIBRARY_PATH must be set before starting a native process, not dlopen-time.
my $raw=VisLlama::Util::capture_command_stdout($helper,"$root/lib/libggml-cuda.so");is($?,0,'Synthetic runtime/driver probe succeeds');
my $rows=decode_json($raw);
is($rows->[0]{bus},'0000:43:00.0','Original runtime ordinal retains its PCI bus');
is($rows->[0]{uuid},'GPU-bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','Driver UUID joined by bus, not ordinal');
is($rows->[1]{uuid},'GPU-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','Second identical GPU retains distinct identity');
{
 no warnings 'redefine';local $CFG{builds}={test=>"$root/bin"};
 local *VisLlama::Platform::CUDA::helper=sub {$helper};
 
 my $capture=\&VisLlama::Util::capture_command;
 local *VisLlama::Util::capture_command=sub {if($_[0] eq 'nvidia-smi'){$?=0;return "GPU-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa, 00000000:0C:00.0\nGPU-bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb, 00000000:43:00.0\n";}goto &$capture;};
 local *VisLlama::Builds::checked_probe=sub {"CUDA0: Same card\nCUDA1: Same card\n"};
 my $map=VisLlama::GPUIsolation::inventory('test');
 is($map->{CUDA0}{uuid},$rows->[0]{uuid},'Production inventory ignores NVIDIA-SMI order');
 my $profile=VisLlama::GPUIsolation::profile({build=>'test',ui=>{},options=>[['device','CUDA1,CUDA0']]},{});
 is($profile->{visible},$rows->[1]{uuid}.','.$rows->[0]{uuid},'Ordered physical UUID visibility retained');
 is_deeply(VisLlama::GPUIsolation::remap_options([['device','CUDA1,CUDA0']],$profile),[['device','CUDA0,CUDA1']],'Original-to-local ordinal remapping retained');
 local $ENV{VISLLAMA_TEST_PROBE_FAIL}=1;
 eval {VisLlama::GPUIsolation::inventory('test')};
 like($@,qr/Selected Linux build device\/linkage probe failed/,'Selected executable failure is rejected before helper invocation');
 local *VisLlama::Platform::CUDA::linkage=sub {($backend,$runtime)};
 eval {VisLlama::GPUIsolation::inventory('test')};
 like($@,qr/cudaGetDeviceCount failed \(999\)/,'Private diagnostic retains native failing operation/code');
 my $public=VisLlama::Errors::public_error($@);
 unlike($public->{message},qr/cudaGetDeviceCount|999|libggml/,'API errors redact helper diagnostics');
}
# Linkage parser verifies loader-reported paths, not guessed file adjacency.
{
 no warnings 'redefine';
 local *VisLlama::Util::capture_command=sub {$?=0;return "  12: calling init: $root/lib/libggml-cuda.so\nCUDA0: fixture\n";};
 my ($linked,$runtime)=VisLlama::Platform::CUDA::linkage($exe);
 is($linked,"$root/lib/libggml-cuda.so",'Actual loader-reported backend path accepted');
 is($runtime,$linked,'Static exported runtime provenance is the backend');
 local *VisLlama::Util::capture_command=sub {$?=0;return 'CUDA0: fixture without loader provenance';};
 eval {VisLlama::Platform::CUDA::linkage($exe)};
 like($@,qr/Cannot verify Linux CUDA linkage/,'Missing actual linkage never falls back to a global runtime');
}
my $mismatch=VisLlama::Util::capture_command_stdout($helper,"$root/lib/libggml-cuda.so","$root/lib/libcuda.so.1");
ok($?!=0,'Helper rejects runtime provenance mismatch');
like($VisLlama::Command::LAST_STDERR,qr/linkage mismatch/,'Mismatch detail stays private');
{
 no warnings 'redefine';
 local *VisLlama::Util::capture_command=sub {$?=0;return "calling init: $root/lib/libcudart.so.12\n";};
 my ($target,$loaded_runtime)=VisLlama::Platform::CUDA::linkage($exe);
 is($target,$loaded_runtime,'Monolithic backend with observed dynamic runtime supported');
}
done_testing();
