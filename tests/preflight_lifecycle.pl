# Static preflight and identity boundaries with synthetic build capabilities.
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use VisLlama::Platform ();
BEGIN { no warnings 'redefine'; *VisLlama::Platform::windows=sub {1}; }
use VisLlama::Preflight ();
use VisLlama::Lifecycle ();
use VisLlama::Readiness ();
use VisLlama::API ();
use VisLlama::Context qw(%CFG $STATE);
my $dir=tempdir(CLEANUP=>1);my $exe="$dir/llama-server.exe";my $model="$dir/model.gguf";
for my $file ($exe,$model) {open my $fh,'>',$file or die $!;print {$fh} 'fixture';close $fh;}
no warnings 'redefine';
local *VisLlama::ProcessState::router_engine_running=sub {1};
local *VisLlama::Paths::presets_dir=sub{$dir};
local *VisLlama::Paths::app_base_dir=sub{$dir};
local *VisLlama::Paths::canonical_under=sub {index($_[0],$dir.'/')==0};
local *VisLlama::Builds::checked_probe=sub {'--model --ctx-size --chat-template-file --device --fit --gpu-layers'};
local *VisLlama::GPUPlanner::gpu_plan_for_mode=sub{die 'Preflight must never plan VRAM'};
local $CFG{builds}={build=>$dir};local $CFG{model_root}=$dir;
$STATE->{router_engines}={build=>{build=>'build',models=>['model'],proc=>1}};
my $req={alias=>'model',original_alias=>'model',build=>'build',model=>$model,args=>['--ctx-size','4096'],ui=>{},live=>1};
ok(VisLlama::Preflight::validate($req,1),'Existing target validates without VRAM planning');
for my $bad ({%$req,model=>"$dir/missing.gguf"},{%$req,args=>['--chat-template-file',"$dir/missing.jinja"]},{%$req,build=>'missing'}) {
 eval {VisLlama::Preflight::validate($bad,1)};ok($@,'Invalid replacement rejected before mutation');
}
ok(VisLlama::Preflight::validate({%$req,args=>['--unadvertised','value']},1),'Unadvertised custom option is preserved for native validation');
{
 local *VisLlama::Builds::checked_probe=sub {die 'Ordinary validation must not run a native help probe'};
 ok(VisLlama::Preflight::validate($req,1),'Ordinary preflight does not probe native capabilities');
 my $changed={%$req,args=>['--device','CUDA1'],ui=>{devices=>['CUDA1']}};
 is(VisLlama::Preflight::issue($changed),undef,'New GPU visibility group requests save plus explicit restart, not a failed preflight');
}
# Incomplete split sets fail before the currently loaded model is touched.
my $shard="$dir/split-00001-of-00002.gguf";
open my $sf,'>',$shard or die $!;print {$sf} 'fixture';close $sf;
eval {VisLlama::Preflight::validate({%$req,model=>$shard},1)};
like($@,qr/shard is missing/,'Missing split shard is a static preflight failure');
{
 local *VisLlama::ProcessState::router_engine_running=sub {0};
 eval {VisLlama::Preflight::validate($req,1)};
 like($@,qr/no longer running/,'Dead target group fails before unload');
}
my $id=VisLlama::Preflight::issue($req);
ok(VisLlama::Preflight::check({model=>'model',preflight_id=>$id},0),'Unload ticket checks original alias and files');
eval {VisLlama::Preflight::check({model=>'other',preflight_id=>$id},0)};like($@,qr/does not match/,'Ticket cannot unload another alias');
eval {VisLlama::Preflight::check({%$req,args=>['--ctx-size','8192'],preflight_id=>$id},1)};like($@,qr/settings changed/,'Edited payload cannot reuse ticket');
open my $fh,'>>',$model or die $!;print {$fh} 'changed';close $fh;
eval {VisLlama::Preflight::check({model=>'model',preflight_id=>$id},0)};like($@,qr/files changed/,'File changed between preflight and unload is rejected');
# Real save dispatch advances the same ticket so save-before-unload works.
$id=VisLlama::Preflight::issue($req);
{
 local *VisLlama::Catalog::sync_router_build_inis=sub {
  my ($items,$entry)=@_;VisLlama::Storage::transaction([$entry]);
 };
 my $wire='';open my $sock,'>',\$wire or die $!;
 VisLlama::API::handle_api($sock,'/api/router-preset-save',{%$req,preflight_id=>$id});close $sock;
 like($wire,qr/^HTTP\/1.1 200/,'Preflight-bound save commits through real API');
 ok(VisLlama::Preflight::check({model=>'model',preflight_id=>$id},0),'Same ticket remains valid for unload after its own save');
 my ($catalog)=VisLlama::Catalog::router_paths();VisLlama::Storage::write($catalog,'[]');
 eval {VisLlama::Preflight::check({model=>'model',preflight_id=>$id},0)};
 like($@,qr/settings changed/,'Unrelated catalog change invalidates the ticket');
}
$id=VisLlama::Preflight::issue($req);VisLlama::Lifecycle::rotate();
eval {VisLlama::Preflight::check({model=>'model',preflight_id=>$id},0)};like($@,qr/Runtime changed/,'Ticket cannot target replacement runtime');
my $old=VisLlama::Lifecycle::token();VisLlama::Lifecycle::rotate();
eval {VisLlama::Lifecycle::check({runtime_token=>$old})};like($@,qr/Runtime changed/,'Old runtime token rejected');
ok(eval {VisLlama::Lifecycle::check({runtime_token=>VisLlama::Lifecycle::token()});1},'Current token accepted');
# Real dispatch rejects stale/missing identity before invoking native cleanup.
{
 local $STATE->{require_runtime_token}=1;my $called=0;
 local *VisLlama::Process::stop_server=sub {$called++;return {ok=>JSON::PP::true}};
 for my $body ({},{runtime_token=>$old}) {
  my $wire='';open my $sock,'>',\$wire or die $!;
  VisLlama::API::handle_api($sock,'/api/stop',$body);close $sock;
  like($wire,qr/^HTTP\/1.1 409/,'Stale action is an HTTP conflict');
  unlike($wire,qr/Preflight.pm|Lifecycle.pm/,'Identity errors do not leak source details');
 }
 is($called,0,'Rejected requests cannot stop a replacement');
}
$STATE->{mode}='router';$STATE->{active_operation}=undef;
$STATE->{endpoint_ready}=1;$STATE->{endpoint_checked_at}=time();
$STATE->{router_engines}{build}{ready}=1;$STATE->{router_engines}{build}{ready_checked_at}=time();
$STATE->{startup_models}=[{alias=>'model',state=>'failed',error=>'Safe failure reference'}];
is(VisLlama::Readiness::snapshot(1)->{phase},'partial','Healthy proxy does not hide failed startup model');
$STATE->{startup_models}[0]{state}='loaded';
is(VisLlama::Readiness::snapshot(1)->{phase},'ready','Ready requires endpoint and engine evidence');
$STATE->{starting_engines}=$STATE->{router_engines};
is(scalar @{VisLlama::Readiness::snapshot(1)->{engines}},1,'Startup and active registries do not duplicate readiness rows');
delete $STATE->{starting_engines};
$STATE->{catalog_apply_incomplete}=1;
is(VisLlama::Readiness::snapshot(1)->{phase},'degraded','Incomplete live publication cannot appear ready');
delete $STATE->{catalog_apply_incomplete};
$STATE->{router_engines}{build}{ready}=0;
is(VisLlama::Readiness::snapshot(1)->{phase},'degraded','Failed engine readiness remains distinct from launcher liveness');
$STATE->{router_engines}{build}{ready_checked_at}=1;
is(VisLlama::Readiness::snapshot(1)->{phase},'checking','Stale evidence is not current readiness');
is(VisLlama::Readiness::snapshot(0)->{phase},'stopped','Stopped state remains explicit');
done_testing();
