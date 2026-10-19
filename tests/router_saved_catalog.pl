# Exercise real group-INI publication before native load using a synthetic engine.
# No Windows process, CUDA placement or native llama.cpp reload is tested here.
use strict;use warnings;use Test::More;use FindBin qw($RealBin);use lib "$RealBin/../lib";
use File::Temp qw(tempdir);use VisLlama::Router ();use VisLlama::Catalog ();use VisLlama::GPUIsolation ();
my $root=tempdir(CLEANUP=>1);my $path="$root/group.ini";
my $p={alias=>'target',build=>'test',enabled=>1,model=>'target.gguf',ui=>{},options=>[['ctx-size',8192]]};
my $items=[$p];my $eng={build=>'test',preset_file=>$path};my @calls;my $state='unloaded';my $fail_reload=0;
sub read_ini {open my $f,'<:raw',$path or die $!;local $/;return <$f>}
{
 no warnings 'redefine';
 local *VisLlama::Catalog::load_router_presets=sub {$items};
 local *VisLlama::Router::router_model_status=sub {$state};
 local *VisLlama::Router::router_http_engine=sub {
  my ($e,$method,$endpoint)=@_;push @calls,$endpoint;
  if($endpoint eq '/v1/models?reload=1'){like(read_ini(),qr/ctx-size = 8192/,'Saved settings published before reload');die 'fixture reload failed' if $fail_reload;}
  return {};
 };
 open my $f,'>:raw',$path or die $!;print $f "model-draft = old.gguf\nspec-type = draft-simple\n";close $f;
 VisLlama::Router::load_router_model_centrally('target',$eng);
 is_deeply(\@calls,['/v1/models?reload=1','/models/load'],'Ordinary load reloads saved catalog before spawn');
 unlike(read_ini(),qr/model-draft|spec-type/,'Removed speculative options disappear from actual group INI');
 @calls=();$fail_reload=1;eval {VisLlama::Router::load_router_model_centrally('target',$eng)};
 like($@,qr/fixture reload failed/,'Native reload failure is reported');is_deeply(\@calls,['/v1/models?reload=1'],'Failed reload never starts stale child');
 $fail_reload=0;@calls=();$state='loaded';VisLlama::Router::load_router_model_centrally('target',$eng);
 is_deeply(\@calls,[],'Resident model is not silently reconfigured or restarted');
 $state='unloaded';$eng->{group_key}='changed';eval {VisLlama::Router::load_router_model_centrally('target',$eng)};
 like($@,qr/GPU selection changed/,'Changed visibility requires explicit apply/restart');is_deeply(\@calls,[],'Changed visibility cannot launch with old mapping');
 delete $eng->{group_key};$eng->{preset_file}="$root/missing/group.ini";
 # Inject storage publication failure, preserving the existing catalog writer.
 local *VisLlama::Storage::write=sub {die 'fixture publication failed'};
 eval {VisLlama::Router::load_router_model_centrally('target',$eng)};
 like($@,qr/fixture publication failed/,'Publication failure is reported');is_deeply(\@calls,[],'Failed publication cannot reload or start');
}
done_testing();
