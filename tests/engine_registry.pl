# GPL-3.0-only. Synthetic engines test application contracts, not hardware.
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(encode_json);
use Storable qw(dclone);
use VisLlama::Engines ();
use VisLlama::Router ();
use VisLlama::Catalog ();
use VisLlama::Context qw(%CFG $STATE);
sub put {my ($p,$s)=@_;open my $f,'>:raw',$p or die $!;print {$f} $s;close $f;}
my $root=tempdir(CLEANUP=>1);make_path("$root/engines/example","$root/stable","$root/experimental");
my $definition={schema_version=>'1.0',definition_version=>'1.0.0',id=>'example',name=>'Example',platforms=>['linux','windows'],driver=>'native-json',concurrency=>'independent',
 argv=>['${executable}','${root}/server.pl','--config','${runtime_config}','--port','${port}'],fingerprint_files=>['server.pl'],
 probe=>{argv=>['${executable}','${root}/server.pl','--help'],timeout=>3,required_flags=>['--config','--port']},
 fields=>[{key=>'context',label=>'Context',type=>'integer',minimum=>1,binding=>'config',path=>['runtime','context']},{key=>'verbose',label=>'Verbose',type=>'boolean',binding=>'flag',flag=>'--verbose'}],
 config_overrides=>{model_name=>'${alias}',port=>'${port}'},readiness=>{path=>'/health',equals=>{loaded=>JSON::PP::true}}};
