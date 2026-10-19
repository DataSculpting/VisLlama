# Real saved JSON/catalog operations with fixture HTTP replies. No Docker/GPU.
use strict;use warnings;use Test::More;use FindBin qw($RealBin);use lib "$RealBin/../lib";
use File::Temp qw(tempdir);use JSON::PP ();use VisLlama::Config ();use VisLlama::Catalog ();use VisLlama::API::Settings ();use VisLlama::Context qw(%CFG);
plan skip_all=>'Linux Docker configuration contracts' unless $^O eq 'linux';
my $root=tempdir(CLEANUP=>1);mkdir "$root/presets";my $reply;
{
 no warnings 'redefine';
 local *VisLlama::Paths::app_base_dir=sub {$root};
 local *VisLlama::HTTP::json_response=sub {$reply=$_[2];return $reply};
 local *VisLlama::HTTP::fail_json=sub {$reply={ok=>0,error=>$_[1]};return $reply};
 VisLlama::Config::load_runtime_configs();
 VisLlama::API::Settings::handle(undef,'/api/build-save',{alias=>'Spark',type=>'docker',image=>'fixture/server:tag'});
 ok($reply->{ok},'Docker alias saved without a discovery root or native build folder');
 is($CFG{builds}{Spark},'docker://fixture/server:tag','Same build alias map resolves Docker image');
 my ($path)=VisLlama::Config::runtime_config_paths();my $saved=VisLlama::Config::read_json_file($path,[]);
 is_deeply($saved,[{alias=>'Spark',path=>'docker://fixture/server:tag'}],'Existing alias/path JSON shape retained');
 is($CFG{discovery_root},'','No discovery root requirement introduced');
 VisLlama::Config::write_json_file_ascii((VisLlama::Catalog::router_paths())[0],[{alias=>'model',build=>'Spark',model=>"$root/model.gguf",enabled=>0,options=>[],ui=>{build=>'Spark'}}]);
 VisLlama::API::Settings::handle(undef,'/api/build-delete',{alias=>'Spark'});
 ok(!$reply->{ok},'Referenced Docker build deletion blocked');like($reply->{error},qr/model/,'Error names the affected model preset');
 VisLlama::API::Settings::handle(undef,'/api/build-save',{alias=>'Renamed',old_alias=>'Spark',type=>'docker',image=>'fixture/server:tag'});
 ok($reply->{ok},'Docker alias rename saved');
 my $models=VisLlama::Catalog::load_router_presets();is($models->[0]{build},'Renamed','Saved model reference follows alias rename');is($models->[0]{ui}{build},'Renamed','Saved UI build value follows alias rename');
 VisLlama::Config::write_json_file_ascii((VisLlama::Catalog::router_paths())[0],[]);
 {local *VisLlama::ProcessState::proc_running=sub {1};VisLlama::API::Settings::handle(undef,'/api/build-delete',{alias=>'Renamed'});ok(!$reply->{ok},'Final alias deletion requires managed serving to stop');ok(exists $CFG{builds}{Renamed},'Active runtime cannot be left with zero build aliases');}
 {local *VisLlama::ProcessState::proc_running=sub {1};local *VisLlama::Engines::builds=sub {[{id=>'engine-fixture'}]};
 VisLlama::API::Settings::handle(undef,'/api/build-delete',{alias=>'Renamed'});
 ok($reply->{ok},'Last unused native alias can be removed while an extension-only Router runs');}
 ok($reply->{ok},'Last unreferenced alias can be removed');is_deeply($CFG{build_order},[],'Empty build list reaches UI setup gate');
 mkdir "$root/native";open my $f,'>',"$root/native/llama-server";print $f '# fixture';close $f;chmod 0755,"$root/native/llama-server";
 VisLlama::API::Settings::handle(undef,'/api/build-save',{alias=>'Native',path=>"$root/native"});ok($reply->{ok},'Native build addition remains supported');
 VisLlama::API::Settings::handle(undef,'/api/build-save',{alias=>'Docker',type=>'docker',image=>'fixture/server:tag'});ok($reply->{ok},'Docker is additive to native aliases');
 is_deeply($CFG{build_order},['Native','Docker'],'Mixed preset order retained');
}
done_testing();
