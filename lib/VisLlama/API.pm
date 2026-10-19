package VisLlama::API;

# Explicit API route table. Scope-specific handlers own operations; this
# module does not expose arbitrary Perl methods or filesystem paths.
use strict;
use VisLlama::API::Engines ();
use warnings;
use VisLlama::HTTP ();
use VisLlama::Chat ();
use VisLlama::Storage ();
use VisLlama::Context qw($STATE);
use VisLlama::Lifecycle ();
use VisLlama::API::Settings ();
use VisLlama::API::Models ();
use VisLlama::API::Serving ();
use VisLlama::API::Diagnostics ();

my %ROUTES = (
    '/api/engine-library-folders' => \&VisLlama::API::Engines::handle,
    '/api/engine-import-inspect' => \&VisLlama::API::Engines::handle,
    '/api/engine-list' => \&VisLlama::API::Engines::handle,
    '/api/engine-build-save' => \&VisLlama::API::Engines::handle,
    '/api/engine-build-delete' => \&VisLlama::API::Engines::handle,
    '/api/engine-capabilities' => \&VisLlama::API::Engines::handle,
    '/api/engine-discover' => \&VisLlama::API::Engines::handle,
    '/api/engine-definition-defaults' => \&VisLlama::API::Engines::handle,
    '/api/engine-definition-save' => \&VisLlama::API::Engines::handle,
    '/api/engine-probe' => \&VisLlama::API::Engines::handle,
    '/api/engine-preset-save' => \&VisLlama::API::Engines::handle,
    '/api/engine-load-check' => \&VisLlama::API::Engines::handle,
    '/api/engine-preview' => \&VisLlama::API::Engines::handle,

    '/api/chat-info' => \&VisLlama::Chat::handle,
    '/api/config' => \&VisLlama::API::Settings::handle,
    '/api/refresh-models' => \&VisLlama::API::Models::handle,
    '/api/fs-list' => \&VisLlama::API::Settings::handle,
    '/api/build-scan' => \&VisLlama::API::Settings::handle,
    '/api/build-details' => \&VisLlama::API::Settings::handle,
    '/api/build-save' => \&VisLlama::API::Settings::handle,
    '/api/build-delete' => \&VisLlama::API::Settings::handle,
    '/api/model-root-save' => \&VisLlama::API::Settings::handle,
    '/api/devices' => \&VisLlama::API::Models::handle,
    '/api/gpu-priority-preview' => \&VisLlama::API::Models::handle,
    '/api/help' => \&VisLlama::API::Models::handle,
    '/api/router-settings-save' => \&VisLlama::API::Settings::handle,
    '/api/router-presets' => \&VisLlama::API::Models::handle,
    '/api/router-preset-order' => \&VisLlama::API::Models::handle,
    '/api/router-preset-save' => \&VisLlama::API::Models::handle,
    '/api/router-preset-build' => \&VisLlama::API::Models::handle,
    '/api/router-preset-startup' => \&VisLlama::API::Models::handle,
    '/api/router-preset-delete' => \&VisLlama::API::Models::handle,
    '/api/router-preset-toggle' => \&VisLlama::API::Models::handle,
    '/api/router-apply-config' => \&VisLlama::API::Serving::handle,
    '/api/model-preflight' => \&VisLlama::API::Serving::handle,
    '/api/router-models' => \&VisLlama::API::Serving::handle,
    '/api/router-load' => \&VisLlama::API::Serving::handle,
    '/api/router-unload' => \&VisLlama::API::Serving::handle,
    '/api/router-ensure-load' => \&VisLlama::API::Serving::handle,
    '/api/start' => \&VisLlama::API::Serving::handle,
    '/api/stop' => \&VisLlama::API::Serving::handle,
    '/api/gpu-stats' => \&VisLlama::API::Diagnostics::handle,
    '/api/model-stats' => \&VisLlama::API::Diagnostics::handle,
    '/api/stop-compute' => \&VisLlama::API::Serving::handle,
    '/api/clear-log' => \&VisLlama::API::Diagnostics::handle,
    '/api/status' => \&VisLlama::API::Diagnostics::handle,
);

sub known_route {return exists $ROUTES{$_[0]}}

# -----------------------------------------------------------------------------
# Dispatch all VisLlama control API POST endpoints.
# -----------------------------------------------------------------------------
sub handle_api {
    my ($sock, $path, $req) = @_;
    my $handler = $ROUTES{$path};
    return VisLlama::HTTP::fail_json($sock, "Unknown API route", 404) unless $handler;
    if ($STATE->{require_runtime_token} && $path =~ m{^/api/(?:start|stop|stop-compute|model-preflight|engine-load-check|router-(?:load|unload|apply-config))$}) {
        my $valid=eval {VisLlama::Lifecycle::check($req);1};
        return VisLlama::HTTP::fail_json($sock,$@,409) unless $valid;
    }
    if ($path eq '/api/stop' && $req->{cancel_operation}) {
        return VisLlama::HTTP::fail_json($sock,'Runtime changed. Refresh status and retry the action.',409)
            unless ($STATE->{active_operation}{id}//'') eq $req->{cancel_operation};
    }
    return VisLlama::Storage::with_lock(sub {$handler->($sock,$path,$req)})
        if $path =~ m{^/api/(?:router-preset-(?:order|save|build|startup|delete|toggle)|build-(?:save|delete)|model-root-save|router-settings-save)$};
    return $handler->($sock, $path, $req);
}

1;
