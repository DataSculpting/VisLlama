# Contract fixtures only: no Docker daemon, Windows, GPU or model inference.
use strict;use warnings;use Test::More;use FindBin qw($RealBin);use lib "$RealBin/../lib";
use File::Temp qw(tempdir);use File::Spec;use JSON::PP ();
use VisLlama::Docker ();use VisLlama::Builds ();use VisLlama::Platform::Linux ();
use VisLlama::Platform::CUDA ();use VisLlama::Context qw(%CFG);use VisLlama::Catalog ();
plan skip_all=>'Linux Docker adapter contracts' unless $^O eq 'linux';
my $root=tempdir(CLEANUP=>1);mkdir "$root/models";mkdir "$root/external";mkdir "$root/presets";mkdir "$root/logs";
open my $m,'>',$root.'/models/model.gguf';print $m 'fixture';close $m;
open my $t,'>',$root.'/external/chat.jinja';print $t 'fixture';close $t;
my $ref='docker://fixture/wrapper:tag';my $id='sha256:'.('b'x64);my $cid='a'x64;
my (@calls,%containers);my $probe_fail=0;my $router_capability=1;my ($stop_fail,$foreign,$rm_query_fail,$image_override)=(0,0,0,'');
my $capture=sub {
 my ($stdout,$cli,@a)=@_;push @calls,\@a;my $out='';$?=0;
 if ($a[0] eq 'context') {$out=JSON::PP->new->encode([{Endpoints=>{docker=>{Host=>'unix:///var/run/docker.sock'}}}]);}
 elsif ($a[0] eq 'info') {$out="linux\n";}
 elsif ($a[0] eq 'image') {my $direct=$a[-1] =~ /direct/;$out=JSON::PP->new->encode([{Id=>$image_override||$id,Config=>{Entrypoint=>$direct?['/app/llama-server']:['/opt/nvidia/nvidia_entrypoint.sh'],Cmd=>['llama-server'],Env=>[]}}]);}
 elsif ($a[0] eq 'run') {
  if ($probe_fail) {my ($name,$owner);for my $i (0..$#a-1){$name=$a[$i+1] if $a[$i] eq '--name';$owner=$a[$i+1] if $a[$i] eq '--label'}$owner =~ s/^visllama.owner=//;$containers{'d'x64}={Id=>'d'x64,Name=>$name,Config=>{Labels=>{'visllama.owner'=>$owner}},State=>{Running=>1,ExitCode=>0,Pid=>4567}};$?=256;return 'fixture timed-out probe';}
  if (grep {$_ eq '/visllama-cuda-helper'} @a) {$out='[{"id":"CUDA0","bus":"0000:01:00.0","uuid":"GPU-12345678-1234-1234-1234-123456789abc"}]';}
  elsif (grep {$_ eq 'LD_DEBUG=libs'} @a) {$out="calling init: /image/lib/libggml-cuda.so\ncalling init: /image/lib/libcudart.so.12\n";}
  elsif ($a[-1] eq '--list-devices') {$out="NVIDIA copyright banner\nAvailable devices:\n CUDA0: NVIDIA GB10 (124545 MiB, 102154 MiB free)\n";}
  elsif ($a[-1] eq '--version') {$out="version: b11223 (commit abc1234)\n";}
  else {$out=($router_capability?"  --models-preset FILE  Model presets\n":'')."  --metrics  Metrics\n";}
 }
 elsif ($a[0] eq 'create') {my %labels;for my $i (0..$#a-1) {if($a[$i] eq '--label'){my($k,$v)=split /=/,$a[$i+1],2;$labels{$k}=$v}}$containers{$cid}={Id=>$cid,Config=>{Labels=>\%labels},State=>{Running=>0,ExitCode=>0,Pid=>1234}};$out=$cid;}
 elsif ($a[0] eq 'start') {$containers{$cid}{State}{Running}=1;$out=$cid;}
 elsif ($a[0] eq 'inspect') {my $c=$containers{$a[1]} || (grep {($_->{Name}//'') eq $a[1]} values %containers)[0];die 'No such object' unless $c;my $copy=JSON::PP->new->decode(JSON::PP->new->encode($c));$copy->{Config}{Labels}{'visllama.owner'}='foreign' if $foreign;$out=JSON::PP->new->encode([$copy]);}
 elsif ($a[0] eq 'stop') {if($stop_fail){$?=256;return 'fixture stop failed'}$containers{$a[-1]}{State}{Running}=0;$out=$a[-1];}
 elsif ($a[0] eq 'rm') {delete $containers{$a[-1]};$out=$a[-1];}
 elsif ($a[0] eq 'ps') {die 'fixture list interrupted' if $rm_query_fail;my $target=$a[-1];$target =~ s/^id=//;$out=exists($containers{$target})?$target:'';}
 else {die 'Unexpected fixture Docker command '.join(' ',@a);}
 return $out;
};
{
 no warnings 'redefine';
 local *VisLlama::Command::capture=$capture;
 local *VisLlama::Paths::app_base_dir=sub {$root};
 local *VisLlama::Paths::presets_dir=sub {"$root/presets"};
 local *VisLlama::Platform::Linux::launch=sub {bless {},'DockerFixtureLogger'};
 local *VisLlama::Platform::CUDA::helper=sub {"$root/helper"};
 local *VisLlama::Catalog::load_router_presets=sub {return [{build=>'Spark',model=>"$root/models/model.gguf",options=>[['chat-template-file',"$root/external/chat.jinja"]]}]};
 local $CFG{builds}={Spark=>$ref};local $CFG{build_order}=['Spark'];local $CFG{model_root}="$root/models";
 is(VisLlama::Docker::validate_image('registry.example:5000/server:tag'),'docker://registry.example:5000/server:tag','Image reference accepted without a shell command');
 eval {VisLlama::Docker::validate_image('docker run image; unwanted')};like($@,qr/image reference/,'Command text rejected');
 is(VisLlama::Builds::find_server_exe($ref),$ref,'Docker runtime shares build alias resolution');
 my $payload=VisLlama::Builds::build_entries_payload()->[0];is($payload->{name},'Spark','Build preset alias retained');is($payload->{image},'fixture/wrapper:tag','Image available separately from alias');
 my $info=VisLlama::Docker::resolve($ref);is_deeply($info->{server_command},['llama-server'],'NVIDIA wrapper preserved with explicit server command');
 my $direct=VisLlama::Docker::resolve('docker://fixture/direct:tag');is_deeply($direct->{server_command},[],'Direct entrypoint takes flags alone');
 my $help=VisLlama::Builds::checked_probe($ref,'--help');like($help,qr/models-preset/,'Feature probe routes through Docker');
 my $devices=VisLlama::Builds::parse_devices(VisLlama::Builds::checked_probe($ref,'--list-devices'));is(@$devices,1,'Startup banner does not become a device');is($devices->[0]{id},'CUDA0','Container CUDA namespace retained');
 is(VisLlama::Builds::planner_build_number($ref),11223,'Docker build number supplied to architecture rules');
 my $identity=JSON::PP->new->decode(VisLlama::Docker::identity($ref));is($identity->[0]{uuid},'GPU-12345678-1234-1234-1234-123456789abc','Container-runtime identity result retained');
 my ($helper_call)=grep {$_->[0] eq 'run' && grep {$_ eq '/visllama-cuda-helper'} @$_} @calls;
 is_deeply([@$helper_call[-2,-1]],['/image/lib/libggml-cuda.so','/image/lib/libcudart.so.12'],'Identity helper receives traced image libraries, not host library guesses');
 my $spec={exe=>$ref,args=>['--models-preset',"$root/presets/group.ini",'--host','127.0.0.1','--port',18123],env=>{LLAMA_CACHE=>"$root/logs/cache",CUDA_VISIBLE_DEVICES=>'GPU-12345678-1234-1234-1234-123456789abc'},log=>"$root/logs/router.log",exit_file=>"$root/logs/exit"};
 my $proc=VisLlama::Docker::launch($spec);isa_ok($proc,'VisLlama::Docker::Process');
 my ($create)=grep {$_->[0] eq 'create'} @calls;
 ok(grep($_ eq 'host',@$create),'Linux host networking keeps native Router child loopback behavior');
 ok(grep($_ eq $id,@$create),'Serving pins resolved image ID');
 ok(grep($_ eq '--models-preset',@$create),'Native Router configuration supplied');
 ok(grep($_ eq 'CUDA_VISIBLE_DEVICES=GPU-12345678-1234-1234-1234-123456789abc',@$create),'Verified UUID visibility scoped to container');
 ok(grep(index($_,'source='.$root.'/external')>=0,@$create),'External template directory mounted automatically');
 ok(grep(index($_,'target='.$root.'/models')>=0,@$create),'Host model path remains identical inside container');
 my $exit=0;ok($proc->GetExitCode($exit),'Container health queried');is($exit,259,'Running container uses existing owned-process interface');
 eval {VisLlama::Docker::check_live($proc,$ref,["$root/unmounted/model.gguf"])};like($@,qr/Restart Router/,'Unmounted live-catalog references require restart');
 my $before=@calls;$foreign=1;eval {$proc->stop()};like($@,qr/ownership/,'Foreign container ownership rejected');is(@calls,$before+1,'No stop command issued after ownership mismatch');$foreign=0;
 $stop_fail=1;eval {$proc->stop()};like($@,qr/Docker command failed/,'Stop failure reported');ok(!$proc->{removed},'Failed stop retains container ownership');$stop_fail=0;
 $rm_query_fail=1;eval {$proc->stop()};like($@,qr/list interrupted/,'Post-removal verification failure remains visible');$rm_query_fail=0;
 ok($proc->stop(),'Cleanup can complete after interrupted removal verification');ok($proc->{removed},'Removal confirmed');
 $image_override='sha256:'.('c'x64);my $guard={%$spec,docker_image_id=>$id};eval {VisLlama::Docker::launch($guard)};like($@,qr/image changed/,'Image change after UUID verification blocks launch');
 $router_capability=0;my $created=grep {$_->[0] eq 'create'} @calls;eval {VisLlama::Docker::launch($spec)};like($@,qr/Router support/,'Single-model-only images are not mistaken for Router images');is(scalar(grep {$_->[0] eq 'create'} @calls),$created,'Unsupported Router image rejected before a serving container is created');
 $probe_fail=1;eval {VisLlama::Docker::probe($ref,'--list-devices')};like($@,qr/timed-out probe/,'Failed ephemeral probe reports its original error');ok(!VisLlama::Docker::pending_running(),'Timed-out probe container is cleaned by full owned ID');
 $stop_fail=1;eval {VisLlama::Docker::probe($ref,'--list-devices')};like($@,qr/cleanup is unconfirmed/,'Failed probe cleanup is reported');ok(VisLlama::Docker::pending_running(),'Failed probe container ownership remains available to Stop');$stop_fail=0;ok(VisLlama::Docker::stop_pending(),'Stop retries retained probe cleanup');ok(!VisLlama::Docker::pending_running(),'Retry clears pending probe ownership');
}
done_testing();
package DockerFixtureLogger;sub stop {1}
