package VisLlama::Process;

# Shared launch orchestration with platform-specific owned-process creation.
# Preserve process-group flags and native exit sidecars when altering launch code.
use strict;
use VisLlama::Engines ();
use warnings;
use VisLlama::ProcessState ();
use VisLlama::Platform ();

use IO::Socket::INET;

use File::Spec;
use File::Basename qw(basename);

use POSIX qw(strftime);
use Time::HiRes qw(time);
use Digest::SHA qw(sha1_hex);
use VisLlama::Context qw(%CFG $STATE);
use VisLlama::Util qw(jtrue jfalse);
use VisLlama::Builds ();
use VisLlama::Arguments ();
use VisLlama::GPUIsolation ();
use VisLlama::Catalog ();
use VisLlama::Config ();
use VisLlama::GPUPlanner ();
use VisLlama::Logs ();
use VisLlama::ModelStats ();
use VisLlama::Paths ();
use VisLlama::Router ();
use VisLlama::Lifecycle ();
use VisLlama::Preflight ();
use VisLlama::Errors ();

# Windows broadcasts console Ctrl+C to every process sharing the console.
# Put each launcher in its own console process group so only VisLlama handles
# Ctrl+C; its cleanup can then taskkill /T the still-running launcher and child.
# The group inherits the console (for normal logging) but does not receive
# Ctrl+C sent to the parent process group.
sub managed_process_flags {
    return VisLlama::Platform::flags();
}

# -----------------------------------------------------------------------------
# Allocate an unused loopback TCP port for an internal engine/proxy.
# -----------------------------------------------------------------------------
sub find_free_loopback_port {
    my ($excluded)=@_;my @held;
    for (1..100) {
    my $sock = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto => 'tcp',
        Listen => 1,
        ReuseAddr => 1,
    ) or die "Unable to allocate an internal router port: $!";
    my $port = $sock->sockport();
    if ($excluded && $excluded->{$port}) {push @held,$sock;next;}
    close $sock;
    return $port;
    }
    die "Unable to allocate a distinct internal port";
}

