# Focused recovery checks. All files, native probes and process handles are fixtures.
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use VisLlama::ModelStats ();
use VisLlama::HTTP ();
use VisLlama::Proxy ();
use VisLlama::ProcessState ();
use VisLlama::Context qw($STATE);
my $dir=tempdir(DIR=>$RealBin,CLEANUP=>1);
{ no warnings 'redefine'; *VisLlama::Errors::log_dir=sub {$dir}; }
{
 no warnings 'redefine';
 local *VisLlama::ModelStats::model_stats_path=sub {"$dir/missing/stats.jsonl"};
 eval { VisLlama::ModelStats::append_model_stats('model','cfg','build','file','instance',
   {prompt_tokens_total=>100,tokens_predicted_total=>20,prompt_seconds_total=>2,tokens_predicted_seconds_total=>1},1000) };
 ok($@,'Initial stats write fails in fixture');
}
{
 no warnings 'redefine';
 local *VisLlama::ModelStats::model_stats_path=sub {"$dir/stats.jsonl"};
 my $m={prompt_tokens_total=>150,tokens_predicted_total=>30,prompt_seconds_total=>3,tokens_predicted_seconds_total=>2};
 VisLlama::ModelStats::append_model_stats('model','cfg','build','file','instance',$m,1001);
 VisLlama::ModelStats::append_model_stats('model','cfg','build','file','instance',$m,1002);
 open my $fh,'<',"$dir/stats.jsonl" or die $!;my @rows=map {decode_json($_)} <$fh>;close $fh;
 is($rows[0]{prompt_tokens},150,'Retry retains tokens from failed write');
 is($rows[0]{decode_tokens},30,'Retry retains decode tokens');
 is(scalar(@rows),1,'Unchanged counters do not duplicate a written sample');
}
{
 no warnings 'redefine';
 my $calls=0;
 local *VisLlama::Util::capture_command=sub {++$calls; $?=$calls==1?256:0;return $calls==1?'probe failed':'--metrics';};
 ok(!VisLlama::ModelStats::metrics_supported("$dir/engine"),'Transient failed probe reports unavailable');
 ok(VisLlama::ModelStats::metrics_supported("$dir/engine"),'Next probe recovers instead of caching failure');
 VisLlama::ModelStats::metrics_supported("$dir/engine");
 is($calls,2,'Successful capability result is cached');
}
{
 no warnings 'redefine';my $calls=0;
 my $exe="$dir/replace.exe";open my $fh,'>',$exe or die $!;print $fh 'old';close $fh;
 local *VisLlama::Util::capture_command=sub {++$calls;$?=0;return $calls==1?'no metrics':'--metrics';};
 ok(!VisLlama::ModelStats::metrics_supported($exe),'Successful absence is supported');
 open $fh,'>>',$exe or die $!;print $fh 'replacement';close $fh;
 ok(VisLlama::ModelStats::metrics_supported($exe),'Changed executable invalidates capability cache');
}
for my $wire ("POST /api/start HTTP/1.1\r\nContent-Length: 9\r\n\r\n{}",
              "POST /api/start HTTP/1.1\r\nContent-Length: xyz\r\n\r\n",
              "POST /api/start HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 9\r\n\r\n{}",
              "POST /api/start HTTP/1.1\r\nContent-Length: 0\r\n") {
 open my $sock,'<',\$wire or die $!;eval {VisLlama::HTTP::read_request($sock)};ok($@,'Incomplete/ambiguous control request rejected');close $sock;
}
{
 my $wire="POST /api/status HTTP/1.1\r\nContent-Length: 2 \t\r\n\r\n{}";
 open my $sock,'<',\$wire or die $!;my @req=VisLlama::HTTP::read_request($sock);close $sock;
 is($req[3],'{}','Complete control request with header whitespace unchanged');
}
for my $wire ("2junk\r\n{}\r\n0\r\n\r\n","2\r\n{}xx0\r\n\r\n","0\r\n") {
 open my $sock,'<',\$wire or die $!;my $body=eval {VisLlama::Proxy::read_chunked_body($sock)};
 ok($@ || !defined($body),'Malformed public chunk request rejected');close $sock;
}
{
 package RecoveryProcess;
 sub new {bless {mode=>'fail'},shift}
 sub GetExitCode {die "Transient handle error\n" if $_[0]{mode} eq 'throw';return 0 if $_[0]{mode} eq 'fail';$_[1]=$_[0]{mode} eq 'active'?259:0;return 1}
}
{
 no warnings 'redefine';local *VisLlama::Errors::log_dir=sub {$dir};
 local $STATE->{mode}='single';local $STATE->{proc}=RecoveryProcess->new;local $STATE->{pid}=123;
 ok(VisLlama::ProcessState::proc_running(),'Failed health query conservatively retains live ownership');
 is($STATE->{pid},123,'Failed query does not discard PID');
 $STATE->{proc}{mode}='throw' if $STATE->{proc};
 ok(VisLlama::ProcessState::proc_running(),'Thrown query is retried instead of treating process as stopped');
 if ($STATE->{proc}) {$STATE->{proc}{mode}='active';ok(VisLlama::ProcessState::proc_running(),'Health query recovers');$STATE->{proc}{mode}='exited';}
 ok(!VisLlama::ProcessState::proc_running(),'Verified exit still clears ownership');
 ok(!defined($STATE->{pid}),'Confirmed stopped PID cleared');
}
done_testing;
