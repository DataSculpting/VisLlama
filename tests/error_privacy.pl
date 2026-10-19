use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Temp qw(tempdir);
use File::Spec;
use JSON::PP qw(decode_json encode_json);
use VisLlama::Errors ();
use VisLlama::HTTP ();
use VisLlama::App ();
use VisLlama::API::Diagnostics ();
use VisLlama::Context qw($STATE);
use VisLlama::ProcessState ();
use VisLlama::Router ();
use VisLlama::Builds ();

my $dir=tempdir(CLEANUP=>1);
my $sentinel='PRIVATE_SENTINEL';
my $detail="Cannot read C:\\private\\$sentinel.pm at C:\\private\\Handler.pm line 47.\nAuthorization: Bearer secret-value\n";
{ no warnings 'redefine'; *VisLlama::Errors::log_dir=sub{$dir}; }
my $e=VisLlama::Errors::public_error($detail);
unlike(encode_json($e),qr/PRIVATE_SENTINEL|Handler|line 47|secret-value|C:/,'Unknown failure is not echoed');
like($e->{reference},qr/^VL-[a-f0-9]{20}$/,'Opaque error reference');
my @files=glob(File::Spec->catfile($dir,'*.jsonl'));
is(scalar(@files),1,'Private diagnostic file created');
open my $fh,'<',$files[0] or die $!;my $record=decode_json(<$fh>);close $fh;
is($record->{reference},$e->{reference},'Response correlates with private detail');
like($record->{detail},qr/PRIVATE_SENTINEL/,'Private diagnostic retained');
unlike($record->{detail},qr/secret-value/,'Conventional authorization value not logged');
my $unicode=eval {VisLlama::Errors::public_error("Unicode path \x{4e2d}\x{6587} $sentinel")};
ok($unicode && $unicode->{reference},'Unicode exceptions do not break diagnostic hashing');
my $v=VisLlama::Errors::public_error("API alias is required at lib/X.pm line 1.");
is($v->{message},'API alias is required','Reviewed static validation retained');
my $spoof=VisLlama::Errors::public_error('API alias is required '.$sentinel);
unlike($spoof->{message},qr/PRIVATE_SENTINEL/,'Validation prefix does not whitelist arbitrary suffix');
my $wire='';open my $sock,'>',\$wire or die $!;VisLlama::HTTP::fail_json($sock,$detail,500);close $sock;
unlike($wire,qr/PRIVATE_SENTINEL|Handler|secret-value/,'HTTP failure boundary strips all exception detail');
like($wire,qr/error_ref/,'HTTP error reference returned');
my $safe=VisLlama::Errors::browser_log("error: $detail\nmetadata from C:\\$sentinel\nlayer 4/20\nordinary diagnostic message\n");
unlike($safe,qr/PRIVATE_SENTINEL|Handler|secret-value/,'Sensitive log values are redacted');
like($safe,qr/layer 4\/20/,'Original numeric progress retained');
like($safe,qr/ordinary diagnostic message/,'Ordinary diagnostics are retained');
{
 local $STATE->{mode}='single';local $STATE->{proc}=undef;
 local $STATE->{last_error}=$detail;local $STATE->{command}="exe --api-key $sentinel";
 my $status=VisLlama::ProcessState::state_payload();
 unlike(encode_json($status),qr/PRIVATE_SENTINEL|Handler/,'Status reused by config/start does not spill error/command');
}
{
 no warnings 'redefine';
 local *VisLlama::ProcessState::proc_running=sub{1};
 local *VisLlama::ProcessState::router_engine_running=sub{1};
 local *VisLlama::Preflight::saved=sub{1};
 local *VisLlama::Catalog::publish_engine_inis=sub{};
 local *VisLlama::Catalog::load_router_presets=sub{[{alias=>'model',build=>'b',enabled=>1}]};
 local *VisLlama::Catalog::write_router_ini_for_build=sub{{}};
 local *VisLlama::Router::router_http_engine=sub{die $detail};
 local $STATE->{mode}='router';local $STATE->{router_engines}={b=>{models=>['model']}};
 my $result=VisLlama::Router::apply_router_config_live(0);
 unlike(encode_json($result),qr/PRIVATE_SENTINEL|Handler/,'HTTP-200 restart-required failure is safe');
 like($result->{reason},qr/Reference: VL-/,'Soft failure includes private-log reference');
}
{
 no warnings 'redefine';
 local *VisLlama::ProcessState::router_engine_running=sub{1};
 local *VisLlama::Router::router_http_engine=sub{{data=>[{id=>'model',debug=>$detail,status=>{value=>'loaded',error=>$detail,args=>['--api-key',$sentinel,'--model','C:/private/a.gguf','--ctx-size','8192','--parallel=2','--load-mode','mmap']}}]}};
 local $STATE->{router_engines}={b=>{models=>['model']}};
 my $models=VisLlama::Router::router_models_merged();
 unlike(encode_json($models),qr/PRIVATE_SENTINEL|Handler|private\/a/,'Native model debug fields and secret/path arguments are not forwarded');
 is_deeply($models->{data}[0]{status}{args},['--ctx-size','8192','--parallel','2','--load-mode','mmap'],'Reload verification arguments retained');
}
{
 no warnings 'redefine';local *VisLlama::Util::capture_command=sub{$?=256;return $detail};
 my $raw=eval{VisLlama::Builds::checked_probe('fixture','--help')};my $failure=$@;
 ok(!defined($raw) && $failure,'Failed probe does not return native output as successful help');
 unlike(encode_json(VisLlama::Errors::public_error($failure)),qr/PRIVATE_SENTINEL|Handler/,'Probe exception is safe at public boundary');
}
{
 no warnings 'redefine'; local *VisLlama::Errors::log_dir=sub{File::Spec->catdir($dir,'missing','child')};
 my $stderr='';open my $err,'>',\$stderr or die $!;local *STDERR=$err;
 my $ok=eval{VisLlama::Errors::public_error('unique fallback '.$sentinel);1};
 ok($ok,'Unwritable log does not crash error handling');like($stderr,qr/PRIVATE_SENTINEL/,'Fallback details remain server-side STDERR');
}
done_testing();