# -----------------------------------------------------------------------------
# Cancel active public inference connections without unloading resident models.
# -----------------------------------------------------------------------------
sub restart_proxy_for_compute_cancel {
    die "Stop compute is available only while Router mode and its compatibility proxy are running"
        unless VisLlama::ProcessState::proc_running() && ($STATE->{mode} // '') eq 'router' && VisLlama::ProcessState::proxy_running();
    VisLlama::Lifecycle::rotate();
    my $launcher = $STATE->{proxy_launcher} // '';
    die "Proxy launcher is unavailable" unless $launcher && -f $launcher;

    die "Could not confirm proxy termination; retry Stop before restarting compute"
        unless VisLlama::ProcessState::stop_proxy();
    select(undef, undef, undef, 0.18);

    my $proxy_proc=VisLlama::Platform::launch($launcher,VisLlama::Paths::app_base_dir());
    # Own the replacement before querying health; a query failure is not exit.
    $STATE->{proxy_proc} = $proxy_proc;
    $STATE->{proxy_pid} = $proxy_proc->GetProcessID();
    select(undef, undef, undef, 0.25);
    my $exit = 0;
    unless ($proxy_proc->GetExitCode($exit) && $exit == 259) {
        VisLlama::ProcessState::stop_proxy();
        die "OpenAI compatibility proxy failed to restart";
    }
    return VisLlama::ProcessState::state_payload();
}

# -----------------------------------------------------------------------------
# Launch one direct llama-server instance for Single mode.
# -----------------------------------------------------------------------------
sub start_server {
    my ($req) = @_;
    return start_router($req) if (($req->{mode} // 'single') eq 'router');
    die "A llama-server process is already running" if VisLlama::ProcessState::proc_running();
    die 'Configure at least one llama.cpp build alias before starting' unless keys %{$CFG{builds}||{}} || @{VisLlama::Engines::builds()};

    VisLlama::Lifecycle::rotate();
    $STATE->{startup_models}=[];
    my $build_name = $req->{build} // '';
    die "Unknown build" unless exists $CFG{builds}{$build_name};
    my $build_dir = $CFG{builds}{$build_name};
    my $exe = VisLlama::Builds::find_server_exe($build_dir) or die "llama-server executable not found below $build_dir";

    my $model = $req->{model} // '';
    die "Model path is required" unless $model;
    die "Model must be under $CFG{model_root}" unless VisLlama::Paths::canonical_under($model, $CFG{model_root});
    die "Model file does not exist" unless -f $model;
    die "Model must be a .gguf file" unless $model =~ /\.gguf$/i;
    $req = { %$req, args=>VisLlama::Arguments::normalize($req->{args}) } if ref($req->{args}) eq 'ARRAY';
    if (ref($req->{args}) eq 'ARRAY') { for (my $i=0; $i < @{$req->{args}}; $i++) { if (($req->{args}[$i] // '') eq '--chat-template-file') { my $tpl=$req->{args}[$i+1] // ''; die "Chat template file does not exist on this server: $tpl" unless length($tpl) && -f $tpl; } } }

    my @args = ('-m', $model);
    if (ref($req->{args}) eq 'ARRAY') {
        for my $a (@{$req->{args}}) {
            next unless defined $a;
            $a =~ s/[\r\n]//g;
            push @args, "$a";
        }
    }
    if (($req->{gpu_priority} // '') =~ /^(?:priority|priority_split)$/) {
        my $plan = VisLlama::GPUPlanner::gpu_plan_for_mode($build_name,$model,$req->{gpu_devices},$req->{gpu_reserve},$req->{gpu_priority},$req->{gpu_settings},\@args);
        @args = @{VisLlama::GPUPlanner::priority_args(\@args,$plan)};
    }
    my $metrics_enabled = VisLlama::ModelStats::metrics_supported($exe);
    push @args, '--metrics' if $metrics_enabled && !grep { $_ eq '--metrics' } @args;
    my $direct_port = 8080;my $direct_host='127.0.0.1';
    for (my $i = 0; $i < @args - 1; $i++) {
        $direct_host=$args[$i+1] if $args[$i] eq '--host';
        $direct_port = int($args[$i+1]) if $args[$i] eq '--port' && $args[$i+1] =~ /^\d+$/;
    }

    # Resolve all launcher-related paths absolutely before changing the child
    # working directory to the selected llama.cpp build.  Win32::Process::Create
    # applies $build_dir as the PowerShell working directory, so relative paths
    # such as logs\launch-*.ps1 would otherwise be resolved under the CUDA build.
    my $base_dir = VisLlama::Paths::app_base_dir();
    my $logs = File::Spec->catdir($base_dir, 'logs');
    mkdir $logs unless -d $logs;
    $logs = File::Spec->rel2abs($logs);
    my $stamp = strftime('%Y%m%d-%H%M%S', localtime);
    my $log = File::Spec->rel2abs(File::Spec->catfile($logs, "llama-server-$stamp.log"));
    my $exit_code_file = File::Spec->rel2abs(File::Spec->catfile($logs, "llama-server-$stamp.exitcode"));

    my @logical_args=@args;
    my $isolation=VisLlama::GPUIsolation::profile({build=>$build_name,ui=>{},
        options=>VisLlama::GPUIsolation::options_from_args(\@args)},{});
    @args=@{VisLlama::GPUIsolation::remap_args(\@args,$isolation)};
    my $shown = join(' ', VisLlama::Util::shell_quote_win($exe), map { VisLlama::Util::shell_quote_win($_) } @args);

    # Use a tiny PowerShell launcher so arguments (including JSON-valued options)
    # are passed as discrete argv elements rather than being reparsed by cmd.exe.
    # The PowerShell process remains the parent while llama-server runs, allowing
    # taskkill /T to terminate the complete process tree reliably.
    my $launcher = File::Spec->rel2abs(File::Spec->catfile($logs, "launch-$stamp".VisLlama::Platform::launcher_suffix()));
    if (VisLlama::Platform::windows()) {
    open my $lfh, '>:encoding(UTF-8)', $launcher or die "Cannot write $launcher: $!";
    print $lfh "\$ErrorActionPreference = 'Continue'\n";
    print $lfh "\$PSNativeCommandUseErrorActionPreference = \$false\n";
    print $lfh VisLlama::GPUIsolation::environment_line($isolation,$log);
    print $lfh '& ' . VisLlama::Util::ps_quote($exe) . ' ' . join(' ', map { VisLlama::Util::ps_quote($_) } @args) . ' >> ' . VisLlama::Util::ps_quote($log) . " 2>&1\n";
    print $lfh "\$llamaExit = \$LASTEXITCODE\n";
    print $lfh "Set-Content -LiteralPath " . VisLlama::Util::ps_quote($exit_code_file) . " -Value \$llamaExit -Encoding ASCII\n";
    # Do not propagate the native status through PowerShell; that can truncate or
    # reinterpret NTSTATUS values. Perl reads the sidecar above instead.
    print $lfh "exit 0\n";
    close $lfh;
    } else {
        VisLlama::Platform::write_spec($launcher,$exe,\@args,$build_dir,$log,$exit_code_file,$isolation);
    }

    my $proc=VisLlama::Platform::launch($launcher,$build_dir);

    $STATE->{proc} = $proc;
    $STATE->{pid} = $proc->GetProcessID();
    $STATE->{started} = scalar localtime;
    $STATE->{command} = $shown;
    $STATE->{log_file} = $log;
    $STATE->{log_clear_offset} = 0;
    $STATE->{exit_code_file} = $exit_code_file;
    $STATE->{build} = $build_name;
    $STATE->{model} = $model;
    $STATE->{direct_alias} = $req->{alias} || basename($model);
    $STATE->{direct_port} = $direct_port;
    $STATE->{direct_host} = $direct_host;
    $STATE->{direct_metrics} = $metrics_enabled;
    $STATE->{direct_config_id} = VisLlama::ModelStats::model_config_id({build=>$build_name,model=>$model,options=>\@logical_args});
    $STATE->{last_exit_code} = undef;
    $STATE->{last_exit_hex} = undef;
    $STATE->{last_exit_name} = undef;
    $STATE->{wrapper_exit_code} = undef;
    $STATE->{last_exit_time} = undef;
    $STATE->{last_error} = undef;
    $STATE->{crashed} = 0;
    $STATE->{stop_requested} = 0;
    $STATE->{mode} = 'single';
    $STATE->{router_host} = undef;
    $STATE->{router_port} = undef;
    $STATE->{router_internal_port} = undef;
    VisLlama::ProcessState::stop_proxy();
    $STATE->{proxy_log} = undef;
    $STATE->{proxy_launcher} = undef;

    # Catch launch-time failures immediately while still allowing long model loads.
    select(undef, undef, undef, 0.35);
    return VisLlama::ProcessState::state_payload();
}

# -----------------------------------------------------------------------------
# Group enabled presets by build and ordered GPU visibility, then start the public proxy.
# -----------------------------------------------------------------------------
# Ensure every partially launched tree is owned even if a later file/probe fails.
sub start_router {
    my ($req)=@_;
    die "A llama-server process is already running" if VisLlama::ProcessState::proc_running();
    VisLlama::Lifecycle::rotate();
    my $result=eval { start_router_impl($req) };
    if (my $error=$@) {
        # Cleanup all partial trees, retaining any whose exit cannot be proved.
        # Preserve the original startup error across cleanup's nested evals.
        my $cleaned=eval { stop_server(); 1 };
        my $cleanup_error=$@;
        if (!$cleaned) {
            $STATE->{mode}='router';
            $STATE->{last_error}=$error . "\n" . $cleanup_error;
        }
        die $error . ($cleaned ? '' : "\nCleanup also failed: $cleanup_error");
    }
    delete $STATE->{starting_engines};
    return $result;
}
sub start_router_impl {
    my ($req) = @_;
    my $expected_runtime=VisLlama::Lifecycle::token();
    $STATE->{mode}='router';
    die "A llama-server process is already running" if VisLlama::ProcessState::proc_running();

    my $presets = VisLlama::Catalog::load_router_presets();
    my @enabled = grep { $_->{enabled} } @$presets;
    die "No enabled models are configured. Open Manage Models to add or enable a model." unless @enabled;

    my (%groups,%profiles,%maps);
    for my $p (@enabled) {
        my $build = $p->{build} // '';
        die "Router Preset '$p->{alias}' has no engine build assigned" unless length $build;
        if (VisLlama::Engines::external($p)) {push @{$groups{VisLlama::Engines::group_key($p)}},$p;next;}
        die "Router Preset '$p->{alias}' references unknown build '$build'" unless exists $CFG{builds}{$build};
        my $key=VisLlama::Engines::group_key($p);
        die 'Router engine identity collision' if $groups{$key} && $groups{$key}[0]{build} ne $build;
        push @{$groups{$key}}, $p;
        $profiles{$key} ||= VisLlama::GPUIsolation::profile($p,\%maps);
    }

    my $saved_router = VisLlama::Config::load_router_service_config();
    # Starting a Router must never persist stale browser fields over the
    # dedicated Settings save. The saved service config is authoritative.
    my $host = $saved_router->{host};
    my $port = int($saved_router->{port});
    my $models_max = int($saved_router->{models_max});
    die "models-max must be >= 0" if $models_max < 0;
    my $autoload = $saved_router->{autoload} ? 1 : 0;
    $STATE->{router_autoload}=$autoload;
    my $raw_threads_http = $saved_router->{threads_http};
    my $threads_http = (defined $raw_threads_http && "$raw_threads_http" ne '') ? "$raw_threads_http" : undef;

    my $base_dir = VisLlama::Paths::app_base_dir();
    my $logs = File::Spec->catdir($base_dir, 'logs'); mkdir $logs unless -d $logs;
    $logs = File::Spec->rel2abs($logs);
    my $preset_dir = VisLlama::Paths::presets_dir();
    my (undef, undef, $empty_cache_root) = VisLlama::Catalog::router_paths();
    my $stamp = strftime('%Y%m%d-%H%M%S', localtime);

    # Keep build-specific INI files synchronized before launching engines.
    # This also removes obsolete files from earlier build assignments.
    $STATE->{priority_plans} = {};
    delete $STATE->{catalog_apply_incomplete};
    VisLlama::Catalog::sync_router_build_inis($presets);

    my %engines;
    $STATE->{starting_engines}=\%engines;
    my %route_map;
    my @shown;

    for my $key (sort keys %groups) {
        VisLlama::Lifecycle::checkpoint($expected_runtime);
        my $build=$groups{$key}[0]{build};
        if (VisLlama::Engines::external($groups{$key}[0])) {
            my $p=$groups{$key}[0];my $port=find_free_loopback_port({map {$_->{port}=>1} values %engines});
            # Each startup-load driver owns one model process, under the same Router.
            $engines{$key}={engine=>$p->{engine},build=>$build,group_key=>$key,port=>$port,models=>[$p->{alias}]};
            $route_map{$p->{alias}}={host=>'127.0.0.1',port=>$port,build=>$build,managed=>1,engine=>$p->{engine}};
            push @shown,"$build -> 127.0.0.1:$port -> $p->{alias}";next;
        }
        my $isolation=$profiles{$key};
        my $build_dir = $CFG{builds}{$build};
        my $exe = VisLlama::Builds::find_server_exe($build_dir) or die "llama-server executable not found below $build_dir for build '$build'";
        my $internal_port = find_free_loopback_port({map {$_->{port}=>1} values %engines});
        my $slug = VisLlama::Catalog::safe_build_slug($key)."-".substr(sha1_hex($key),0,10);
        my $ini_file = File::Spec->rel2abs(File::Spec->catfile($preset_dir, "router-group-$slug.ini"));
        my $descriptor={build=>$build,group_key=>$key,isolation=>$isolation};
        VisLlama::Catalog::write_router_ini_for_build($presets, $build, $ini_file,undef,$descriptor);
        my $cache_dir = File::Spec->catdir($empty_cache_root, $slug);
        mkdir $cache_dir unless -d $cache_dir;

        my $startup_count = scalar grep { $_->{enabled} && $_->{load_on_startup} && VisLlama::Engines::group_key($_) eq $key } @$presets;
        die "$startup_count presets for '$build' are marked Load on startup but models-max is $models_max" if $models_max > 0 && $startup_count > $models_max;

        my @args = ('--models-preset', $ini_file, '--models-max', $models_max,
                    ($autoload ? '--models-autoload' : '--no-models-autoload'),
                    '--host', '127.0.0.1', '--port', $internal_port);
        my $metrics_enabled = VisLlama::ModelStats::metrics_supported($exe);
        push @args, '--metrics' if $metrics_enabled;
        push @args, '--threads-http', $threads_http if defined $threads_http;

        my $log = File::Spec->rel2abs(File::Spec->catfile($logs, "llama-router-$slug-$stamp.log"));
        my $exit_code_file = File::Spec->rel2abs(File::Spec->catfile($logs, "llama-router-$slug-$stamp.exitcode"));
        my $launcher = File::Spec->rel2abs(File::Spec->catfile($logs, "launch-router-$slug-$stamp".VisLlama::Platform::launcher_suffix()));
        if (VisLlama::Platform::windows()) {
        open my $lfh, '>:encoding(UTF-8)', $launcher or die "Cannot write $launcher: $!";
        print $lfh "\$ErrorActionPreference = 'Continue'\n";
        print $lfh "\$PSNativeCommandUseErrorActionPreference = \$false\n";
        print $lfh VisLlama::GPUIsolation::environment_line($isolation,$log);
        print $lfh "\$env:LLAMA_CACHE = " . VisLlama::Util::ps_quote($cache_dir) . "\n";
        print $lfh '& ' . VisLlama::Util::ps_quote($exe) . ' ' . join(' ', map { VisLlama::Util::ps_quote($_) } @args) . ' >> ' . VisLlama::Util::ps_quote($log) . " 2>&1\n";
        print $lfh "\$llamaExit = \$LASTEXITCODE\n";
        print $lfh "Set-Content -LiteralPath " . VisLlama::Util::ps_quote($exit_code_file) . " -Value \$llamaExit -Encoding ASCII\n";
        print $lfh "exit 0\n";
        close $lfh;
        } else {
            VisLlama::Platform::write_spec($launcher,$exe,\@args,$build_dir,$log,$exit_code_file,$isolation,{LLAMA_CACHE=>$cache_dir});
        }

        my $proc=VisLlama::Platform::launch($launcher,$build_dir);

        my @models = map { $_->{alias} } @{$groups{$key}};
        $engines{$key} = {
            group_key=>$key,isolation=>$isolation,
            build=>$build, build_dir=>$build_dir, exe=>$exe, proc=>$proc, pid=>$proc->GetProcessID(), port=>$internal_port,
            log_file=>$log, exit_code_file=>$exit_code_file, launcher=>$launcher, preset_file=>$ini_file,
            models=>\@models, crashed=>0, metrics_enabled=>$metrics_enabled,
        };
        for my $alias (@models) {
            my ($preset) = grep { ($_->{alias}//'') eq $alias } @{$groups{$key}};
            $route_map{$alias} = { host=>'127.0.0.1', port=>$internal_port, build=>$build,
                calculated=>(($preset->{ui}{gpuPriority}//'') eq 'priority_split' ? 1 : 0) };
        }
        push @shown, "$build -> 127.0.0.1:$internal_port -> " . join(', ', @models);
    }

    my $route_map_file = File::Spec->rel2abs(File::Spec->catfile($logs, "openai-route-map-$stamp.json"));
    my $control_token = sha1_hex(join(':',time(),rand(),$$));
    VisLlama::Config::write_json_file_ascii($route_map_file, { models=>\%route_map, backends=>[ map { {build=>$engines{$_}{build},host=>'127.0.0.1',port=>$engines{$_}{port}} } sort keys %engines ],
        control=>{host=>'127.0.0.1',port=>$CFG{listen_port},token=>$control_token} });

    # Complete ordered startup loads before opening the public API. Requests
    # arriving at startup therefore cannot cause out-of-order autoloading.
    # A failed model is recorded and the remaining catalog is still attempted.
    # The public proxy can therefore start with only part of the startup set;
    # completion of this stage does not mean every requested model loaded.
    my @startup_errors;
    $STATE->{startup_models}=[];
    for my $p (@enabled) {
        next unless $p->{load_on_startup};
        my $eng = $engines{VisLlama::Engines::group_key($p)};
        my $ok = eval {
            VisLlama::Router::load_router_model_centrally($p->{alias},$eng);
            VisLlama::Router::wait_router_model_loaded($eng,$p->{alias},300);
            1;
        };
        my $failure=$@;
        push @{$STATE->{startup_models}},{alias=>$p->{alias},state=>$ok?'loaded':'failed',error=>$ok?undef:VisLlama::Errors::public_text($failure,'model_load_error')};
        if (!$ok) {
            VisLlama::Lifecycle::checkpoint($expected_runtime);
            my $error = "Startup model $p->{alias}: $failure";
            push @startup_errors, $error;
            warn $error;
        }
    }

    VisLlama::Lifecycle::checkpoint($expected_runtime);
    my $proxy_launcher = File::Spec->rel2abs(File::Spec->catfile($logs, "launch-openai-proxy-$stamp".VisLlama::Platform::launcher_suffix()));
    my $proxy_log = File::Spec->rel2abs(File::Spec->catfile($logs, "openai-proxy-$stamp.log"));
    my $proxy_script = File::Spec->rel2abs(File::Spec->catfile($base_dir, 'llama_openai_proxy.pl'));
    die "OpenAI proxy script not found: $proxy_script" unless -f $proxy_script;

    if (VisLlama::Platform::windows()) {
    open my $pfh, '>:encoding(UTF-8)', $proxy_launcher or die "Cannot write $proxy_launcher: $!";
    print $pfh "\$ErrorActionPreference = 'Continue'\n";
    print $pfh "& " . VisLlama::Util::ps_quote($^X) . " " . VisLlama::Util::ps_quote($proxy_script)
        . " --listen-host " . VisLlama::Util::ps_quote($host)
        . " --listen-port " . VisLlama::Util::ps_quote($port)
        . " --route-map " . VisLlama::Util::ps_quote($route_map_file)
        . " >> " . VisLlama::Util::ps_quote($proxy_log) . " 2>&1\n";
    print $pfh "exit \$LASTEXITCODE\n";
    close $pfh;
    } else {
        VisLlama::Platform::write_spec($proxy_launcher,$^X,[$proxy_script,'--listen-host',$host,'--listen-port',$port,'--route-map',$route_map_file],$base_dir,$proxy_log,undef,undef);
    }

    my $proxy_proc=VisLlama::Platform::launch($proxy_launcher,$base_dir);

    $STATE->{starting_proxy}={proc=>$proxy_proc,pid=>$proxy_proc->GetProcessID()};
    select(undef,undef,undef,0.45);
    my $proxy_exit = 0;
    if (!$proxy_proc->GetExitCode($proxy_exit) || $proxy_exit != 259) {
        die "OpenAI compatibility proxy failed to bind $host:$port. See $proxy_log";
    }

    delete $STATE->{starting_proxy};
    $STATE->{router_engines}=\%engines;
    $STATE->{router_route_map}=$route_map_file;
    $STATE->{router_control_token}=$control_token;
    $STATE->{proxy_proc}=$proxy_proc; $STATE->{proxy_pid}=$proxy_proc->GetProcessID();
    $STATE->{proxy_log}=$proxy_log; $STATE->{proxy_launcher}=$proxy_launcher;
    $STATE->{proc}=undef; $STATE->{pid}=undef; $STATE->{started}=scalar localtime;
    $STATE->{command}="Public OpenAI endpoint: http://$host:$port\nInternal routers by build and GPU selection:\n  " . join("\n  ", @shown);
    $STATE->{log_file}=undef; $STATE->{log_clear_offset}=0; $STATE->{exit_code_file}=undef;
    $STATE->{build}='(per-model builds)'; $STATE->{model}='(router / managed presets)';
    $STATE->{last_exit_code}=undef; $STATE->{last_exit_hex}=undef; $STATE->{last_exit_name}=undef;
    $STATE->{wrapper_exit_code}=undef; $STATE->{last_exit_time}=undef;
    $STATE->{last_error}=@startup_errors ? join("\n",@startup_errors) : undef;
    $STATE->{crashed}=0; $STATE->{stop_requested}=0; $STATE->{mode}='router';
    $STATE->{router_host}=$host; $STATE->{router_port}=$port; $STATE->{router_internal_port}=undef;

    return VisLlama::ProcessState::state_payload();
}

# -----------------------------------------------------------------------------
# Stop all managed direct/router/proxy processes.
# -----------------------------------------------------------------------------
sub stop_server {
    VisLlama::Lifecycle::rotate();
    local $STATE->{stop_requested}=1;
    eval { VisLlama::ModelStats::sample_running_model_stats(1) };
    my @failed;
    push @failed,'Docker startup cleanup' unless VisLlama::Docker::stop_pending();
    push @failed,'public proxy' unless VisLlama::ProcessState::stop_proxy();
    if (my $pending=$STATE->{starting_proxy}) {
        if (VisLlama::ProcessState::stop_owned_process($pending->{proc},$pending->{pid},'starting proxy')) {
            delete $STATE->{starting_proxy};
        } else { push @failed,'starting proxy'; }
    }
    # Keep attempting independent trees after one fails. Only verified exits
    # leave the registry; a later Stop targets the original retained handles.
    for my $registry (qw(starting_engines router_engines)) {
        for my $key (sort keys %{$STATE->{$registry}||{}}) {
            my $eng=$STATE->{$registry}{$key};
            if (VisLlama::ProcessState::stop_owned_process($eng->{proc},$eng->{pid},"Router engine $key")) {
                delete $STATE->{$registry}{$key};
            } else { push @failed,"Router engine $key"; }
        }
    }
    delete $STATE->{starting_engines} unless keys %{$STATE->{starting_engines}||{}};
    if (VisLlama::ProcessState::stop_owned_process($STATE->{proc},$STATE->{pid},'direct server')) {
        # Preserve direct-mode exit/sidecar diagnostics before releasing its handle.
        VisLlama::ProcessState::proc_running() if $STATE->{proc};
        $STATE->{proc}=undef;
        $STATE->{pid}=undef;
    } else { push @failed,'direct server'; }
    if (@failed) {
        die 'Managed process termination could not be confirmed; ownership retained for retry: '.join(', ',@failed);
    }
    $STATE->{router_engines}={};
    $STATE->{router_route_map}=undef;
    $STATE->{router_control_token}=undef;
    return VisLlama::ProcessState::state_payload();
}

1;
