# GPL-3.0-only. Exercise real mixed Router orchestration with owned-handle fixtures.
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(decode_json);
use VisLlama::Process ();
use VisLlama::Context qw(%CFG $STATE);
use VisLlama::Config ();
use VisLlama::Storage ();
use VisLlama::Engines ();
my $root=tempdir(CLEANUP=>1);make_path("$root/native");
for my $file ('llama_openai_proxy.pl','native/llama-server') {open my $f,'>',"$root/$file" or die $!;close $f;}
no warnings 'redefine';
local *VisLlama::Paths::app_base_dir=sub {$root};
%CFG=(builds=>{native=>"$root/native"},build_order=>['native'],listen_port=>9090);
$STATE={};
my @presets=({alias=>'external-first',engine=>'example',build=>'engine-example',model=>'/one',enabled=>1,load_on_startup=>1,ui=>{},options=>[]},
 {alias=>'native-second',build=>'native',model=>'/two',enabled=>1,load_on_startup=>1,ui=>{},options=>[]},
 {alias=>'external-idle',engine=>'example',build=>'engine-example',model=>'/three',enabled=>1,load_on_startup=>0,ui=>{},options=>[]});
local *VisLlama::Catalog::load_router_presets=sub {\@presets};
local *VisLlama::ModelStats::metrics_supported=sub {0};
local *VisLlama::Builds::find_server_exe=sub {"$root/native/llama-server"};
my $port=8100;local *VisLlama::Process::find_free_loopback_port=sub {++$port};
my (@events,@launches);my $pid=700;
{package RouterEngineHandle;sub GetProcessID {$_[0]{pid}}sub GetExitCode {$_[1]=259;1}}
local *VisLlama::Platform::launch=sub {push @launches,$_[0];bless {pid=>++$pid},'RouterEngineHandle'};
local *VisLlama::Router::load_router_model_centrally=sub {push @events,'load:'.$_[0];$_[1]{proc}=bless {pid=>++$pid},'RouterEngineHandle';$_[1]{pid}=$pid;{}};
local *VisLlama::Router::wait_router_model_loaded=sub {push @events,'ready:'.$_[1];1};
VisLlama::Process::start_router_impl({});
is_deeply(\@events,['load:external-first','ready:external-first','load:native-second','ready:native-second'],'Catalog order crosses engine families with readiness barrier');
is(scalar @launches,2,'One native Router and one public proxy; extension launch delegated');
is(scalar keys %{$STATE->{router_engines}},3,'Native group and distinct extension instances retained');
ok(!$STATE->{router_engines}{'extension:external-idle'}{proc},'On-demand instance remains unloaded');
my $map=decode_json(VisLlama::Storage::raw_read($STATE->{router_route_map}));
ok($map->{models}{'external-first'}{managed},'Extension routes through serialized control loader');ok(!$map->{models}{'native-second'}{managed},'Native non-Calculated path unchanged');
is(scalar keys %{$map->{models}},3,'One public map includes all presets');
my %ports=map {$_->{port}=>1} values %{$STATE->{router_engines}};is(scalar keys %ports,3,'Distinct ports for unloaded and loaded instances');
my @stopped;local *VisLlama::ProcessState::stop_owned_process=sub {push @stopped,$_[1] if $_[0];1};local *VisLlama::ModelStats::sample_running_model_stats=sub {};
VisLlama::Process::stop_server();is(scalar @stopped,3,'Stop covers native, extension and public proxy ownership');
is_deeply($STATE->{router_engines},{},'Confirmed stop clears registry');
@presets=grep {VisLlama::Engines::external($_)} @presets;
%CFG=(builds=>{},build_order=>[],listen_port=>9090);$STATE={};@events=();@launches=();
VisLlama::Process::start_router_impl({});
is(scalar @launches,1,'Engine-only Router starts just one public proxy without any llama.cpp registration');
is_deeply(\@events,['load:external-first','ready:external-first'],'Engine-only startup loads selected model');
is(scalar keys %{$STATE->{router_engines}},2,'Engine-only catalog retains loaded and idle models');
VisLlama::Process::stop_server();
done_testing();
