# Validate launcher paths and process ownership with simulated Win32 handles.
# This is not a Windows or GPU hardware test; no commands are executed.
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Temp qw(tempdir);
use File::Spec;
our (@created, @killed, %active);
BEGIN {
    $INC{'Win32.pm'} = __FILE__;
    $INC{'Win32/Process.pm'} = __FILE__;
    *CORE::GLOBAL::system = sub {
        my @args = @_;
        die 'Unexpected system call in process test' unless $args[0] eq 'taskkill';
        push @killed, \@args;
        $active{$args[2]} = 0;
        return 0;
    };
}
{
    package Win32::Process;
    sub import {}
    sub NORMAL_PRIORITY_CLASS { 0x20 }
    sub CREATE_NEW_PROCESS_GROUP { 0x200 }
    sub Create {
        my $pid = 90000 + @main::created;
        push @main::created, [@_[1..5]];
        $main::active{$pid} = 1;
        $_[0] = bless {pid=>$pid}, 'VisLlamaTestProcess';
        return 1;
    }
    package VisLlamaTestProcess;
    sub GetProcessID { $_[0]{pid} }
    sub GetExitCode { $_[1] = $main::active{$_[0]{pid}} ? 259 : 0; return 1 }
}
use VisLlama::Platform ();
BEGIN { no warnings 'redefine'; *VisLlama::Platform::windows=sub {1}; }
use VisLlama::Process ();
use VisLlama::Config ();
use VisLlama::Context qw(%CFG $STATE);

my $root = tempdir(CLEANUP=>1);
my $model = File::Spec->catfile($root, 'fixture.gguf');
my $proxy = File::Spec->catfile($root, 'llama_openai_proxy.pl');
my $exe = File::Spec->catfile($root, 'llama-server.exe');
for my $file ($model, $proxy, $exe) { open my $fh, '>', $file or die $!; close $fh; }
my @startup;
{
    no warnings 'redefine';
    local *VisLlama::Paths::app_base_dir = sub { $root };
    local *VisLlama::Paths::canonical_under = sub { $_[0] eq $model && $_[1] eq $root };
    local *VisLlama::ModelStats::metrics_supported = sub { 0 };
    local *VisLlama::ModelStats::sample_running_model_stats = sub {};
    local *VisLlama::Router::load_router_model_centrally = sub { push @startup, 'load:'.$_[0].':'.$_[1]{build} };
    local *VisLlama::Router::wait_router_model_loaded = sub { push @startup, 'ready:'.$_[1].':'.$_[0]{build} };
    local $CFG{builds} = {a=>$root,b=>$root};
    local $CFG{model_root} = $root;
    my $direct = VisLlama::Process::start_server({build=>'a',model=>$model,args=>['--ctx-size','4096','--log-verbosity 4']});
    ok($direct->{running}, 'Direct server launched through original process path');
    open my $launch_fh,'<',$created[0][1] =~ /-File "([^"]+)"/ ? $1 : die 'Missing launcher path' or die $!;
    my $direct_script=do {local $/;<$launch_fh>};close $launch_fh;
    like($direct_script,qr/'--log-verbosity' '4'/,'Direct launcher separates a combined extra option before execution');
    is(File::Spec->abs2rel($STATE->{log_file}, $root) =~ m{\Alogs[/\\]} ? 1 : 0, 1,
        'Direct-server logs remain beside the application, not under lib');
    like($created[0][1], qr/launch-.*\.ps1/, 'PowerShell launcher used');
    is($created[0][3], 0x220, 'Separate process group retained');
    is($created[0][4], $root, 'Child working directory remains selected build directory');
    my $direct_pid = $STATE->{pid};
    VisLlama::Process::stop_server();
    is_deeply($killed[0], ['taskkill','/PID',$direct_pid,'/T','/F'], 'Direct stop terminates complete managed tree');

    my $service = {host=>'192.168.6.39',port=>18080,models_max=>4,threads_http=>'',autoload=>1};
    VisLlama::Config::write_json_file_ascii(VisLlama::Config::router_service_config_path(), $service);
    my $presets = [
        {alias=>'first',build=>'b',model=>$model,enabled=>1,load_on_startup=>1,options=>[],ui=>{}},
        {alias=>'demand',build=>'a',model=>$model,enabled=>1,load_on_startup=>0,options=>[],ui=>{}},
        {alias=>'second',build=>'a',model=>$model,enabled=>1,load_on_startup=>1,options=>[],ui=>{}},
    ];
    VisLlama::Catalog::save_router_presets($presets);
    my $router = VisLlama::Process::start_router({host=>'0.0.0.0',port=>8080});
    is($router->{router_host}, '192.168.6.39', 'Router start retains saved host');
    is($router->{router_port}, 18080, 'Router start retains saved port');
    is_deeply(\@startup, ['load:first:b','ready:first:b','load:second:a','ready:second:a'],
        'Full Router launch retains sequential catalog order across builds');
    is_deeply(VisLlama::Config::load_router_service_config(), $service, 'Router start does not rewrite service settings');
    open my $fh, '<', $STATE->{proxy_launcher} or die $!;
    my $launcher = do { local $/; <$fh> };
    like($launcher, qr/\Q$proxy\E/, 'Proxy launch resolves the original root entry point');
    for my $entry (@created) { is($entry->[3],0x220,'Every child keeps managed process group flags'); }
    my @pids = ($STATE->{proxy_pid}, map { $_->{pid} } values %{$STATE->{router_engines}});
    VisLlama::Process::stop_server();
    for my $pid (@pids) { ok((grep { $_->[2] == $pid && $_->[3] eq '/T' } @killed), "Managed Router tree $pid stopped"); }
    is_deeply($STATE->{router_engines},{},'Router runtime ownership cleared after stop');
}
done_testing();
