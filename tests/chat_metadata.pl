use strict;use warnings;use Test::More;use FindBin qw($RealBin);use lib "$RealBin/../lib";
use VisLlama::Chat ();use VisLlama::Context qw($STATE);
my ($reply,@paths);my $engine={models=>['alpha'],port=>18081,ready=>1};
{
 no warnings 'redefine';
 local *VisLlama::ProcessState::proc_running=sub {1};
 local *VisLlama::ProcessState::proxy_running=sub {1};
 local *VisLlama::ProcessState::router_engine_running=sub {1};
 local *VisLlama::Router::router_engine_for_model=sub {$engine};
 local *VisLlama::HTTP::json_response=sub {$reply=$_[2]};
 local *VisLlama::Chat::engine_metadata=sub {push @paths,$_[1];return $_[1] eq '/v1/models'?{data=>[{id=>'alpha',status=>{value=>'loaded'}}]}:{default_generation_settings=>{n_ctx=>8192}}};
 local $STATE->{mode}='router';local $STATE->{router_host}='0.0.0.0';local $STATE->{router_port}=18080;local $STATE->{router_engines}={test=>$engine};
 VisLlama::Chat::handle(undef,'/api/chat-info',{model=>'alpha'});
 ok($reply->{available},'Active owned Router is available');is_deeply($reply->{models},[{id=>'alpha'}],'Active engine catalog supplies public aliases');is($reply->{context_size},8192,'Observed props supplies context');is_deeply(\@paths,['/v1/models','/props?autoload=false&model=alpha'],'Metadata does not autoload');is($engine->{ready},1,'Optional probes leave readiness alone');
 @paths=();local *VisLlama::Chat::engine_metadata=sub {push @paths,$_[1];return {data=>[{id=>'alpha',status=>{value=>'unloaded'}}]}};
 VisLlama::Chat::handle(undef,'/api/chat-info',{model=>'alpha'});is($reply->{context_size},undef,'Unloaded context stays unknown');is_deeply(\@paths,['/v1/models'],'Unloaded model is not probed for props');
 local *VisLlama::ProcessState::proc_running=sub {0};VisLlama::Chat::handle(undef,'/api/chat-info',{});ok(!$reply->{available},'Stopped serving is unavailable');is_deeply($reply->{models},[],'Saved snapshots do not supply fictitious running models');
}
done_testing();
