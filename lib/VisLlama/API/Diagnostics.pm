package VisLlama::API::Diagnostics;

# Read status, telemetry and history and manage the visible log window.
# Payload construction stays in the corresponding subsystem modules.
use strict;
use warnings;
use VisLlama::ProcessState ();

use VisLlama::Util qw(jtrue);
use VisLlama::HTTP ();
use VisLlama::Logs ();
use VisLlama::Errors ();
use VisLlama::ModelStats ();
use VisLlama::Telemetry ();
use VisLlama::GPUProviders ();
use VisLlama::Readiness ();
use VisLlama::Performance ();

# Handle the explicitly dispatched routes for this API scope.
# Each branch sends its own response and returns; unknown routes fail closed.
sub handle {
    my ($sock, $path, $req) = @_;
    if ($path eq '/api/gpu-stats') {
        VisLlama::GPUProviders::request_refresh() if $req->{refresh_providers};
        my $nvidia = VisLlama::Telemetry::collect_nvidia_gpu_stats();
        # NVIDIA selection wraps its existing result; it does not add a probe,
        # change the collector/cache or gate inference on optional discovery.
        my $provider={id=>'nvidia-smi',vendor=>'NVIDIA',status=>$nvidia->{available}?'monitoring_ready':'unavailable',
            message=>$nvidia->{available}?'Existing NVIDIA monitoring is available.':'NVIDIA telemetry is unavailable.',
            identity_status=>'Existing CUDA verification runs for the selected build at launch.'};
        return VisLlama::HTTP::json_response($sock, 200, { ok=>jtrue, nvidia=>$nvidia, amd=>VisLlama::Telemetry::collect_amd_gpu_stats(), intel=>VisLlama::Telemetry::collect_intel_gpu_stats(), system=>VisLlama::Telemetry::collect_system_stats(), gpu_providers=>{nvidia=>$provider} });
    }
    if ($path eq '/api/model-stats') {
        eval { VisLlama::ModelStats::sample_running_model_stats(0) };
        return VisLlama::HTTP::json_response($sock, 200, VisLlama::ModelStats::model_stats_payload());
    }
    if ($path eq '/api/clear-log') {
        return VisLlama::HTTP::json_response($sock, 200, VisLlama::Logs::clear_log_view());
    }
    if ($path eq '/api/status') {
        VisLlama::Readiness::refresh_endpoint();
        my $s = VisLlama::ProcessState::state_payload();
        $s->{performance}=VisLlama::Performance::payload();
        $s->{log_tail} = VisLlama::Errors::browser_log(VisLlama::Logs::tail_log(40000));
        return VisLlama::HTTP::json_response($sock, 200, $s);
    }
    return VisLlama::HTTP::fail_json($sock, "Unknown API route", 404);
}

1;
