package VisLlama::ProcessState;

# Shared health checks without importing launch orchestration. Reading state
# can reap exited handles and record exit details; it is not a pure getter layer.
use strict;
use warnings;
use Time::HiRes qw(time);
use VisLlama::Context qw($APP_VERSION $STATE);
use VisLlama::Util qw(jtrue jfalse);
use VisLlama::Logs ();
use VisLlama::Errors ();
use VisLlama::Lifecycle ();
use VisLlama::Command ();
use VisLlama::Readiness ();
use VisLlama::Platform ();
use VisLlama::Docker ();

# Keep the owned handle/PID when a native health query fails, so later polling
# can recover and Stop still targets the managed process. Only a successful
# query may establish an exit; STILL_ACTIVE is also the conservative fallback.
sub owned_exit_code {
    my ($proc)=@_;my $exit=259;
    my $ok=eval {$proc->GetExitCode($exit)};
    if (!$ok) {
        my $detail=$@ || "GetExitCode failed: $!";
        VisLlama::Errors::report($detail,'process_error');
        return 259;
    }
    return $exit;
}

# Shared process health/state without depending on launch orchestration.
sub proxy_running {
    return 0 unless $STATE->{proxy_proc};
    my $exit = owned_exit_code($STATE->{proxy_proc});
    # Win32 STILL_ACTIVE means the owned process has not exited.
    return 1 if $exit == 259;
    $STATE->{proxy_proc} = undef;
    $STATE->{proxy_pid} = undef;
    return 0;
}

# -----------------------------------------------------------------------------
# Stop an owned launcher tree; a PID alone is not authority to kill a process.
# Keep the handle until exit is confirmed so a failed kill/query can be retried.
# -----------------------------------------------------------------------------
sub stop_owned_process {
    my ($proc,$pid,$label)=@_;
    return 1 unless $proc || $pid;
    if (!$proc) {
        VisLlama::Errors::report("Cannot verify owned handle for $label (PID $pid)",'process_error');
        return 0;
    }
    return 1 if owned_exit_code($proc) != 259;
    if (!$pid) {
        VisLlama::Errors::report("Missing owned PID for $label",'process_error');
        return 0;
    }
    # A failed health query is treated as possibly alive, but must not authorize
    # taskkill against a PID that could now refer to a different process.
    my $exit=259;
    my $verified=eval { $proc->GetExitCode($exit) };
    if (!$verified) {
        VisLlama::Errors::report($@ || "Cannot verify $label before taskkill: $!",'process_error');
        return 0;
    }
    return 1 if $exit != 259;
    if ($proc->isa('VisLlama::Platform::Linux') || $proc->isa('VisLlama::Docker::Process')) {
        return 1 if $proc->stop();
        VisLlama::Errors::report("Stop unconfirmed for $label (PID $pid)",'process_error');
        return 0;
    }
    my $result=eval {
        if ($^O eq 'MSWin32') {local $VisLlama::Command::TIMEOUT=10;VisLlama::Command::capture(0,'taskkill','/PID',$pid,'/T','/F');$?;}
        else {system('taskkill','/PID',$pid,'/T','/F');}
    };
    my $error=$@;
    my $deadline=time()+1;
    while (1) {
        return 1 if owned_exit_code($proc) != 259;
        last if time() >= $deadline;
        select(undef,undef,undef,0.05);
    }
    VisLlama::Errors::report("Stop unconfirmed for $label (PID $pid); taskkill result "
        .(defined($result)?$result:'unknown')."; $error",'process_error');
    return 0;
}

# Clear proxy ownership only after its owned handle confirms exit.
sub stop_proxy {
    return 0 unless stop_owned_process($STATE->{proxy_proc},$STATE->{proxy_pid},'public proxy');
    $STATE->{proxy_proc} = undef;
    $STATE->{proxy_pid} = undef;
    return 1;
}

# -----------------------------------------------------------------------------
# Read the native llama-server exit code sidecar for single-server mode.
# -----------------------------------------------------------------------------
sub read_native_exit_code {
    my $file = $STATE->{exit_code_file};
    return undef unless $file && -f $file;
    open my $fh, '<:raw', $file or return undef;
    local $/;
    my $v = <$fh> // '';
    close $fh;
    $v =~ s/^\x{FEFF}//;
    $v =~ s/[\r\n\s]+//g;
    return undef unless $v =~ /^-?\d+$/;
    return 0 + $v;
}

# -----------------------------------------------------------------------------
# Read an exit-code sidecar associated with a specific internal engine.
# -----------------------------------------------------------------------------
sub read_native_exit_code_for_file {
    my ($file) = @_;
    return undef unless $file && -f $file;
    open my $fh, '<:raw', $file or return undef;
    local $/;
    my $v = <$fh> // '';
    close $fh;
    $v =~ s/^\x{FEFF}//;
    $v =~ s/[\r\n\s]+//g;
    return undef unless $v =~ /^-?\d+$/;
    return 0 + $v;
}

# -----------------------------------------------------------------------------
# Check whether one internal per-build Router engine is alive.
# -----------------------------------------------------------------------------
sub router_engine_running {
    my ($eng) = @_;
    return 0 unless $eng && $eng->{proc};
    my $wrapper_exit = owned_exit_code($eng->{proc});
    return 1 if $wrapper_exit == 259;

    my $native_exit = read_native_exit_code_for_file($eng->{exit_code_file});
    my $exit = defined($native_exit) ? $native_exit : $wrapper_exit;
    my ($hex, $name) = VisLlama::Logs::decode_native_exit($exit,$eng->{proc});
    $eng->{last_exit_code} = 0 + $exit;
    $eng->{last_exit_hex} = $hex;
    $eng->{last_exit_name} = $name;
    $eng->{wrapper_exit_code} = 0 + $wrapper_exit;
    $eng->{last_exit_time} = scalar localtime;
    $eng->{last_error} = VisLlama::Logs::extract_error_from_log($eng->{log_file});
    $eng->{crashed} = (!$STATE->{stop_requested} && $exit != 0) ? 1 : 0;
    $eng->{proc} = undef;
    $eng->{pid} = undef;
    return 0;
}

