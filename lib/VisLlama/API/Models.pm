package VisLlama::API::Models;

# Model catalog and editor endpoints. Catalog order is durable startup order.
# A model UI snapshot never becomes a source of Router service host/port settings.
use strict;
use VisLlama::Engines ();
use warnings;

use VisLlama::Context qw(%CFG);
use VisLlama::Util qw(jtrue jfalse);
use VisLlama::Builds ();
use VisLlama::Arguments ();
use VisLlama::Catalog ();
use VisLlama::GPUPlanner ();
use VisLlama::HTTP ();
use VisLlama::Models ();
use VisLlama::Paths ();
use VisLlama::Preflight ();

# Handle the explicitly dispatched routes for this API scope.
# Each branch sends its own response and returns; unknown routes fail closed.
sub handle {
    my ($sock, $path, $req) = @_;
    if ($path eq '/api/refresh-models') {
        return VisLlama::HTTP::json_response($sock, 200, { ok=>jtrue, model_root=>$CFG{model_root}, models=>VisLlama::Models::scan_models() });
    }
    if ($path eq '/api/devices') {
        my $name = $req->{build} // '';
        return VisLlama::HTTP::fail_json($sock, 'Unknown build') unless exists $CFG{builds}{$name};
        my $exe = VisLlama::Builds::find_server_exe($CFG{builds}{$name});
        return VisLlama::HTTP::fail_json($sock, 'llama-server executable not found') unless $exe;
        my $txt = VisLlama::Builds::checked_probe($exe, '--list-devices');
        my $devices = VisLlama::Builds::parse_devices($txt);
        return VisLlama::HTTP::json_response($sock, 200, { ok=>jtrue, raw=>$txt, devices=>$devices });
    }
    if ($path eq '/api/gpu-priority-preview') {
        my $model = $req->{model} // '';
        return VisLlama::HTTP::fail_json($sock,'Model must be under the GGUF model root')
            unless $model && VisLlama::Paths::canonical_under($model,$CFG{model_root});
        if (ref($req->{args}) eq 'ARRAY') {
            my $args = eval { VisLlama::Arguments::normalize($req->{args}) };
            return VisLlama::HTTP::fail_json($sock,$@) if $@;
            $req->{args}=$args;
        }
        my $plan = eval { VisLlama::GPUPlanner::gpu_plan_for_mode($req->{build}//'', $model, $req->{devices}, $req->{reserve}, $req->{mode}, $req->{settings}, $req->{args}) };
        return VisLlama::HTTP::fail_json($sock,$@) if $@;
        return VisLlama::HTTP::json_response($sock,200,{ok=>jtrue,plan=>$plan});
    }
    if ($path eq '/api/help') {
        my $name = $req->{build} // '';
        return VisLlama::HTTP::fail_json($sock, 'Unknown build') unless exists $CFG{builds}{$name};
        my $exe = VisLlama::Builds::find_server_exe($CFG{builds}{$name});
        return VisLlama::HTTP::fail_json($sock, 'llama-server executable not found') unless $exe;
        my $txt = VisLlama::Builds::checked_probe($exe, '--help');
        return VisLlama::HTTP::json_response($sock, 200, { ok=>jtrue, raw=>$txt, options=>VisLlama::Builds::parse_help($txt) });
    }
    if ($path eq '/api/router-presets') {
        my ($json_file, $ini_file) = VisLlama::Catalog::router_paths();
        return VisLlama::HTTP::json_response($sock, 200, { ok=>jtrue, presets=>VisLlama::Catalog::load_router_presets(), json_file=>$json_file, ini_file=>$ini_file });
    }
    if ($path eq '/api/router-preset-order') {
        my $items = VisLlama::Catalog::load_router_presets();
        my $ordered = eval { VisLlama::Catalog::reorder_router_presets($items,$req->{aliases}) };
        return VisLlama::HTTP::fail_json($sock,$@||'Invalid model load order') if $@;
        my $saved = eval { VisLlama::Catalog::save_router_presets($ordered); 1 };
        return VisLlama::HTTP::fail_json($sock,$@||'Could not save model load order',500) unless $saved;
        return VisLlama::HTTP::json_response($sock,200,{ok=>jtrue,presets=>$ordered});
    }
    if ($path eq '/api/router-preset-save') {
        VisLlama::Preflight::check($req,1) if $req->{preflight_id};
        my $alias = $req->{alias} // '';
        $alias =~ s/^\s+|\s+$//g;
        return VisLlama::HTTP::fail_json($sock, 'API alias is required') unless length $alias;
        return VisLlama::HTTP::fail_json($sock, 'Alias may contain only letters, numbers, dot, underscore, colon and hyphen') unless $alias =~ /^[A-Za-z0-9._:-]+$/;
        my $model = $req->{model} // '';
        return VisLlama::HTTP::fail_json($sock, 'Model path is required') unless $model && -f $model && VisLlama::Paths::canonical_under($model,$CFG{model_root});
        my $preset_build = $req->{build} // '';
        return VisLlama::HTTP::fail_json($sock, 'A valid llama.cpp build must be selected for this Router Preset') unless length($preset_build) && exists $CFG{builds}{$preset_build};
        my $args = ref($req->{args}) eq 'ARRAY' ? [ @{$req->{args}} ] : [];
        # Reject malformed CLI tokens before probing GPUs or changing a preset.
        my $valid_args = eval { $args = VisLlama::Arguments::normalize($args); VisLlama::Catalog::args_to_preset_options($args); 1 };
        return VisLlama::HTTP::fail_json($sock,$@) unless $valid_args;
        # Clearing the manual Tensor split removes stale raw overrides only in
        # Manual mode. Even split generates its own weights while that disabled
        # manual field may be blank; keep those generated weights through save.
        if (ref($req->{ui}) eq 'HASH') {
            my $ts = defined($req->{ui}{tensorSplit}) ? $req->{ui}{tensorSplit} : '';
            $ts =~ s/^\s+|\s+$//g;
            if ($ts eq '' && ($req->{ui}{gpuPriority}//'manual') eq 'manual') {
                $args = VisLlama::Util::strip_arg_with_value($args, '--tensor-split');
            }
        }
        for (my $i=0; $i < @$args; $i++) { if (($args->[$i] // '') eq '--chat-template-file') { my $tpl=$args->[$i+1] // ''; return VisLlama::HTTP::fail_json($sock, "Chat template file does not exist on this server: $tpl") unless length($tpl) && -f $tpl; } }
        my $items = VisLlama::Catalog::load_router_presets();
        my $original_alias = $req->{original_alias} // '';
        $original_alias =~ s/^\s+|\s+$//g;
        my $previous;
        if (length $original_alias) {
            for my $p (@$items) { if (($p->{alias}//'') eq $original_alias) { $previous=$p; last; } }
        }
        VisLlama::Engines::check_replacement($req,$previous,'llamacpp');
        for my $target (grep {($_->{alias}//'') eq $alias} @$items) {VisLlama::Engines::check_replacement($req,$target,'llamacpp');}
        my $ui = ref($req->{ui}) eq 'HASH' ? { %{$req->{ui}} } : {};
        if (($ui->{gpuPriority}//'') =~ /^(?:priority|priority_split)$/) {
            my $check = eval { VisLlama::GPUPlanner::gpu_plan_for_mode($preset_build,$model,$ui->{devices},$ui->{gpuReserve},$ui->{gpuPriority},$ui,$args) };
            return VisLlama::HTTP::fail_json($sock,$@) if $@;
        }
        $ui->{build} = $preset_build;
        $ui->{model} = $model;
        $ui->{alias} = $alias;
        # Retain lifecycle choices from the existing catalog entry. The model
        # editor edits model settings, not startup/enabled state or service binding.
        my $obj = {
            alias=>$alias, model=>$model, build=>$preset_build,
            enabled=>($previous ? $previous->{enabled} : jtrue),
            load_on_startup=>($previous ? $previous->{load_on_startup} : ($req->{load_on_startup}?jtrue:jfalse)),
            stop_timeout=>($previous ? int($previous->{stop_timeout}||10) : int($req->{stop_timeout}||10)),
            options=>VisLlama::Catalog::args_to_preset_options($args), ui=>$ui, saved_at=>scalar localtime,
        };
        my $replaced=0;
        my @updated;
        for my $p (@$items) {
            if (($p->{alias}//'') eq $alias || (length($original_alias) && ($p->{alias}//'') eq $original_alias)) {push @updated,$obj unless $replaced++;}
            else {push @updated,$p;}
        }
        push @updated,$obj unless $replaced;
        $items=\@updated;
        VisLlama::Catalog::save_router_presets($items);
        VisLlama::Preflight::committed($req);
        # Saving does not replace a loaded child. The browser's separate live
        # apply/load sequence may activate this catalog; new groups need restart.
        return VisLlama::HTTP::json_response($sock,200,{ok=>jtrue,presets=>$items,replaced=>$replaced?jtrue:jfalse});
    }
    if ($path eq '/api/router-preset-build') {
        my $alias=$req->{alias}//''; my $build=$req->{build}//'';
        return VisLlama::HTTP::fail_json($sock,'Preset alias is required') unless length $alias;
        return VisLlama::HTTP::fail_json($sock,'Unknown llama.cpp build') unless length($build) && exists $CFG{builds}{$build};
        my $items=VisLlama::Catalog::load_router_presets(); my $found=0;
        for my $p (@$items) {
            if (($p->{alias}//'') eq $alias) {
                die 'Use the engine model editor to change this build' if VisLlama::Engines::external($p);
                $p->{build}=$build;
                $p->{ui}{build}=$build if ref($p->{ui}) eq 'HASH';
                $p->{saved_at}=scalar localtime;
                $found=1; last;
            }
        }
        return VisLlama::HTTP::fail_json($sock,'Preset not found',404) unless $found;
        VisLlama::Catalog::save_router_presets($items);
        return VisLlama::HTTP::json_response($sock,200,{ok=>jtrue,presets=>$items});
    }
    if ($path eq '/api/router-preset-startup') {
        my $alias=$req->{alias}//''; my $items=VisLlama::Catalog::load_router_presets(); my $found=0;
        for my $p (@$items) { if (($p->{alias}//'') eq $alias) { $p->{load_on_startup}=$req->{load_on_startup}?jtrue:jfalse; $found=1; last; } }
        return VisLlama::HTTP::fail_json($sock,'Preset not found',404) unless $found;
        VisLlama::Catalog::save_router_presets($items);
        # Router preset catalog/build changes are applied on the next Router restart.
        return VisLlama::HTTP::json_response($sock,200,{ok=>jtrue,presets=>$items});
    }
    if ($path eq '/api/router-preset-delete') {
        my $alias=$req->{alias}//''; my $items=VisLlama::Catalog::load_router_presets();
        my @keep=grep { ($_->{alias}//'') ne $alias } @$items;
        VisLlama::Catalog::save_router_presets(\@keep);
        # Router preset catalog/build changes are applied on the next Router restart.
        return VisLlama::HTTP::json_response($sock,200,{ok=>jtrue,presets=>\@keep});
    }
    if ($path eq '/api/router-preset-toggle') {
        my $alias=$req->{alias}//''; my $items=VisLlama::Catalog::load_router_presets(); my $found=0;
        for my $p (@$items) { if (($p->{alias}//'') eq $alias) { $p->{enabled}=$req->{enabled}?jtrue:jfalse; $found=1; last; } }
        return VisLlama::HTTP::fail_json($sock,'Preset not found',404) unless $found;
        VisLlama::Catalog::save_router_presets($items);
        # Router preset catalog/build changes are applied on the next Router restart.
        return VisLlama::HTTP::json_response($sock,200,{ok=>jtrue,presets=>$items});
    }
    return VisLlama::HTTP::fail_json($sock, "Unknown API route", 404);
}

1;
