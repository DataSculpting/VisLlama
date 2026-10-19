# GPL-3.0-only. Synthetic build help/schema evidence, never hardware acceptance.
use strict;use warnings;use Test::More;use FindBin qw($RealBin);use lib "$RealBin/../lib";
use File::Temp qw(tempdir);use File::Path qw(make_path);use JSON::PP qw(encode_json);use Storable qw(dclone);
use VisLlama::Engine::Registry ();use VisLlama::Engine::Definitions ();use VisLlama::Engine::Discovery ();use VisLlama::Engines ();use VisLlama::Context qw(%CFG $STATE);
my $root=tempdir(CLEANUP=>1);make_path("$root/engines/example","$root/a","$root/b","$root/tokenizer");
sub put {open my $f,'>:raw',$_[0] or die $!;print {$f} $_[1];close $f;}
for(qw(python native-a native-b model)){put("$root/$_",'fixture');chmod 0755,"$root/$_";}
my $d={schema_version=>'1.1',definition_version=>'1.0.0',id=>'example',name=>'Example',platforms=>['linux','windows'],driver=>'native-json',concurrency=>'independent',argv=>['${executable}','--config','${runtime_config}'],fields=>[
 {key=>'format',label=>'Format',type=>'string',enum=>['native','pack'],binding=>'none'},
 {key=>'tokenizer',label=>'Tokenizer',type=>'string',binding=>'config',path=>['tokenizer'],required=>JSON::PP::true},
 {key=>'workers',label=>'Known workers',type=>'integer',binding=>'config-flag',path=>['args'],flag=>'--workers',support=>{probe=>'native',flag=>'--workers'}},
 {key=>'dependent',label=>'Dependent',type=>'boolean',binding=>'config',path=>['dependent'],when=>{key=>'format',equals=>'pack'}}],
 runtime_executable_path=>['exe'],new_config=>{exe=>'${runtime_executable}',cwd=>'${root}',args=>[]},model_bindings=>[{key=>'format',equals=>'native',path=>['args'],flag=>'--native'},{key=>'format',equals=>'pack',path=>['args'],flag=>'--pack'}],
 requirements=>[{path=>['exe'],kind=>'file',label=>'Executable'},{path=>['tokenizer'],kind=>'directory',label=>'Tokenizer'}],
 discovery=>[{id=>'native',argv=>['${runtime_executable}','--help'],timeout=>3,parser=>'help',target=>'config-flag',path=>['args'],exclude=>['--help','--host']}],readiness=>{path=>'/health',equals=>{loaded=>JSON::PP::true}}};