# -----------------------------------------------------------------------------
# Check whether any internal Router engine remains alive.
# -----------------------------------------------------------------------------
sub router_any_running {
    my $any = 0;
    for my $build (keys %{$STATE->{router_engines} || {}}) {
        my $eng = $STATE->{router_engines}{$build};
        $any = 1 if router_engine_running($eng);
    }
    return $any;
}

# -----------------------------------------------------------------------------
# Refresh process state for direct/single-server and Router modes.
# -----------------------------------------------------------------------------
sub proc_running {
    return 1 if VisLlama::Docker::pending_running();
    # Failed startup can leave owned launchers before normal state is committed.
    # Count these as running so status keeps Stop available and Start blocked.
    for my $eng (values %{$STATE->{starting_engines}||{}}) {
        return 1 if router_engine_running($eng);
    }
    my $pending=$STATE->{starting_proxy};
    return 1 if $pending && $pending->{proc} && owned_exit_code($pending->{proc}) == 259;
    if (($STATE->{mode} // '') eq 'router') {
        my $any = router_any_running();
        # Status must not silently issue stop commands. A surviving proxy is
        # still owned work even after all engines have exited.
        return proxy_running() unless $any;
        return 1;
    }
    return proxy_running() unless $STATE->{proc};
    my $wrapper_exit = owned_exit_code($STATE->{proc});
    return 1 if $wrapper_exit == 259;

    my $native_exit = read_native_exit_code();
    my $exit = defined($native_exit) ? $native_exit : $wrapper_exit;
    my ($hex, $name) = VisLlama::Logs::decode_native_exit($exit,$STATE->{proc});
    $STATE->{last_exit_code} = 0 + $exit;
    $STATE->{last_exit_hex} = $hex;
    $STATE->{last_exit_name} = $name;
    $STATE->{wrapper_exit_code} = 0 + $wrapper_exit;
    $STATE->{last_exit_time} = scalar localtime;
    $STATE->{last_error} = VisLlama::Logs::extract_error_from_log($STATE->{log_file});
    $STATE->{crashed} = (!$STATE->{stop_requested} && $exit != 0) ? 1 : 0;
    $STATE->{proc} = undef;
    $STATE->{pid} = undef;
    $STATE->{stop_requested} = 0;
    return proxy_running();
}

# -----------------------------------------------------------------------------
# Serialize internal engine/build/port/model assignments for UI status.
# -----------------------------------------------------------------------------
sub router_engines_payload {
    my @out;
    my %engines=(%{$STATE->{router_engines}||{}},%{$STATE->{starting_engines}||{}});
    for my $build (sort keys %engines) {
        my $eng = $engines{$build};
        my $running = router_engine_running($eng);
        push @out, {
            build => $eng->{build},
            ($eng->{engine}?(engine=>$eng->{engine},managed=>jtrue):()),
            gpu_devices => $eng->{isolation} ? $eng->{isolation}{devices} : [],
            running => $running ? jtrue : jfalse,
            pid => $eng->{pid},
            internal_port => $eng->{port},
            preset_file => $eng->{preset_file},
            log_file => $eng->{log_file},
            models => $eng->{models} || [],
            last_exit_code => $eng->{last_exit_code},
            last_exit_hex => $eng->{last_exit_hex},
            last_exit_name => $eng->{last_exit_name},
            last_exit_time => $eng->{last_exit_time},
            last_error => VisLlama::Errors::public_text($eng->{last_error},'process_error'),
            crashed => $eng->{crashed} ? jtrue : jfalse,
        };
    }
    return \@out;
}

# -----------------------------------------------------------------------------
# Build the main status response consumed by Dashboard/Router/Logs views.
# -----------------------------------------------------------------------------
sub state_payload {
    my $running = proc_running();
    return {
        ok => jtrue,
        app_version => $APP_VERSION,
        runtime_token => VisLlama::Lifecycle::token(),
        active_operation => $STATE->{active_operation},
        readiness => VisLlama::Readiness::snapshot($running),
        running => $running ? jtrue : jfalse,
        pid => $STATE->{pid},
        started => $STATE->{started},
        command => (defined($STATE->{command}) ? 'Launch command retained in server-side logs.' : undef),
        log_file => $STATE->{log_file},
        build => $STATE->{build},
        model => $STATE->{model},
        last_exit_code => $STATE->{last_exit_code},
        last_exit_hex => $STATE->{last_exit_hex},
        last_exit_name => $STATE->{last_exit_name},
        wrapper_exit_code => $STATE->{wrapper_exit_code},
        last_exit_time => $STATE->{last_exit_time},
        last_error => VisLlama::Errors::public_text($STATE->{last_error},'process_error'),
        crashed => $STATE->{crashed} ? jtrue : jfalse,
        mode => $STATE->{mode} || 'single',
        router_host => $STATE->{router_host},
        router_port => $STATE->{router_port},
        router_internal_port => $STATE->{router_internal_port},
        router_engines => router_engines_payload(),
        proxy_running => proxy_running() ? jtrue : jfalse,
        proxy_pid => $STATE->{proxy_pid},
        proxy_log => $STATE->{proxy_log},
    };
}

1;
