# GPL-3.0-only. Real catalog/API persistence, synthetic installations, no inference.
use strict;use warnings;use Test::More;use FindBin qw($RealBin);use lib "$RealBin/../lib";
use File::Temp qw(tempdir);use File::Path qw(make_path);use JSON::PP qw(encode_json);
use VisLlama::Engines ();use VisLlama::API ();use VisLlama::API::Models ();use VisLlama::Catalog ();use VisLlama::Context qw(%CFG $STATE);use VisLlama::Engine::Registry ();
my $root=tempdir(CLEANUP=>1);make_path("$root/engines/one","$root/engines/two","$root/install","$root/models");
sub put {open my $f,'>',$_[0] or die $!;print {$f} $_[1];close $f;}
put("$root/models/a.gguf",'fixture');put("$root/install/server",'fixture');chmod 0755,"$root/install/server";
for my $id (qw(one two)) {put("$root/engines/$id/engine.json",encode_json({schema_version=>'1.0',definition_version=>'1.0.0',id=>$id,name=>$id,platforms=>['linux','windows'],driver=>'native-json',concurrency=>'independent',argv=>['${executable}','--config','${runtime_config}'],fields=>[],config_overrides=>{},readiness=>{path=>'/health',equals=>{ready=>JSON::PP::true}}}));}
no warnings 'redefine';local *VisLlama::Paths::app_base_dir=sub {$root};%CFG=(model_root=>"$root/models",builds=>{native=>"$root/install"},build_order=>['native']);local $VisLlama::Context::STATE={};
my @builds;for my $id (qw(one two)){my $d=VisLlama::Engine::Registry::get($id);push @builds,VisLlama::Engines::save_build({engine=>$id,name=>$id,root=>"$root/install",executable=>"$root/install/server",definition_digest=>$d->{digest}});}
my $old={alias=>'middle',build=>'native',model=>"$root/models/a.gguf",enabled=>JSON::PP::false,load_on_startup=>JSON::PP::true,stop_timeout=>23,options=>[],ui=>{}};
my $prefix={%$old,alias=>'before'},my $suffix={%$old,alias=>'after'};
VisLlama::Catalog::save_router_presets([$prefix,$old,$suffix]);
my $r={alias=>'renamed',original_alias=>'middle',build=>$builds[0]{id},model=>"$root/models/a.gguf",native_config=>{opaque=>[1,2]},settings=>{},config_mode=>'import'};
eval {VisLlama::Engines::save_preset($r)};like($@,qr/Review the selected engine settings/,'Different engine requires explicit replacement intent');
is_deeply([map {$_->{alias}} @{VisLlama::Catalog::load_router_presets()}],[qw(before middle after)],'Rejected change leaves durable order intact');
$r->{replace_engine}=1;$STATE->{router_engines}={owned=>{engine=>'one',build=>$builds[0]{id}}};
eval {VisLlama::Engines::save_preset($r)};like($@,qr/Stop Router/,'Owned engine state prevents conversion');
$STATE->{router_engines}={};$STATE->{proxy_proc}=bless {},'FixtureProxy';
eval {VisLlama::Engines::save_preset($r)};like($@,qr/Stop Router/,'Proxy-only ownership also prevents conversion');delete $STATE->{proxy_proc};
my $items=VisLlama::Engines::save_preset($r);is_deeply([map {$_->{alias}} @$items],[qw(before renamed after)],'Native to external rename preserves position');
is($items->[1]{engine},'one','Selected family stored');ok(!$items->[1]{enabled},'Disabled state retained');ok($items->[1]{load_on_startup},'Startup retained');is($items->[1]{stop_timeout},23,'Stop timeout retained across engine conversion');is_deeply($items->[1]{native_config}{opaque},[1,2],'Native config retained as entered');
$r={%$r,alias=>'renamed',original_alias=>'renamed',build=>$builds[1]{id},native_config=>{different=>1}};$items=VisLlama::Engines::save_preset($r);is($items->[1]{engine},'two','External to different external family supported');ok(!exists $items->[1]{native_config}{opaque},'Old family config not merged into new family');
my $native={alias=>'back-native',original_alias=>'renamed',build=>'native',model=>"$root/models/a.gguf",args=>[],ui=>{gpuPriority=>'manual'},replace_engine=>1};
my ($reply,$status);local *VisLlama::HTTP::json_response=sub {($status,$reply)=($_[1],$_[2]);};local *VisLlama::HTTP::fail_json=sub {die $_[1]};
$STATE->{router_engines}={owned=>{}};eval {VisLlama::API::Models::handle(undef,'/api/router-preset-save',$native)};like($@,qr/Stop Router/,'Native endpoint enforces same conversion ownership rule');$STATE->{router_engines}={};
VisLlama::API::Models::handle(undef,'/api/router-preset-save',$native);is($status,200,'External to native save accepted');$items=VisLlama::Catalog::load_router_presets();is_deeply([map {$_->{alias}} @$items],[qw(before back-native after)],'Native conversion rename keeps startup order');ok(!exists($items->[1]{engine})&&!exists($items->[1]{native_config}),'Native preset has established native format');ok(!$items->[1]{enabled}&&$items->[1]{load_on_startup},'Native conversion retains lifecycle choices');
# The narrow load check validates only an explicit load/reload request and persists nothing.
my $checked=0;local *VisLlama::Engines::validate_preset=sub {$checked++;is($_[0]{engine},'one','Load check derives family from registered build');is($_[1],1,'Load check uses launch-level validation');};
ok(VisLlama::API::known_route('/api/engine-load-check'),'Load check explicitly routed');VisLlama::API::handle_api(undef,'/api/engine-load-check',{build=>$builds[0]{id},model=>"$root/models/a.gguf"});is($checked,1,'Explicit check performed');is_deeply([map {$_->{alias}} @{VisLlama::Catalog::load_router_presets()}],[qw(before back-native after)],'Load check leaves catalog unchanged');
done_testing();
