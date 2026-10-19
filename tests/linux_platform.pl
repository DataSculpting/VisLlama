# Real Linux filesystem/process-group tests with synthetic executables. This
# validates OS operations, not llama.cpp inference, CUDA hardware or Windows.
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Temp qw(tempdir);
use File::Spec;
use JSON::PP qw(decode_json);
use Time::HiRes qw(time);
use VisLlama::Platform ();
use VisLlama::Platform::Linux ();
use VisLlama::Builds ();
use VisLlama::Models ();
use VisLlama::Paths ();
use VisLlama::Telemetry ();
use VisLlama::Process ();
use VisLlama::Context qw(%CFG $STATE);
plan skip_all=>'Linux native operations' unless $^O eq 'linux';
my $root=tempdir(CLEANUP=>1);
sub put {my ($path,$text)=@_;open my $fh,'>:raw',$path or die $!;print {$fh} $text;close $fh;}
sub readfile {open my $fh,'<:raw',$_[0] or die $!;local $/;return <$fh>;}
sub until_true {my ($code)=@_;my $until=time()+4;while(time()<$until){return 1 if $code->();select undef,undef,undef,.03;}return 0;}
mkdir "$root/Models";mkdir "$root/Models/sub";mkdir "$root/outside";
put("$root/Models/sub/model.gguf",'fixture');put("$root/outside/model.gguf",'outside');
symlink "$root/outside","$root/Models/escape" or die $!;
ok(VisLlama::Paths::canonical_under("$root/Models/sub/model.gguf","$root/Models"),'Linux child path accepted');
ok(!VisLlama::Paths::canonical_under("$root/Models/escape/model.gguf","$root/Models"),'Symlink escape rejected');
ok(!VisLlama::Paths::canonical_under("$root/Models/../outside/model.gguf","$root/Models"),'Parent traversal rejected');
ok(!VisLlama::Paths::canonical_under("$root/models/sub/model.gguf","$root/Models"),'Case is significant');
my $folders=VisLlama::Models::list_server_folders("$root/Models/sub",1);
is($folders->{parent},"$root/Models",'Native Linux folder parent');
is($folders->{files}[0]{path},"$root/Models/sub/model.gguf",'Picker returns usable POSIX file path');
is(VisLlama::Models::list_server_folders('',0)->{folders}[0]{path},'/','Linux picker starts at filesystem root');
mkdir "$root/Models/\x{4e2d}";
my $unicode=VisLlama::Models::list_server_folders("$root/Models",0);
ok((grep {$_->{name} eq "\x{4e2d}"} @{$unicode->{folders}}),'UTF-8 folder names cross JSON as characters');
for my $name ('Build','build') {mkdir "$root/$name";put("$root/$name/llama-server","#!$^X\nprint qq(version: b12345\\n);\n");chmod 0755,"$root/$name/llama-server";}
my ($found)=VisLlama::Builds::discover_builds($root);
is(scalar @$found,2,'Case-distinct executable builds both discovered');
chmod 0644,"$root/build/llama-server";
ok(!VisLlama::Builds::find_server_exe("$root/build"),'Linux requires executable permission');
chmod 0755,"$root/build/llama-server";
# Launch a native child which forks a TERM-resistant descendant. Both remain in
# the owned process group; shell metacharacters and Unicode are literal argv.
subtest 'Native Linux ownership' => sub {
plan skip_all=>'This host does not expose procfs; execute on a normal Linux installation' unless -r '/proc/self/stat';
my $script="$root/child.pl";put($script,<<'CHILD');
use strict;use warnings;use JSON::PP;
$|=1;
open my $f,'>:raw',$ARGV[0] or die $!;print {$f} JSON::PP->new->encode({argv=>[@ARGV[1..$#ARGV]],cwd=>do{require Cwd;Cwd::getcwd()},visible=>$ENV{CUDA_VISIBLE_DEVICES}});close $f;
my $pid=fork();die $! unless defined $pid;
if (!$pid) {$SIG{TERM}='IGNORE';while(1){select undef,undef,undef,.1;}}
open $f,'>',$ARGV[0].'.descendant' or die $!;print {$f} $pid;close $f;
while(1){select undef,undef,undef,.1;}
CHILD
my $proc=VisLlama::Platform::Linux->launch({exe=>$^X,args=>[$script,"$root/args.json",'two words',q{$(touch unwanted); "quoted"},"unicode-\x{4e2d}"],cwd=>$root,log=>"$root/process.log",exit_file=>"$root/process.exitcode",env=>{CUDA_VISIBLE_DEVICES=>'GPU-b,GPU-a'}});
ok(until_true(sub {-f "$root/args.json.descendant"}),'Real forked native descendants start');
my $args=decode_json(readfile("$root/args.json"));
is_deeply($args->{argv},['two words',q{$(touch unwanted); "quoted"},"unicode-\x{4e2d}"],'Argument boundaries and UTF-8 preserved without a shell');
is($args->{cwd},$root,'Native working directory');is($args->{visible},'GPU-b,GPU-a','Child-only ordered visibility');
ok(!-e "$root/unwanted",'Shell substitution never executed');
my $desc=0+readfile("$root/args.json.descendant");
my $exit;ok($proc->GetExitCode($exit) && $exit==259,'Owned Linux child reports running');
ok($proc->stop(),'TERM followed by KILL confirms entire native group stopped');
ok(until_true(sub {my $r=VisLlama::Platform::Linux::stat_row($desc);!$r || $r->{state}=~/^[ZX]$/}),'TERM-resistant descendant is no longer running');
ok($proc->GetExitCode($exit) && $exit==143,'Linux termination retains native signal status');
is(readfile("$root/process.exitcode"),"143\n",'Native exit sidecar is ASCII');
my $fast=VisLlama::Platform::Linux->launch({exe=>$^X,args=>['-e','exit 37'],cwd=>$root,log=>"$root/fast.log",env=>{}});
ok(until_true(sub {$fast->GetExitCode($exit) && $exit==37}),'Fast native exit is reaped with its actual status');
eval {VisLlama::Platform::Linux->launch({exe=>"$root/missing",args=>[],cwd=>$root,log=>"$root/fail.log",env=>{}})};
like($@,qr/exec failed/,'Exec failure is caught before committing process state');
done_testing();
};
# Probe deterministic procfs counters, including first sample and guest exclusion.
mkdir "$root/proc";local $VisLlama::Telemetry::PROC_ROOT="$root/proc";
put("$root/proc/stat","cpu 100 0 20 880 0 0 0 0 50 0\n");put("$root/proc/meminfo","MemTotal: 2048 kB\nMemAvailable: 512 kB\n");
my $stats=VisLlama::Telemetry::linux_system_stats();ok(!defined($stats->{cpu_percent}),'First CPU sample is unknown');
put("$root/proc/stat","cpu 150 0 20 930 0 0 0 0 100 0\n");$stats=VisLlama::Telemetry::linux_system_stats();
is($stats->{cpu_percent},50,'CPU delta excludes duplicate guest counters');is($stats->{memory_used_mib},1.5,'RAM uses MemAvailable');
done_testing();
