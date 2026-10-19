# Fault injection for owned-process recovery. These are simulated Win32 handles,
# not evidence of taskkill or process-tree behavior on a Windows machine.
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Temp qw(tempdir);
our (%active,%fail,%query_fail,@kills,$create_count);
BEGIN {
    $INC{'Win32.pm'}=__FILE__;$INC{'Win32/Process.pm'}=__FILE__;
    *CORE::GLOBAL::system=sub {
        die 'Unexpected command' unless $_[0] eq 'taskkill';
        push @kills,$_[2];
        return 256 if $fail{$_[2]};
        $active{$_[2]}=0;return 0;
    };
}
{ package StopTestHandle;
  sub GetProcessID {$_[0]{pid}}
  sub GetExitCode { return 0 if $main::query_fail{$_[0]{pid}}; $_[1]=$main::active{$_[0]{pid}}?259:0;return 1 }
}
{ package Win32::Process;
  sub import {}
  sub NORMAL_PRIORITY_CLASS {0x20}
  sub CREATE_NEW_PROCESS_GROUP {0x200}
  sub Create {
      $main::create_count++;$main::active{701}=1;$main::query_fail{701}=1;
      $_[0]=bless({pid=>701},'StopTestHandle');return 1;
  }
}
use VisLlama::Platform ();
BEGIN { no warnings 'redefine'; *VisLlama::Platform::windows=sub {1}; }
use VisLlama::App ();
use JSON::PP qw(decode_json);
use VisLlama::Process ();
use VisLlama::ProcessState ();
use VisLlama::Context qw($STATE);
sub owned { my ($pid)=@_;$active{$pid}=1;return {proc=>bless({pid=>$pid},'StopTestHandle'),pid=>$pid,build=>"build-$pid"} }
my $root=tempdir(CLEANUP=>1);
{
    no warnings 'redefine';
    local *VisLlama::Paths::app_base_dir=sub {$root};
    local *VisLlama::ModelStats::sample_running_model_stats=sub {};
    $STATE={mode=>'single',%{owned(101)}};
    $fail{101}=1;
    eval {VisLlama::Process::stop_server()};
    like($@,qr/ownership retained/,'Failed stop is an error');
    is($STATE->{pid},101,'Direct PID retained');
    ok($STATE->{proc},'Direct handle retained');
    ok(VisLlama::ProcessState::state_payload()->{running},'Status keeps Stop available');
    eval {VisLlama::Process::start_server({})};
    like($@,qr/already running/,'Replacement start blocked');
    my $safe=VisLlama::Errors::public_error('Managed process termination could not be confirmed; private C:\\secret\\file');
    like($safe->{message},qr/Retry Stop/,'Safe error provides recovery action');
    unlike($safe->{message},qr/secret/,'No raw diagnostic in safe error');
    like($safe->{reference},qr/^VL-/,'Error keeps private diagnostic reference');
    # Exercise the actual dispatch/error boundary with only request input mocked.
    # The production Serving route still invokes the failing process cleanup.
    {
        local *VisLlama::HTTP::read_request=sub {('POST','/api/stop',{},'{}')};
        my $wire='';open my $sock,'>',\$wire or die $!;
        VisLlama::App::handle_client($sock);close $sock;
        like($wire,qr/^HTTP\/1\.1 500/,'Stop failure reaches API as HTTP 500');
        my ($body)=$wire =~ /\r\n\r\n(.*)/s;
        my $response=decode_json($body);
        ok(!$response->{ok},'Failed stop cannot claim API success');
        like($response->{error},qr/Retry Stop/,'API gives reviewed recovery guidance');
        like($response->{error_ref},qr/^VL-/,'API includes diagnostic correlation');
        unlike($body,qr/ownership retained|Process.pm|line \d+/,'API hides raw cleanup exception');
        is($STATE->{pid},101,'API failure retains the same owned process');
    }
    $fail{101}=0;
    ok(!VisLlama::Process::stop_server()->{running},'Retry confirms exit');
    ok(!$STATE->{pid} && !$STATE->{proc},'Confirmed stop clears ownership');
    is($STATE->{wrapper_exit_code},0,'Confirmed direct stop retains exit diagnostics');

    $STATE={mode=>'router',router_engines=>{a=>owned(201),b=>owned(202)},router_control_token=>'retain-token'};
    $fail{201}=1;
    eval {VisLlama::Process::stop_server()};
    like($@,qr/ownership retained/,'Mixed Router cleanup reports survivor');
    ok(exists $STATE->{router_engines}{a},'Failed engine retained');
    ok(!exists $STATE->{router_engines}{b},'Independent successful engine removed');
    is($STATE->{router_control_token},'retain-token','Routing state retained for survivor');
    $fail{201}=0;VisLlama::Process::stop_server();
    is_deeply($STATE->{router_engines},{},'Retry clears final engine');

    my $proxy=owned(301);$STATE={mode=>'router',proxy_proc=>$proxy->{proc},proxy_pid=>301};
    open my $fh,'>',$root.'/proxy.ps1' or die $!;close $fh;
    $STATE->{proxy_launcher}=$root.'/proxy.ps1';$fail{301}=1;
    eval {VisLlama::Process::restart_proxy_for_compute_cancel()};
    like($@,qr/Could not confirm proxy termination/,'Stop compute aborts before replacement');
    is($STATE->{proxy_pid},301,'Original proxy remains owned');
    ok(VisLlama::ProcessState::proc_running(),'Proxy alone counts as running');
    $fail{301}=0;VisLlama::Process::stop_server();

    my $old=owned(601);
    $STATE={mode=>'router',proxy_proc=>$old->{proc},proxy_pid=>601,proxy_launcher=>$root.'/proxy.ps1'};
    eval {VisLlama::Process::restart_proxy_for_compute_cancel()};
    like($@,qr/failed to restart/,'Unknown replacement health reports failure');
    is($create_count,1,'Replacement created only after original exit');
    is($STATE->{proxy_pid},701,'Unhealthy replacement remains owned');
    ok(VisLlama::ProcessState::proc_running(),'Unknown replacement remains stoppable');
    $query_fail{701}=0;VisLlama::Process::stop_server();
    ok(!$STATE->{proxy_pid},'Replacement cleanup can be retried');

    $STATE={};$fail{401}=1;
    {
        local *VisLlama::Process::start_router_impl=sub {
            $STATE->{starting_engines}={partial=>owned(401)};
            $STATE->{starting_proxy}=owned(402);
            die "Original startup failure\n";
        };
        eval {VisLlama::Process::start_router({})};
        like($@,qr/Original startup failure.*Cleanup also failed/s,'Original and cleanup failures preserved');
    }
    is($STATE->{starting_engines}{partial}{pid},401,'Partial startup survivor retained');
    ok(!exists $STATE->{starting_proxy},'Partial proxy successfully cleaned');
    ok(VisLlama::ProcessState::state_payload()->{running},'Partial survivor visible as running');
    is(scalar @{VisLlama::ProcessState::router_engines_payload()},1,'Partial engine visible in payload');
    $fail{401}=0;VisLlama::Process::stop_server();
    ok(!exists $STATE->{starting_engines},'Retry removes partial registry');

    my $unknown=owned(501);$query_fail{501}=1;my $before=@kills;
    ok(!VisLlama::ProcessState::stop_owned_process($unknown->{proc},501,'unknown'),'Unknown health retains ownership');
    is(scalar @kills,$before,'Failed health query never authorizes PID kill');
    ok(!VisLlama::ProcessState::stop_owned_process(undef,502,'orphan'),'PID alone cannot authorize kill');
    is(scalar @kills,$before,'PID-only record not killed');
    $query_fail{501}=0;$active{501}=0;
    ok(VisLlama::ProcessState::stop_owned_process($unknown->{proc},501,'exited'),'Confirmed exit needs no kill');
    is(scalar @kills,$before,'Exited handle does not target potentially reused PID');
}
done_testing();
