# Optional native Linux lifecycle acceptance with HTTP fixtures. Requires procfs;
# no real GGUF/CUDA inference or browser behavior is represented by this test.
use strict;use warnings;use Test::More;use FindBin qw($RealBin);use lib "$RealBin/../lib";
use File::Temp qw(tempdir);use File::Copy qw(copy);use JSON::PP qw(decode_json encode_json);use HTTP::Tiny;
use Time::HiRes qw(time);use VisLlama::Process ();use VisLlama::Platform::Linux ();
use VisLlama::Config ();use VisLlama::Catalog ();use VisLlama::Context qw(%CFG $STATE);
plan skip_all=>'Native Linux lifecycle needs /proc; execute on a normal Linux host' unless $^O eq 'linux' && -r '/proc/self/stat';
my $root=tempdir(CLEANUP=>1);
sub put {open my $f,'>:raw',$_[0] or die $!;print {$f} $_[1];close $f;}
sub readfile {open my $f,'<:raw',$_[0] or die $!;local $/;return <$f>;}
my $cleanup=1;END {eval {VisLlama::Process::stop_server()} if $cleanup;}
mkdir "$root/A";mkdir "$root/B";
for my $build(qw(A B)){copy("$RealBin/fixtures/linux/server.pl","$root/$build/llama-server") or die $!;chmod 0755,"$root/$build/llama-server";}
copy("$RealBin/../llama_openai_proxy.pl","$root/llama_openai_proxy.pl") or die $!;
symlink "$RealBin/../lib","$root/lib" or die $!;
put("$root/model.gguf",'fixture only');
no warnings 'redefine';local *VisLlama::Paths::app_base_dir=sub {$root};
local $CFG{builds}={A=>"$root/A",B=>"$root/B"};local $CFG{build_order}=['A','B'];local $CFG{model_root}=$root;
local $ENV{VISLLAMA_TEST_EVENT_LOG}="$root/startup-order.log";
my $port=VisLlama::Process::find_free_loopback_port();
VisLlama::Config::save_router_service_config({host=>'127.0.0.1',port=>$port,models_max=>4,autoload=>1});
my @presets=map {{alias=>$_->[0],build=>$_->[1],model=>"$root/model.gguf",enabled=>1,load_on_startup=>$_->[2],options=>[['device','none']],ui=>{}}} (['first','B',1],['second','A',1],['demand','B',0]);
VisLlama::Catalog::save_router_presets(\@presets);
my $status=VisLlama::Process::start_router({});
ok($status->{running} && $status->{proxy_running},'Real native Router engines and public Perl proxy start');
is(readfile("$root/startup-order.log"),"first\nsecond\n",'Catalog startup order spans native engines');
is(scalar(keys %{$STATE->{router_engines}}),2,'One shared Router fronts both native build groups');
my $ua=HTTP::Tiny->new(timeout=>3,no_proxy=>['127.0.0.1']);
my $models=$ua->get("http://127.0.0.1:$port/v1/models");ok($models->{success},'Native public proxy serves model catalog');
is(scalar @{decode_json($models->{content})->{data}},3,'Public models merged across engines');
my @pids=map {$_->{pid}} values %{$STATE->{router_engines}};my $old_proxy=$STATE->{proxy_pid};
VisLlama::Process::restart_proxy_for_compute_cancel();
is_deeply([sort {$a<=>$b} map {$_->{pid}} values %{$STATE->{router_engines}}],[sort {$a<=>$b} @pids],'Stop compute retains engine ownership');
isnt($STATE->{proxy_pid},$old_proxy,'Stop compute replaces only public proxy');
ok(!VisLlama::Process::stop_server()->{running},'Native Router Stop confirms cleanup');
# Direct native launch/crash status uses the actual child signal, not NTSTATUS.
VisLlama::Process::start_server({build=>'A',model=>"$root/model.gguf",args=>['--port',VisLlama::Process::find_free_loopback_port(),'--device','none']});
my $direct=$STATE->{pid};kill 'KILL',-$direct;
my $until=time()+4;while(VisLlama::ProcessState::proc_running() && time()<$until){select undef,undef,undef,.03;}
is($STATE->{last_exit_code},137,'Native SIGKILL crash status retained');
is($STATE->{last_exit_name},'SIGNAL_9','Linux crash is labeled as a signal');
ok($STATE->{crashed},'Unrequested native exit recorded as crash');
# Real App signal handler must stop an engine it started through HTTP.
VisLlama::Config::save_build_config([{alias=>'A',path=>"$root/A"}]);VisLlama::Config::save_model_root_config($root);
my $control_port=VisLlama::Process::find_free_loopback_port();
my $controller=VisLlama::Platform::Linux->launch({exe=>$^X,args=>["$RealBin/fixtures/linux/controller.pl",$root,$control_port],cwd=>$root,log=>"$root/controller.log",env=>{}});
my $base="http://127.0.0.1:$control_port";my $response;$until=time()+5;
while(time()<$until){$response=$ua->post("$base/api/status",{content=>'{}'});last if $response->{success};select undef,undef,undef,.05;}
ok($response->{success},'Real control listener starts');
my $token=decode_json($response->{content})->{runtime_token};
$response=$ua->post("$base/api/start",{headers=>{'content-type'=>'application/json'},content=>encode_json({runtime_token=>$token,mode=>'single',build=>'A',model=>"$root/model.gguf",args=>['--device','none','--port',VisLlama::Process::find_free_loopback_port()]})});
ok($response->{success},'Real API starts a native owned server');
my $child=decode_json($response->{content})->{pid};kill 'TERM',$controller->GetProcessID();
my $exit;$until=time()+6;while(time()<$until){last if $controller->GetExitCode($exit) && $exit!=259;select undef,undef,undef,.05;}
is($exit,0,'App SIGTERM completes normal cleanup');
my $row=VisLlama::Platform::Linux::stat_row($child);ok(!$row || $row->{state}=~/^[ZX]$/,'Controller shutdown leaves no running engine');
$controller->stop();$cleanup=0;done_testing();
