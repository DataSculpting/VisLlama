# GPL-3.0-only. Synthetic filesystem and bounded probe transport, no GPU evidence.
use strict;use warnings;use Test::More;use FindBin qw($RealBin);use lib "$RealBin/../lib";
use File::Temp qw(tempdir);use File::Path qw(make_path);use JSON::PP ();use Storable qw(dclone);
use VisLlama::Engine::Libraries ();use VisLlama::Engines ();use VisLlama::Context qw(%CFG $STATE);
my $root=tempdir(CLEANUP=>1);make_path(map {"$root/$_"} qw(engines/example install/venv/Scripts install/venv/Lib/site-packages/nvidia/cublas/bin install/venv/Lib/site-packages/nvidia/cuda_runtime/bin imported edited));
sub put {open my $f,'>',$_[0] or die $!;print {$f} $_[1];close $f;}
put("$root/install/native",'fixture');put("$root/install/venv/Scripts/python",'fixture');put("$root/model",'fixture');
chmod 0755,"$root/install/native","$root/install/venv/Scripts/python";
my $d={schema_version=>'1.1',definition_version=>'1.0.0',id=>'example',name=>'Example',platforms=>['windows','linux'],driver=>'native-json',argv=>['${executable}','--config','${runtime_config}'],concurrency=>'independent',readiness=>{path=>'/health',equals=>{ok=>JSON::PP::true}},
 new_config=>{exe=>'${runtime_executable}',lib_dirs=>'${runtime_library_dirs}'},runtime_executable_path=>['exe'],runtime_libraries=>{config_path=>['lib_dirs'],base_path=>['cwd'],interpreter_relative=>['../Lib/site-packages/nvidia/cublas/bin','../Lib/site-packages/nvidia/cuda_runtime/bin']},fields=>[{key=>'libraries',label=>'Libraries',type=>'json-array',binding=>'config',path=>['lib_dirs']}],discovery=>[{id=>'native',argv=>['${runtime_executable}','--help'],parser=>'help',target=>'config-flag',path=>['args'],timeout=>3}]};
