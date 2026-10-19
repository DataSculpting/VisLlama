package VisLlama::App;

# Own the control listener lifecycle. Dispatch is serialized, and shutdown
# returns through managed process cleanup; importing this module starts nothing.
use strict;
use warnings;
use IO::Socket::INET;
use JSON::PP qw(decode_json);
use Time::HiRes qw(time);
use VisLlama::Context qw($APP_VERSION %CFG $STATE);
use VisLlama::Config ();
use VisLlama::Storage ();
use VisLlama::Lifecycle ();
use VisLlama::Performance ();
use VisLlama::Command ();
use VisLlama::GPUProviders ();
use VisLlama::Process ();
use VisLlama::ModelStats ();
use VisLlama::HTTP ();
use VisLlama::API ();
use VisLlama::Assets ();
use VisLlama::View ();

# Loading modules for tests/tools must not start a server or stop processes.
# Once run() starts, retain the original best-effort cleanup after uncaught die.
my $SHUTDOWN_COMPLETE = 1;
END {
    eval { VisLlama::Process::stop_server() } unless $SHUTDOWN_COMPLETE;
}

# Read and dispatch one control request; convert exceptions into sanitized JSON.
sub handle_client {
    my ($client,$parsed) = @_;
    my $began=time();
    local $VisLlama::HTTP::STARTED=$began;
    $client->autoflush(1);
    # A browser disconnect during a response must not terminate the listener.
    local $SIG{PIPE} = 'IGNORE';
    eval {
        my @request=$parsed?@$parsed:eval {VisLlama::HTTP::read_request($client)};
        return VisLlama::HTTP::fail_json($client,$@,400) if $@;
        my ($method, $path, $headers, $body) = @request;
        return unless $method;
        if ($method eq 'GET' && ($path eq '/' || $path eq '/index.html')) {
            VisLlama::HTTP::html_response($client, VisLlama::View::app_html());
        } elsif ($method eq 'GET') {
            VisLlama::Assets::serve($client, $path);
        } elsif ($method eq 'POST' && $path =~ m{^/api/}) {
            my $req = {};
            if (defined $body && length $body) {
                $req = eval { decode_json($body) };
                return VisLlama::HTTP::fail_json($client, 'Invalid JSON body')
                    unless $req && ref($req) eq 'HASH';
            }
            local $STATE->{active_operation}=$STATE->{active_operation};
            $STATE->{active_operation}={id=>$req->{action_id},path=>$path,started=>time()}
                if $path =~ m{^/api/(?:start|router-load|router-apply-config|router-ensure-load)$};
            VisLlama::API::handle_api($client, $path, $req);
            VisLlama::Performance::record(VisLlama::API::known_route($path)?$path:'other_api',time()-$began);
        } else {
            VisLlama::HTTP::fail_json($client, 'Not found', 404);
        }
    };
    if ($@) { my $error=$@; eval { VisLlama::HTTP::fail_json($client, $error, 500) } }
}

# Load configuration, run the serialized accept loop, and stop owned children
# on a signal. END retries cleanup if normal shutdown could not complete.
sub run {
    $SHUTDOWN_COMPLETE = 0;
    $STATE->{require_runtime_token}=1;
    my $ownership=VisLlama::Storage::controller_lock();
    VisLlama::Config::load_runtime_configs();
    my $server = IO::Socket::INET->new(
        LocalAddr => $CFG{listen_host}, LocalPort => $CFG{listen_port},
        Proto => 'tcp', Listen => 10, ReuseAddr => 1,
    ) or die "Cannot listen on http://$CFG{listen_host}:$CFG{listen_port}: $!\n";

    print "VisLlama $APP_VERSION\n";
    print "  UI:     http://$CFG{listen_host}:$CFG{listen_port}/\n";
    print "  Models: " . ($CFG{model_root} || '(not configured)') . "\n";
    print "Press Ctrl+C to stop the control panel and its managed model servers.\n\n";

    my $shutdown_requested = 0;
    my $request_shutdown = sub { $shutdown_requested = 1; };
    local $SIG{INT} = $request_shutdown;
    local $SIG{TERM} = $request_shutdown;
    local $SIG{BREAK} = $request_shutdown if exists $SIG{BREAK};

    # Keep the nonblocking accept/poll behavior needed for Windows Ctrl+C.
    $server->blocking(0);
    # Long load/probe loops allow read-only status/model polls and explicit Stop.
    # Telemetry must not turn a healthy model poll into a busy error. Engine
    # reads retain their HTTP timeout; nested pumping stays disabled, and no
    # second load/save can reenter the planner or mutate its catalog.
    my @deferred;
    local $VisLlama::Lifecycle::PUMP=sub {
        die 'Operation cancelled by shutdown' if $shutdown_requested;
        my $waiting=$server->accept();return unless $waiting;
        local $VisLlama::Lifecycle::PUMP;
        my @request=eval {VisLlama::HTTP::read_request($waiting)};
        if ($@) {VisLlama::HTTP::fail_json($waiting,$@,400);}
        elsif (($request[0]//'') eq 'POST' && ($request[1]//'') =~ m{^/api/(?:status|router-models|stop)$}) {handle_client($waiting,\@request);}
        elsif (!$STATE->{active_operation} && @deferred<32) {
            # Probe/telemetry work is not a lifecycle mutation. Keep accepted
            # requests in order and dispatch after it returns, never reentrantly.
            push @deferred,[$waiting,\@request];return;
        } else {VisLlama::HTTP::fail_json($waiting,'Controller is busy. Retry after the current operation.',409);}
        close $waiting;
    };
    while (!$shutdown_requested) {
        VisLlama::Command::reap();
        my $queued=shift @deferred;
        my $client = $queued ? $queued->[0] : $server->accept();
        if (!$client) {
            VisLlama::GPUProviders::tick();
            VisLlama::ModelStats::sample_if_due();
            select(undef, undef, undef, 0.10);
            next;
        }
        # Mutations stay serialized. Probe/load checkpoints service status and
        # cancellation; other requests receive a retryable busy conflict.
        handle_client($client,$queued ? $queued->[1] : undef);
        close $client;
    }

    close $_->[0] for @deferred;
    print "\nStopping VisLlama...\n";
    my $shutdown_ok = eval { VisLlama::Process::stop_server(); 1 };
    $SHUTDOWN_COMPLETE = 1 if $shutdown_ok;
    warn "Unable to stop all managed processes: $@" unless $shutdown_ok;
    eval { close $server };
    print "Stopped.\n";
    return 0;
}

1;