put("$root/engines/example/engine.json",encode_json($definition));
put("$root/stable/server.pl","# stable\n");put("$root/experimental/server.pl","# experimental\n");put("$root/model.gguf",'fixture');
no warnings 'redefine';
local *VisLlama::Paths::app_base_dir=sub {$root};local %CFG=(builds=>{},build_order=>[]);$STATE={};
my $registry=VisLlama::Engine::Registry::list();is(scalar @{$registry->{definitions}},1,'One family definition');is_deeply($registry->{errors},[],'Valid package');
my $d=$registry->{definitions}[0];put("$root/executable","fixture");chmod 0755,"$root/executable";
my $a=VisLlama::Engines::save_build({engine=>'example',name=>'Stable',root=>"$root/stable",executable=>"$root/executable",definition_digest=>$d->{digest}});
my $b=VisLlama::Engines::save_build({engine=>'example',name=>'Experimental',root=>"$root/experimental",executable=>"$root/executable",definition_digest=>$d->{digest}});
isnt($a->{id},$b->{id},'Build IDs independent of family');isnt($a->{fingerprint},$b->{fingerprint},'Installed revisions fingerprint independently');
my $calls=0;local *VisLlama::Command::capture=sub {$calls++;$?=0;$VisLlama::Command::LAST_STDERR='--config --port';return 'help on stderr'};
ok(VisLlama::Engines::probe($a->{id})->{compatible},'Both probe streams inform compatibility');
my $p={alias=>'first',build=>$a->{id},engine=>'example',model=>"$root/model.gguf",native_config=>{unknown=>[1,2],runtime=>{extra=>'kept'}},settings=>{context=>4096,verbose=>JSON::PP::false}};
my $items=VisLlama::Engines::save_preset($p);is($calls,1,'Save never probes');is(scalar @$items,1,'Extension in shared catalog');
ok(!-e "$root/presets/router-models-$a->{id}.ini",'No llama.cpp INI for extension');
my $plan=VisLlama::Engines::preview($p);is($plan->{config}{runtime}{context},4096,'Typed field');is($plan->{config}{runtime}{extra},'kept','Unknown native field retained');is_deeply($plan->{config}{unknown},[1,2],'Arrays retained');
is($plan->{args}[-1],8081,'Port argv');is($plan->{config}{port},8081,'Typed placeholder');ok(!grep($_ eq '--verbose',@{$plan->{args}}),'False presence flag omitted');
$p->{settings}{obsolete}='keep';$plan=VisLlama::Engines::preview($p);is_deeply($plan->{inactive_fields},['obsolete'],'Inactive value reported');
$p->{settings}{context}=0;eval {VisLlama::Engines::preview($p)};like($@,qr/minimum/,'Range checked');$p->{settings}{context}=4096;
my $before=VisLlama::Engine::Registry::json()->encode($p->{native_config});VisLlama::Engines::preview($p);is(VisLlama::Engine::Registry::json()->encode($p->{native_config}),$before,'Preview leaves input unchanged');
$p->{native_config}{api_key}='private';is(VisLlama::Engines::preview($p)->{config}{api_key},'[redacted]','Sensitive preview redacted');delete $p->{native_config}{api_key};
eval {VisLlama::Engines::delete_build($a->{id})};like($@,qr/model presets/,'Referenced build protected');
is_deeply(VisLlama::Engines::redact({tokenizer=>'/tokenizer',args=>['--api-key','private','--context','4096']}),{tokenizer=>'/tokenizer',args=>['--api-key','[redacted]','--context','4096']},'Redaction preserves useful non-secret settings');
my $old=$a->{id};$a=VisLlama::Engines::save_build({%$a,name=>'Renamed'});is($a->{id},$old,'Rename preserves immutable ID');
for my $case (['shell','arbitrary'],['schema_version','2.0']) {my $bad=dclone($definition);$bad->{$case->[0]}=$case->[1];eval {VisLlama::Engine::Registry::validate($bad)};ok($@,'Unsupported metadata fails closed');}
my $bad=dclone($definition);$bad->{argv}[0]='sh';eval {VisLlama::Engine::Registry::validate($bad)};like($@,qr/argv/,'Definition uses registered executable only');
$bad=dclone($definition);$bad->{fingerprint_files}=['../escape'];eval {VisLlama::Engine::Registry::validate($bad)};like($@,qr/fingerprint/,'Traversal rejected');
is(VisLlama::Engine::Plan::expand('${root}/file',{root=>'C:\\Models $(literal)'}),'C:\\Models $(literal)/file','No shell evaluation');
eval {VisLlama::Engine::Plan::expand('${unknown}',{})};like($@,qr/placeholder/,'Unknown placeholder rejected');
my $eng={engine=>'example',build=>$a->{id},port=>8001,models=>['first']};
{package EngineTestHandle;sub GetProcessID {4321}sub GetExitCode {$_[1]=$_[0]{exited}?0:259;1}}
local *VisLlama::Platform::launch=sub {bless {},'EngineTestHandle'};
local *VisLlama::Engines::http_json=sub {$_[1] eq '/health'?{loaded=>JSON::PP::true}:{data=>[{id=>$_[0]{models}[0]}]}};
local *VisLlama::ProcessState::stop_owned_process=sub {$_[0]{exited}=1 if $_[0];1};
VisLlama::Engines::load('first',$eng);is(VisLlama::Engines::status($eng),'loaded','Readiness predicate confirms loaded');ok(-f $eng->{plan}{config_path},'Private generated config');
is(VisLlama::Router::router_http_engine($eng,'GET','/v1/models',undef)->{data}[0]{status}{value},'loaded','Management dispatch');
$STATE->{router_engines}={'extension:first'=>$eng};is(VisLlama::Router::router_models_merged()->{data}[0]{id},'first','Merged Router catalog');
VisLlama::Engines::probe($b->{id});
VisLlama::Engines::save_preset({%$p,alias=>'second',build=>$b->{id}});
my $eng2={engine=>'example',build=>$b->{id},port=>8002,models=>['second']};
$STATE->{router_engines}{'extension:second'}=$eng2;
VisLlama::Engines::load('second',$eng2);
isnt($eng->{plan}{config_path},$eng2->{plan}{config_path},'Simultaneous builds have independent artifacts');
is($eng2->{plan}{cwd},$b->{root},'Experimental build retains its own working directory');
is($eng2->{plan}{config}{model_name},'second','Public aliases render independently');
VisLlama::Engines::unload($eng2);ok($eng->{proc},'Unloading one build retains the other');
my $instance=$eng->{plan}{config_path};VisLlama::Engines::unload($eng);is(VisLlama::Engines::status($eng),'unloaded','Confirmed unload');
VisLlama::Engines::load('first',$eng);isnt($instance,$eng->{plan}{config_path},'Reload uses new artifact directory');
{local *VisLlama::ProcessState::stop_owned_process=sub {0};eval {VisLlama::Engines::unload($eng)};like($@,qr/ownership retained/,'Unconfirmed stop reported');ok($eng->{proc},'Handle retained');}
VisLlama::Engines::unload($eng);
# Exercise actual control endpoints and public runtime payload for an idle engine.
require VisLlama::API::Serving;
{
 local *VisLlama::ProcessState::proc_running=sub {1};
 local *VisLlama::HTTP::json_response=sub {$_[2]};
 local *VisLlama::HTTP::fail_json=sub {die $_[1]};
 $STATE->{mode}='router';
 my ($idle)=grep {($_->{build}//'') eq $a->{id}} @{VisLlama::ProcessState::router_engines_payload()};
 ok($idle->{managed} && !$idle->{running},'Public payload identifies idle extension as managed, not running');
 is($idle->{build},$p->{build},'Runtime build ID matches catalog ID without native registrations');
 my $reply=VisLlama::API::Serving::handle(undef,'/api/router-load',{model=>'first'});
 ok($reply->{ok},'Manual API loads an idle extension with no llama.cpp build');
 is(VisLlama::Engines::status($eng),'loaded','Manual API waits for actual readiness fixture');
 $reply=VisLlama::API::Serving::handle(undef,'/api/router-unload',{model=>'first'});
 ok($reply->{ok},'Manual API unloads extension');
 is(VisLlama::Engines::status($eng),'unloaded','Manual API releases owned process');
}
my $count_before=$calls;
put("$root/stable/server.pl","# changed\n");VisLlama::Engines::validate_preset($p,1);is($calls,$count_before+1,'Changed build automatically checked on load');
VisLlama::Engines::validate_preset($p,1);is($calls,$count_before+1,'Unchanged compatible build reuses evidence');
unlink "$root/presets/$a->{id}-probe.json";
VisLlama::Engines::validate_preset($p,1);is($calls,$count_before+2,'Missing evidence checked automatically');
for my $alias ('', 'bad alias', 'bad/alias') {
 eval {VisLlama::Engines::save_preset({%$p,alias=>$alias})};
 my $public=VisLlama::Errors::public_error($@);like($public->{message},qr/Enter a model alias.*Spaces and slashes/, 'Backend alias rejection gives actionable public guidance');
}
{local *VisLlama::Command::capture=sub {$?=0;$VisLlama::Command::LAST_STDERR='';return '--config'};ok(!VisLlama::Engines::probe($a->{id})->{compatible},'Missing flag fails probe');eval {VisLlama::Engines::validate_preset($p,1)};like(VisLlama::Errors::public_error($@)->{message},qr/Engine compatibility check failed.*Settings > Manage builds/, 'Failed automatic check gives actionable public guidance');}
make_path("$root/presets/engines/example");put("$root/presets/engines/example/engine.json",encode_json($definition));
$registry=VisLlama::Engine::Registry::list();is(scalar @{$registry->{definitions}},0,'Duplicates never shadow bundled IDs');is(scalar @{$registry->{errors}},1,'Duplicate reported');
done_testing();