put("$root/engines/example/engine.json",JSON::PP::encode_json($d));
no warnings qw(redefine once);local *VisLlama::Paths::app_base_dir=sub {$root};local %CFG=(builds=>{});$STATE={};
$d=VisLlama::Engine::Registry::get('example');my $b=VisLlama::Engines::save_build({engine=>'example',definition_digest=>$d->{digest},name=>'One',root=>"$root/install",executable=>"$root/install/venv/Scripts/python",runtime_executable=>"$root/install/native"});
my $p={engine=>'example',build=>$b->{id},alias=>'model',model=>"$root/model",config_mode=>'import',settings=>{},native_config=>{exe=>"$root/install/native",cwd=>$root,lib_dirs=>['imported']}};
my $original=dclone($p);my $l=VisLlama::Engine::Libraries::resolve($b,$d,$p);
is_deeply($l->{directories},["$root/imported"],'Relative imported library folder resolved against native cwd');is($l->{folders}[0]{source},'Imported','Imported source shown');is_deeply($p,$original,'Inspection never edits source or settings');
$p->{settings}{libraries}=["$root/edited"];$l=VisLlama::Engine::Libraries::resolve($b,$d,$p);is_deeply($l->{directories},["$root/edited"],'Current named field overrides imported folder');is($l->{folders}[0]{source},'User-selected','Override provenance');
my $relative=dclone($original);$relative->{native_config}{cwd}='..';$relative->{native_config}{exe}='install/native';is_deeply(VisLlama::Engine::Libraries::resolve($b,$d,$relative)->{directories},["$root/imported"],'Relative cwd and executable resolve against registered root');
$p->{settings}{libraries}=undef;$l=VisLlama::Engine::Libraries::resolve($b,$d,$p);is_deeply($l->{directories},[],'Explicit omission prevents fallback and detection');
$p->{settings}{libraries}=[];is_deeply(VisLlama::Engine::Libraries::resolve($b,$d,$p)->{directories},[],'Explicit empty list is preserved');
delete $p->{settings}{libraries};delete $p->{native_config}{lib_dirs};$l=VisLlama::Engine::Libraries::resolve($b,$d,$p);is(scalar(@{$l->{directories}}),2,'Missing libraries detected beside selected interpreter');is($l->{folders}[0]{source},'Detected','Detection provenance');
make_path("$root/env [brackets]/Scripts","$root/env [brackets]/Lib/site-packages/nvidia/cublas/bin");put("$root/env [brackets]/Scripts/python",'fixture');my $special={%$b,executable=>"$root/env [brackets]/Scripts/python"};is(scalar(@{VisLlama::Engine::Libraries::resolve($special,$d)->{directories}}),1,'Installation spaces and glob metacharacters are literal');
my $created={%$p,config_mode=>'create',native_config=>{}};is(scalar(@{VisLlama::Engine::Libraries::resolve($b,$d,$created)->{directories}}),2,'Empty generated defaults also permit detection');
my $defaults={%$b,runtime_library_dirs=>["$root/imported"]};is_deeply(VisLlama::Engine::Libraries::resolve($defaults,$d,$p)->{directories},["$root/imported"],'Absent imported key uses build defaults first');
$p->{native_config}{lib_dirs}=["$root/missing"];$l=VisLlama::Engine::Libraries::resolve($b,$d,$p);is_deeply($l->{missing},["$root/missing"],'Missing folder identified without launching');
my $calls=0;my $key=$^O eq 'MSWin32'?'PATH':'LD_LIBRARY_PATH';my $parent=$ENV{$key}//'';my $seen;
local *VisLlama::Command::capture=sub {$calls++;$seen=$ENV{$key};$?=0;$VisLlama::Command::LAST_STDERR='';return "  --workers INT  Worker count\n";};
eval {VisLlama::Engines::discover($b->{id},$p)};like($@,qr/Some library folders are missing/,'Missing library blocks only explicit discovery with clear error');is($calls,0,'Missing directory never executes a probe');
$p->{native_config}{lib_dirs}=["$root/imported"];
my $effective=VisLlama::Engines::discover($b->{id},$p);like($seen,qr/^\Q$root\/imported\E/,'Probe actually receives model library path');is($ENV{$key}//'',$parent,'Controller environment unchanged');is_deeply(VisLlama::Engines::build($b->{id})->{runtime_library_dirs},[],'Model discovery never rewrites build defaults');
ok($effective->{capabilities}{library_digest},'Evidence records environment digest');
$p->{settings}{'discovered-native-workers'}=4;eval {VisLlama::Engines::validate_preset($p,1)};is($@,'','Matching discovered model environment accepted');
$p->{settings}{libraries}=["$root/edited"];eval {VisLlama::Engines::validate_preset($p,1)};like($@,qr/Library folders differ/,'Different model environment cannot borrow strict evidence');
$p->{native_config}{exe}="$root/model";eval {VisLlama::Engines::discover($b->{id},$p)};like($@,qr/model inference executable differs/,'Imported executable never substitutes for registered probe');is($calls,1,'Mismatched executable not run');
my $bad=dclone($d);$bad->{runtime_libraries}{interpreter_relative}=['../../../../../../escape'];delete @{$bad}{qw(digest definition_file default_controls_available bundled_definition_version)};eval {VisLlama::Engine::Registry::validate($bad)};like($@,qr/Invalid library detection rules/,'Unbounded detection rules rejected');
my $legacy=dclone($d);delete $legacy->{runtime_libraries};is_deeply(VisLlama::Engine::Libraries::rules($legacy)->{config_path},['lib_dirs'],'Old explicit build placeholder still maps imported libraries');
# The real route merges manually chosen build folders with detected folders.
require VisLlama::API::Engines;my $reply;local *VisLlama::HTTP::json_response=sub {$reply=$_[2];1};
VisLlama::API::Engines::handle(undef,'/api/engine-library-folders',{engine=>'example',root=>$b->{root},executable=>$b->{executable},runtime_library_dirs=>["$root/imported","$root/missing"]});
is(scalar(@{$reply->{libraries}{folders}}),4,'Build detection adds to manually selected folders');is($reply->{libraries}{folders}[0]{source},'User-selected','Build selection provenance retained');is_deeply($reply->{libraries}{missing},["$root/missing"],'Real route flags missing manual folders');is($calls,1,'Read-only route never runs a probe');
# Known old defaults can borrow only explicitly declared updated detection rules.
my $old=VisLlama::Engine::Definitions::raw($d);delete $old->{runtime_libraries};require Digest::SHA;my $old_digest=Digest::SHA::sha256_hex(VisLlama::Engine::Registry::json()->encode($old));my $bundle=VisLlama::Engine::Definitions::raw($d);$bundle->{previous_default_digests}=[$old_digest];put("$root/engines/example/engine.json",JSON::PP::encode_json($bundle));$old->{digest}=$old_digest;
is(scalar(@{VisLlama::Engine::Libraries::rules($old)->{interpreter_relative}}),2,'Known unchanged legacy default gets read-only detection metadata');$old->{digest}='edited';is_deeply(VisLlama::Engine::Libraries::rules($old)->{interpreter_relative},[],'Custom definition never silently inherits detection rules');
done_testing();
