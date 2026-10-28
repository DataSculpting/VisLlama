# GPL-3.0-only. Real definition/renderer/lifecycle with synthetic processes, not hardware.
use strict;use warnings;use Test::More;use FindBin qw($RealBin);use lib "$RealBin/../lib";use File::Temp qw(tempdir);use File::Path qw(make_path);use JSON::PP qw(encode_json);use Storable qw(dclone);
use VisLlama::Engines ();use VisLlama::Engine::Import ();use VisLlama::Engine::Definitions ();use VisLlama::Context qw(%CFG $STATE);
my $raw=VisLlama::Engine::Registry::read_json("$RealBin/../engines/maya/engine.json");VisLlama::Engine::Registry::validate($raw);
my $legacy=VisLlama::Engine::Registry::read_json("$RealBin/fixtures/engines/maya-definition-1.0.json");
my $legacy_digest=Digest::SHA::sha256_hex(VisLlama::Engine::Registry::json()->encode($legacy));
ok(grep($_ eq $legacy_digest,@{$raw->{compatible_definition_digests}}),'Existing registrations remain compatible with the corrected bundled definition');
ok(grep($_ eq $legacy_digest,@{$raw->{previous_default_digests}}),'Reviewed default upgrade recognizes the exact earlier definition');
my $cfg=VisLlama::Engine::Registry::read_json("$RealBin/fixtures/engines/maya-glm.json");
my $root=tempdir(CLEANUP=>1);make_path("$root/engines/maya","$root/stable/serve","$root/stable/tools","$root/experimental/serve","$root/experimental/tools","$root/pack/tokenizer");
sub put {open my $f,'>:raw',$_[0] or die $!;print {$f} $_[1];close $f;}
put("$root/engines/maya/engine.json",encode_json($raw));for my $install(qw(stable experimental)){put("$root/$install/serve/server.py","# $install fixture");put("$root/$install/tools/maya_names.py",'# fixture');put("$root/$install/VERSION",$install);for(qw(python maya)){put("$root/$install/$_",'fixture');chmod 0755,"$root/$install/$_";}}
put("$root/pack/tokenizer/$_",'{}') for qw(vocab.json merges.txt token_type.json);
no warnings 'redefine';local *VisLlama::Paths::app_base_dir=sub {$root};local %CFG=(builds=>{},build_order=>[]);$STATE={};
my $d=VisLlama::Engine::Registry::get('maya');my $calls=0;
local *VisLlama::Command::capture=sub {$calls++;$?=0;$VisLlama::Command::LAST_STDERR='';return " --engine VALUE\n --config FILE\n --host VALUE\n --port N\n --api-key KEY\n --glm-pack DIR\n --max-context N\n --new-option N  Future\n"};
my @b;for my $install(qw(stable experimental)){push @b,VisLlama::Engines::save_build({engine=>'maya',name=>$install,root=>"$root/$install",executable=>"$root/$install/python",runtime_executable=>"$root/$install/maya",definition_digest=>$d->{digest}});}
is($calls,0,'Registering Maya is passive');isnt($b[0]{id},$b[1]{id},'One definition covers distinct named installations');isnt($b[0]{fingerprint},$b[1]{fingerprint},'Installed revisions have separate evidence');
my $inspection=VisLlama::Engine::Import::inspect($d,$b[0],$cfg);is($inspection->{model},$cfg->{args}[1],'Import identifies GLM pack');is($inspection->{alias},$cfg->{model_name},'Import prefills alias');
my $original=dclone($cfg);my $p={alias=>'maya-one',engine=>'maya',build=>$b[0]{id},model=>"$root/pack",config_mode=>'import',settings=>{},native_config=>$cfg};
VisLlama::Engines::save_preset($p);is($calls,0,'Maya preset save never probes');
my $plan=VisLlama::Engine::Plan::render($d,$b[0],$p,"$root/private",8181);is_deeply($plan->{config}{args},$cfg->{args},'Untouched imported argv retained');is_deeply($plan->{config}{env},$cfg->{env},'Imported tuning and writable paths retained');is_deeply($plan->{config}{vision},$cfg->{vision},'Unknown/nested vision configuration preserved');is_deeply($plan->{config}{sampling},$cfg->{sampling},'Model sampling retained');
ok(grep($_ eq '--api-key=',@{$plan->{args}}),'Empty worker API-key value travels in one nonempty native argument');
ok(!grep($_ eq '',@{$plan->{args}}),'Bundled Maya startup does not rely on an empty native argv token');
is($plan->{config}{api_key},'','Private loopback worker uses proxy access contract');is($plan->{config}{host},'127.0.0.1','Worker host owned');is($plan->{config}{port},8181,'Worker port owned');is($plan->{config}{model_name},'maya-one','Public alias owned');isnt($plan->{config}{log},$cfg->{log},'Private native log');is_deeply($cfg,$original,'Input JSON never rewritten');
ok(!grep(/maya\.py|maya\.sh|START-MAYA|--setup|--calibrate|--rebuild/,@{$plan->{args}}),'Launch bypasses setup/rebuild/calibration wrappers');is($plan->{args}[2],'strata','Maya server retains documented --engine strata token');
$p->{settings}={'cpu-lane'=>8,'ram-headroom'=>20,'pcie-share'=>0.6,'parallel-requests'=>4,'gpu-selection'=>'1,3','layer-split'=>'22','max-context'=>65536,'slot-directory'=>"$root/slots-one"};
$plan=VisLlama::Engine::Plan::render($d,$b[0],$p,"$root/private",8181);is($plan->{config}{env}{MAYA_GLM_CPU_LANE},8,'Tuning edits map into native env object');is($plan->{config}{env}{FUTURE_SETTING},'keep','Unknown env retained');is($plan->{config}{gpu},'1,3','GPU values remain native');is($plan->{config}{layer_split},'22','Layer boundaries map to native JSON');is(scalar(grep {$_ eq '--parallel'} @{$plan->{config}{args}}),1,'Native parallel flag replaced exactly once');
my $create={%$p,config_mode=>'create',native_config=>{},settings=>{'model-format'=>'glm-pack','tokenizer-directory'=>"$root/pack/tokenizer"}};
$plan=VisLlama::Engine::Plan::render($d,$b[0],$create,"$root/private",8181);is_deeply($plan->{config}{args},['--glm-pack',"$root/pack"],'Create uses prepared catalog pack');ok(!exists($plan->{config}{sampling}),'Creation does not force sampling');ok(!exists($plan->{config}{env}),'Creation does not force tuning');
for my $bad (['parallel-requests',9],['pcie-share',1.2],['gpu-selection','0,,2']){my $invalid=dclone($p);$invalid->{settings}{$bad->[0]}=$bad->[1];eval{VisLlama::Engine::Plan::render($d,$b[0],$invalid,"$root/private",8181)};ok($@,'Invalid '.$bad->[0].' rejected');}
my $caps=VisLlama::Engines::discover($b[0]{id});ok(grep($_->{key} eq 'discovered-native-new-option',@{$caps->{fields}}),'Discovery adds an installed-build native option');is(VisLlama::Engines::capabilities($b[1])->{capabilities}{status},'not-run','Second installation does not inherit additive evidence');
# Load uses actual Maya readiness shape, plus catalog model identity.
VisLlama::Engines::save_preset({%$p,original_alias=>$p->{alias}});
{package MayaHandle;sub GetProcessID {4242}sub GetExitCode {$_[1]=$_[0]{exited}?0:259;1}}
local *VisLlama::Platform::launch=sub {bless {},'MayaHandle'};my $unloaded=0;my $wrong_alias=0;my $health_status="ok";
local *VisLlama::Engines::http_json=sub {$_[1] eq '/health'?{status=>$health_status,unloaded=>$unloaded?JSON::PP::true:JSON::PP::false}:{data=>[{id=>$wrong_alias?'wrong-model':'maya-one'}]}};
local *VisLlama::ProcessState::stop_owned_process=sub {$_[0]{exited}=1 if $_[0];1};
my $eng={engine=>'maya',build=>$b[0]{id},port=>8181,models=>['maya-one']};VisLlama::Engines::load('maya-one',$eng);is(VisLlama::Engines::status($eng),'loaded','Maya health predicate and alias confirm readiness');ok(-f $eng->{plan}{config_path},'Private runtime JSON written');
$wrong_alias=1;is(VisLlama::Engines::status($eng),'loading','Healthy worker with wrong model alias is not ready');$wrong_alias=0;$health_status='updating';is(VisLlama::Engines::status($eng),'loading','Updating worker is not ready');$health_status='ok';$unloaded=1;is(VisLlama::Engines::status($eng),'loading','Native unloaded response is never ready');
VisLlama::Engines::unload($eng);ok(!$eng->{proc},'Confirmed unload releases ownership');
$unloaded=0;VisLlama::Engines::load('maya-one',$eng);{local *VisLlama::ProcessState::stop_owned_process=sub {0};eval{VisLlama::Engines::unload($eng)};ok($@,'Failed stop reported');ok($eng->{proc},'Failed stop retains ownership');}VisLlama::Engines::unload($eng);
{
 local *VisLlama::Platform::windows=sub {1};
 VisLlama::Engines::load('maya-one',$eng);
 my $launcher=$eng->{plan}{config_path};$launcher=~s/config\.json$/launch.ps1/;
 open my $fh,'<',$launcher or die $!;my $script=do{local $/;<$fh>};close $fh;
 like($script,qr/\$ErrorActionPreference = 'Continue'/,'Native stderr does not request terminating PowerShell errors');
 like($script,qr/'--api-key='/,'Corrected default launcher attaches the empty value');
 like($script,qr/\$PSNativeCommandUseErrorActionPreference = \$false/,'Native failure remains an exit-code outcome');
 like($script,qr/2>&1\n\$engineExit = \$LASTEXITCODE\nSet-Content .* -Value \$engineExit -Encoding ASCII\nexit 0/s,'Output and native exit status remain captured in private artifacts');
 VisLlama::Engines::unload($eng);
}
{
 # Discovery may already have retained the previous bundled base locally.
 # Upgrading app files must not require overwriting it or reimporting models.
 my $active=VisLlama::Engine::Definitions::save('maya',$legacy,$d->{digest});
 my $updated=VisLlama::Engines::save_build({%{$b[0]},definition_digest=>$active->{digest}});
 local *VisLlama::Platform::windows=sub {1};VisLlama::Engines::load('maya-one',$eng);
 my $launcher=$eng->{plan}{config_path};$launcher=~s/config\.json$/launch.ps1/;
 open my $fh,'<',$launcher or die $!;my $script=do{local $/;<$fh>};close $fh;
 like($script,qr/'--api-key' '""'/,'Retained old definition encodes its separate empty argument for legacy PowerShell');
 unlike($script,qr/'--api-key' ''/,'Retained launch cannot lose an empty value through a bare PS empty string');
 is_deeply(VisLlama::Engine::Registry::read_json($active->{definition_file}),$legacy,'Local engine definition remains unchanged');
 VisLlama::Engines::unload($eng);
}
done_testing();
