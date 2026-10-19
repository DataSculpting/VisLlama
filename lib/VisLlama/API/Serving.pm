package VisLlama::API::Serving;

# Lifecycle endpoints delegate to Process and Router. Calculated model loads
# use the central serialized path; other modes keep their native fitting behavior.
use strict;
use VisLlama::Engines ();
use warnings;
use VisLlama::ProcessState ();

use VisLlama::Context qw($STATE);
use VisLlama::Util qw(jtrue);
use VisLlama::Catalog ();
use VisLlama::HTTP ();
use VisLlama::ModelStats ();
use VisLlama::Process ();
use VisLlama::Router ();
use VisLlama::Preflight ();

# Handle the explicitly dispatched routes for this API scope.
# Each branch sends its own response and returns; unknown routes fail closed.
sub handle {
    my ($sock, $path, $req) = @_;
    if ($path eq '/api/model-preflight') {
        my $id=VisLlama::Preflight::issue($req);
        return VisLlama::HTTP::json_response($sock,200,{ok=>jtrue,preflight_id=>$id,restart_required=>defined($id)?JSON::PP::false:JSON::PP::true});
    }
    if ($path eq '/api/router-apply-config') {
        return VisLlama::HTTP::fail_json($sock,'Router is not running',400) unless VisLlama::ProcessState::proc_running() && ($STATE->{mode}//'') eq 'router';
        my $res = eval { VisLlama::Router::apply_router_config_live($req->{force_unload_moved} ? 1 : 0) };
        return VisLlama::HTTP::fail_json($sock,$@||'Unable to apply Router configuration',500) if $@;
        return VisLlama::HTTP::json_response($sock,200,{ok=>jtrue,%$res});
    }
    if ($path eq '/api/router-models') {
        return VisLlama::HTTP::fail_json($sock,'Router is not running',400) unless VisLlama::ProcessState::proc_running() && ($STATE->{mode}//'') eq 'router';
        my $j=eval { VisLlama::Router::router_models_merged() };
        return VisLlama::HTTP::fail_json($sock,$@||'Router query failed',500) if $@;
        return VisLlama::HTTP::json_response($sock,200,{ok=>jtrue,result=>$j});
    }
    if ($path eq '/api/router-load' || $path eq '/api/router-unload') {
        return VisLlama::HTTP::fail_json($sock,'Router is not running',400) unless VisLlama::ProcessState::proc_running() && ($STATE->{mode}//'') eq 'router';
        my $model=$req->{model}//''; return VisLlama::HTTP::fail_json($sock,'Model name is required') unless length $model;
        my $eng=VisLlama::Router::router_engine_for_model($model);
        return VisLlama::HTTP::fail_json($sock,'No running router engine owns this model',404) unless $eng;
        my $priority_plan;
        if ($path eq '/api/router-load') {
            my ($preset)=grep {($_->{alias}//'') eq $model && $_->{enabled}} @{VisLlama::Catalog::load_router_presets()};
            die 'Enabled model is not configured' unless $preset;
            VisLlama::Preflight::saved($preset,1);
            my $result = eval { VisLlama::Router::load_router_model_centrally($model,$eng) };
            return VisLlama::HTTP::fail_json($sock,$@||'Could not load model',500) if $@;
            return VisLlama::HTTP::json_response($sock,200,{ok=>jtrue,result=>$result,build=>$eng->{build},gpu_priority_plan=>$result->{gpu_priority_plan}});
        }
        VisLlama::Preflight::check($req,0) if $req->{preflight_id};
        eval { VisLlama::ModelStats::sample_running_model_stats(1, $model) } if $path eq '/api/router-unload';
        my $ep=$path eq '/api/router-load'?'/models/load':'/models/unload';
        my $j=eval { VisLlama::Router::router_http_engine($eng,'POST',$ep,{model=>$model}) };
        return VisLlama::HTTP::fail_json($sock,$@||'Router action failed',500) if $@;
        if ($path eq '/api/router-unload') {
            VisLlama::ModelStats::forget_model($model);
        }
        return VisLlama::HTTP::json_response($sock,200,{ok=>jtrue,result=>{},build=>$eng->{build},gpu_priority_plan=>$priority_plan});
    }
    if ($path eq '/api/router-ensure-load') {
        return VisLlama::HTTP::fail_json($sock,'Router is not running',400) unless VisLlama::ProcessState::proc_running() && ($STATE->{mode}//'') eq 'router';
        return VisLlama::HTTP::fail_json($sock,'Unauthorized',403) unless defined($STATE->{router_control_token})
            && ($req->{token}//'') eq $STATE->{router_control_token};
        my $model = $req->{model}//'';
        my $eng = VisLlama::Router::router_engine_for_model($model);
        return VisLlama::HTTP::fail_json($sock,'No running router engine owns this model',404) unless $eng;
        my $items = VisLlama::Catalog::load_router_presets();
        my ($preset) = grep { $_->{enabled} && ($_->{alias}//'') eq $model && ($_->{build}//'') eq $eng->{build} } @$items;
        return VisLlama::HTTP::fail_json($sock,'Model is not a calculated split preset',400)
            unless $preset && (VisLlama::Engines::external($preset) || ($preset->{ui}{gpuPriority}//'') eq 'priority_split');
        die 'Automatic model loading is disabled; load this model in Router / Serving first'
            if $eng->{engine} && !$STATE->{router_autoload} && VisLlama::Engines::status($eng) ne 'loaded';
        VisLlama::Preflight::saved($preset,1);
        my $result = eval { VisLlama::Router::load_router_model_centrally($model,$eng) };
        return VisLlama::HTTP::fail_json($sock,$@||'Could not load model',500) if $@;
        return VisLlama::HTTP::json_response($sock,200,{ok=>jtrue,result=>$result});
    }
    if ($path eq '/api/start') {
        my $res = eval {
            if (($req->{mode}//'single') eq 'router') {
                VisLlama::Preflight::saved($_,0) for grep {$_->{enabled}} @{VisLlama::Catalog::load_router_presets()};
            } else {VisLlama::Preflight::validate({%$req,ui=>$req->{gpu_settings}||{}},0);}
            VisLlama::Process::start_server($req);
        };
        return VisLlama::HTTP::fail_json($sock, $@ || 'Failed to start', 500) if $@;
        return VisLlama::HTTP::json_response($sock, 200, $res);
    }
    if ($path eq '/api/stop') {
        return VisLlama::HTTP::json_response($sock, 200, VisLlama::Process::stop_server());
    }
    if ($path eq '/api/stop-compute') {
        my $res = eval { VisLlama::Process::restart_proxy_for_compute_cancel() };
        return VisLlama::HTTP::fail_json($sock, $@ || 'Unable to stop active compute', 500) if $@;
        return VisLlama::HTTP::json_response($sock, 200, { ok=>jtrue, status=>$res, message=>'Active proxy inference connections were terminated; loaded router models remain resident.' });
    }
    return VisLlama::HTTP::fail_json($sock, "Unknown API route", 404);
}

1;