put("$root/engines/example/engine.json",encode_json($d));no warnings 'redefine';local *VisLlama::Paths::app_base_dir=sub {$root};local %CFG=(builds=>{});$STATE={};
$d=VisLlama::Engine::Registry::get('example');
my $a=VisLlama::Engines::save_build({engine=>'example',definition_digest=>$d->{digest},name=>'Stable',root=>"$root/a",executable=>"$root/python",runtime_executable=>"$root/native-a",runtime_library_dirs=>["$root/tokenizer"]});
my $b=VisLlama::Engines::save_build({engine=>'example',definition_digest=>$d->{digest},name=>'Experimental',root=>"$root/b",executable=>"$root/python",runtime_executable=>"$root/native-b"});
my $library_key=$^O eq 'MSWin32'?'PATH':'LD_LIBRARY_PATH';my $original_library_path=$ENV{$library_key}//'';my $native_env;my $calls=0;local *VisLlama::Command::capture=sub {$native_env=$ENV{$library_key} if $_[1] eq "$root/native-a";$calls++;$?=0;$VisLlama::Command::LAST_STDERR='';return $_[1] eq "$root/native-a"?"  --workers INT  Worker count\n  --context INT  Context\n  --fast  Enable fast mode\n  --opaque SOMETHING  Unknown type\n  --host VALUE  Host\n":"  --batch INT  Batch\n";};
my $before=VisLlama::Engine::Registry::json()->encode(VisLlama::Engine::Definitions::raw($d));
my $e=VisLlama::Engines::discover($a->{id});is($e->{capabilities}{status},'current','Discovery tied to installed revision');is($calls,1,'Explicit discovery runs once');like($native_env,qr/^\Q$root\E\/tokenizer/,'Native discovery uses registered runtime libraries');is($ENV{$library_key}//'',$original_library_path,'Discovery leaves controller environment unchanged');
ok(-f "$root/presets/engines/example/engine.json",'Editable base beside additive in retained storage');
is(VisLlama::Engine::Registry::json()->encode(VisLlama::Engine::Definitions::raw(VisLlama::Engine::Registry::get('example'))),$before,'Base definition not expanded or overwritten by discovery');
my $pa=VisLlama::Engine::Discovery::path($a);ok(-f $pa,'Per-build additive written');like($pa,qr/additive-engine-.*\.json$/,'File uses stable ID');
my @keys=map {$_->{key}} @{$e->{fields}};ok(grep($_ eq 'discovered-native-context',@keys),'Typed native option becomes control');ok(!grep($_ eq 'discovered-native-opaque'||$_ eq 'discovered-native-host',@keys),'Ambiguous/excluded options not guessed');is(scalar(grep {$_->{flag} && $_->{flag} eq '--workers'} @{$e->{fields}}),1,'Base field wins target collision');
my ($known)=grep {$_->{key} eq 'workers'} @{$e->{fields}};ok($known->{available},'Declared field verified from native help');
VisLlama::Engines::discover($b->{id});isnt(VisLlama::Engine::Discovery::path($b),$pa,'Two installations have separate evidence');
my $other=VisLlama::Engines::capabilities($b);ok(!grep($_->{key} eq 'discovered-native-context',@{$other->{fields}}),'Experimental never inherits stable options');
$a=VisLlama::Engines::save_build({%$a,name=>'Renamed'});is(VisLlama::Engine::Discovery::path($a),$pa,'Renaming preserves additive identity');is(VisLlama::Engines::capabilities($a)->{capabilities}{status},'current','Rename does not invalidate executable evidence');
my $p={engine=>'example',build=>$a->{id},alias=>'created',model=>"$root/model",config_mode=>'create',settings=>{format=>'native',tokenizer=>"$root/tokenizer",'discovered-native-context'=>8192,dependent=>JSON::PP::true},native_config=>{extra=>{kept=>1},args=>['--pack','old','--unknown','literal $(safe)']}};
my $plan=VisLlama::Engines::preview($p);is($plan->{config}{exe},"$root/native-a",'New config chooses build-native executable');is($plan->{config}{extra}{kept},1,'Unknown native config retained');is_deeply($plan->{config}{args},['--unknown','literal $(safe)','--context','8192','--native',"$root/model"],'Model path and controls mapped without shell or conflicting pack selector');ok(!exists $plan->{config}{dependent},'Inactive dependency not emitted');
VisLlama::Engines::save_preset($p);my $saved=VisLlama::Catalog::load_router_presets()->[0];is($saved->{config_mode},'create','Mode saved in canonical catalog');is($calls,2,'Preview/save never discover');
{
 {package DiscoveryTestHandle;sub GetProcessID {9876}sub GetExitCode {$_[1]=259;1}}
 local *VisLlama::Platform::launch=sub {bless {},'DiscoveryTestHandle'};
 local *VisLlama::Engines::http_json=sub {$_[1] eq '/health'?{loaded=>JSON::PP::true}:{data=>[{id=>'created'}]}};
 local *VisLlama::ProcessState::stop_owned_process=sub {1};
 my $eng={engine=>'example',build=>$a->{id},models=>['created'],port=>8123};$STATE->{router_engines}={'extension:created'=>$eng};
 VisLlama::Engines::load('created',$eng);is(VisLlama::Engines::status($eng),'loaded','Created preset launches through existing owned lifecycle');
 my $actual=VisLlama::Config::read_json_file($eng->{plan}{config_path},{});is_deeply($actual->{args},$plan->{config}{args},'Generated launch artifact matches preview controls/model path');
 VisLlama::Engines::unload($eng);ok(!$eng->{proc},'Created model unload retains confirmed ownership rules');$STATE={};
}
my $wrong=dclone($p);$wrong->{native_config}{exe}="$root/native-b";eval {VisLlama::Engines::validate_preset($wrong,1)};like($@,qr/Native executable differs/,'Discovered controls cannot target a different native executable');
my $backup=VisLlama::Engine::Registry::read_json($pa);unlink $pa;
eval {VisLlama::Engines::validate_preset($saved,1)};like($@,qr/Selected engine options are unavailable/,'Deleting additive cannot silently drop saved discovered settings');
put($pa,encode_json($backup));
$p->{settings}{format}='pack';ok(VisLlama::Engines::preview($p)->{config}{dependent},'Dependency applies when condition matches');
my $missing=dclone($p);delete $missing->{settings}{tokenizer};eval {VisLlama::Engines::preview($missing)};like($@,qr/configuration is incomplete/,'Missing required prepared files rejected');
put("$root/native-a",'new revision');is(VisLlama::Engines::capabilities($a)->{capabilities}{status},'stale','Native executable changes invalidate additive');
my $stale=VisLlama::Engines::preview($p);ok(grep($_ eq 'discovered-native-context',@{$stale->{inactive_fields}}),'Stale added values retained as inactive');
eval {VisLlama::Engines::validate_preset($p,1)};like($@,qr/Selected engine options are unavailable/,'Stale selected additions cannot silently vanish during launch');
my $edited=VisLlama::Engine::Definitions::raw(VisLlama::Engine::Registry::get('example'));$edited->{name}='User edited';my $new=VisLlama::Engine::Definitions::save('example',$edited,$d->{digest});is($new->{name},'User edited','User base edit persists separately from bundle');is(VisLlama::Engines::capabilities($b)->{capabilities}{status},'stale','Base changes invalidate both installations');
my $fresh=VisLlama::Engine::Registry::get('example');is($fresh->{name},'User edited','Local definition remains active after registry reload');
my $schema={id=>'machine',parser=>'schema-json',target=>'config'};my ($fields)=VisLlama::Engine::Discovery::parse_schema(encode_json({fields=>[{key=>'context',label=>'Context',type=>'integer',binding=>'config',path=>['context']}]}),$schema);is($fields->[0]{path}[0],'context','Machine-readable mapping is explicit, not inferred');
$schema->{target}='flag';eval {VisLlama::Engine::Discovery::parse_schema(encode_json({fields=>$fields}),$schema)};like($@,qr/binding does not match/,'Machine schema cannot change declared target');
# Exercise the shipped Strata definition rather than only the generic fixture.
make_path("$root/engines/strata","$root/a/serve");
my $strata=VisLlama::Engine::Registry::read_json("$RealBin/../engines/strata/engine.json");put("$root/engines/strata/engine.json",encode_json($strata));put("$root/a/serve/server.py",'# fixture');
my $sd=VisLlama::Engine::Registry::get('strata');my $sb=VisLlama::Engines::save_build({engine=>'strata',definition_digest=>$sd->{digest},name=>'Strata',root=>"$root/a",executable=>"$root/python",runtime_executable=>"$root/native-a"});
ok(VisLlama::Engines::definition_compatible({%$sb,definition_digest=>$sd->{compatible_definition_digests}[0]},$sd),'Exact previous bundled Strata definition remains compatible');
my $sp={alias=>'strata-created',engine=>'strata',build=>$sb->{id},model=>"$root/model",config_mode=>'create',settings=>{'model-format'=>'native','tokenizer-directory'=>"$root/tokenizer"},native_config=>{}};
eval {VisLlama::Engines::preview($sp)};like($@,qr/configuration is incomplete/,'Strata tokenizer artifacts required, not just an empty directory');
put("$root/tokenizer/$_",'{}') for qw(vocab.json merges.txt token_type.json);
my $strata_plan=VisLlama::Engines::preview($sp);is_deeply($strata_plan->{config}{args},['--native',"$root/model"],'Shipped Strata definition creates config with selected model');is($strata_plan->{config}{exe},"$root/native-a",'Strata uses native executable separately from Python');
$sp->{model}="$root/tokenizer";eval {VisLlama::Engines::preview($sp)};like($@,qr/selected model format/,'Native-file format rejects a directory');
$sp->{config_mode}='import';$sp->{native_config}={exe=>"$root/native-b",args=>['--pack','original'],tokenizer=>'original-tokenizer',other=>1};$sp->{settings}={};
is_deeply(VisLlama::Engines::preview($sp)->{config}{args},['--pack','original'],'Legacy/import paths are not rewritten by new model binding');
done_testing();
