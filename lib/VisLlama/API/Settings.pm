package VisLlama::API::Settings;

# Installation and Router service settings endpoints. Keep Router service
# persistence here, independent of model snapshots and Router start/restart.
use strict;
use VisLlama::Engines ();
use warnings;
use VisLlama::ProcessState ();

use File::Basename qw(basename);

use VisLlama::Context qw($APP_VERSION %CFG $STATE);
use VisLlama::Util qw(jtrue jfalse);
use VisLlama::Builds ();
use VisLlama::Catalog ();
use VisLlama::Config ();
use VisLlama::HTTP ();
use VisLlama::Models ();
use VisLlama::Platform ();

# Handle the explicitly dispatched routes for this API scope.
# Each branch sends its own response and returns; unknown routes fail closed.
sub handle {
    my ($sock, $path, $req) = @_;
    if ($path eq '/api/config') {
        my ($build_cfg, $model_cfg) = VisLlama::Config::runtime_config_paths();
        return VisLlama::HTTP::json_response($sock, 200, {
            engine_builds=>VisLlama::Engines::builds(),
            ok=>jtrue, app_version=>$APP_VERSION, platform=>($^O eq 'MSWin32'?'windows':$^O), server_executable=>VisLlama::Platform::server_name(), model_root=>$CFG{model_root}, builds=>VisLlama::Builds::build_entries_payload(),
            build_config_file=>$build_cfg, model_root_config_file=>$model_cfg,
            discovery_root=>$CFG{discovery_root}, discovery_config_file=>VisLlama::Config::discovery_root_config_path(),
            models=>VisLlama::Models::scan_models(), state=>VisLlama::ProcessState::state_payload(),
            router_presets=>VisLlama::Catalog::load_router_presets(), router_json=>(VisLlama::Catalog::router_paths())[0], router_ini=>(VisLlama::Catalog::router_paths())[1],
            router_service=>VisLlama::Config::load_router_service_config(), router_service_file=>VisLlama::Config::router_service_config_path(),
        });
    }
    if ($path eq '/api/fs-list') {
        my $result = VisLlama::Models::list_server_folders($req->{path} // '', $req->{include_files} ? 1 : 0);
        return VisLlama::HTTP::fail_json($sock, 'Folder does not exist or cannot be read on this server', 404) unless $result;
        return VisLlama::HTTP::json_response($sock, 200, { ok=>jtrue, %$result });
    }
    if ($path eq '/api/build-scan') {
        my $root = $req->{root} // '';
        $root =~ s/^\s+|\s+$//g;
        return VisLlama::HTTP::fail_json($sock, 'Select a readable discovery root') unless length($root) && -d $root && -r $root;
        VisLlama::Config::save_discovery_root_config($root);
        my ($found, $limited, $visited) = VisLlama::Builds::discover_builds($root);
        my %used = map { lc($_) => 1 } @{$CFG{build_order} || []};
        my @results;
        for my $item (@$found) {
            my $p = VisLlama::Builds::build_probe($item->{exe}, 0);
            my $base = $p->{build} ? 'llama.cpp b' . $p->{build} : basename($item->{dir});
            $base .= ' - ' . basename($item->{dir}) if $p->{build};
            my $alias = $base;
            my $n = 2;
            $alias = "$base ($n)" , $n++ while $used{lc $alias};
            $used{lc $alias} = 1;
            push @results, { %$item, suggested_alias=>$alias, version=>$p->{version},
                build=>$p->{build}, commit=>$p->{commit}, size=>$p->{size}, modified=>$p->{modified} };
        }
        return VisLlama::HTTP::json_response($sock, 200, { ok=>jtrue, root=>$root, builds=>\@results,
            limited=>$limited ? jtrue : jfalse, scanned_directories=>$visited });
    }
    if ($path eq '/api/build-details') {
        my $alias = $req->{alias} // '';
        return VisLlama::HTTP::fail_json($sock, 'Unknown build') unless exists $CFG{builds}{$alias};
        my $exe = VisLlama::Builds::find_server_exe($CFG{builds}{$alias});
        return VisLlama::HTTP::fail_json($sock, 'llama-server executable not found') unless $exe;
        my $probe = VisLlama::Builds::build_probe($exe, 1);
        return VisLlama::HTTP::json_response($sock, 200, { ok=>jtrue, alias=>$alias, exe=>$exe, %$probe });
    }
    if ($path eq '/api/build-save') {
        my $alias = $req->{alias} // '';
        my $dir = $req->{path} // '';
        my $old_alias = $req->{old_alias} // '';
        $alias =~ s/^\s+|\s+$//g;
        $dir =~ s/^\s+|\s+$//g;
        $old_alias =~ s/^\s+|\s+$//g;
        return VisLlama::HTTP::fail_json($sock, 'Build alias is required') unless length $alias;
        return VisLlama::HTTP::fail_json($sock, 'Build alias contains invalid control characters') if $alias =~ /[\x00-\x1f\x7f]/;
        if (($req->{type}//'') eq 'docker') {
            my $image=$req->{image}//'';$image =~ s/^\s+|\s+$//g;
            $dir=VisLlama::Docker::validate_image($image);
        } else {
            return VisLlama::HTTP::fail_json($sock, 'Build folder is required') unless length $dir;
            return VisLlama::HTTP::fail_json($sock, 'Build folder does not exist on this server') unless -d $dir;
            return VisLlama::HTTP::fail_json($sock, 'llama-server executable not found in this build folder') unless VisLlama::Builds::find_server_exe($dir);
        }
        return VisLlama::HTTP::fail_json($sock, 'Build alias is already used') if exists($CFG{builds}{$alias}) && $alias ne $old_alias;
        return VisLlama::HTTP::fail_json($sock, 'Build being edited no longer exists') if length($old_alias) && !exists($CFG{builds}{$old_alias});
        my @entries;
        my $updated = 0;
        for my $name (@{$CFG{build_order} || []}) {
            next unless exists $CFG{builds}{$name};
            if ((length($old_alias) && $name eq $old_alias) || (!length($old_alias) && $name eq $alias)) {
                push @entries, { alias=>$alias, path=>$dir };
                $updated = 1;
            } else {
                push @entries, { alias=>$name, path=>$CFG{builds}{$name} };
            }
        }
        push @entries, { alias=>$alias, path=>$dir } unless $updated;
        my %seen;
        @entries = grep { !$seen{$_->{alias}}++ } @entries;
        my $rp=VisLlama::Catalog::load_router_presets();my $changed=0;
        if (length($old_alias) && $old_alias ne $alias) {
            for my $p (@$rp) {
                if (($p->{build}//'') eq $old_alias) {$p->{build}=$alias;$p->{ui}{build}=$alias if ref($p->{ui}) eq 'HASH';$changed=1;}
            }
        }
        if ($changed) {
            # Planning uses the prospective alias map, but publication includes
            # builds, catalog and derived INIs in the same recovery generation.
            local $CFG{builds}={map {$_->{alias}=>$_->{path}} @entries};
            my ($build_file)=VisLlama::Config::runtime_config_paths();
            VisLlama::Catalog::save_router_presets($rp,[[$build_file,JSON::PP->new->ascii->pretty->canonical->encode(\@entries)]]);
        } else {VisLlama::Config::save_build_config(\@entries);}
        VisLlama::Config::load_runtime_configs();
        return VisLlama::HTTP::json_response($sock, 200, { ok=>jtrue, builds=>VisLlama::Builds::build_entries_payload() });
    }
    if ($path eq '/api/build-delete') {
        my $alias = $req->{alias} // '';
        return VisLlama::HTTP::fail_json($sock, 'Build alias is required') unless length $alias;
        my $rp=VisLlama::Catalog::load_router_presets();
        my @refs=map { $_->{alias}//'(unnamed)' } grep { (($_->{build}//'') eq $alias) } @$rp;
        return VisLlama::HTTP::fail_json($sock, 'Cannot delete build while Router Presets reference it: ' . join(', ',@refs)) if @refs;
        # Deleting a saved model does not necessarily stop its loaded child.
        # Keep the build while its managed runtime is still owned/running.
        for my $registry (qw(router_engines starting_engines)) {
            for my $eng (values %{$STATE->{$registry}||{}}) {
                return VisLlama::HTTP::fail_json($sock,'Stop Router before removing a build that is still running.')
                    if ($eng->{build}//'') eq $alias && VisLlama::ProcessState::router_engine_running($eng);
            }
        }
        return VisLlama::HTTP::fail_json($sock,'Stop Router before removing a build that is still running.')
            if $STATE->{proc} && ($STATE->{build}//'') eq $alias && VisLlama::ProcessState::proc_running();
        my @entries = map { { alias=>$_, path=>$CFG{builds}{$_} } }
                      grep { $_ ne $alias && exists $CFG{builds}{$_} } @{$CFG{build_order} || []};
        return VisLlama::HTTP::fail_json($sock,'Stop Router before removing the last build alias.')
            if !@entries && !@{VisLlama::Engines::builds()} && VisLlama::ProcessState::proc_running();
        VisLlama::Config::save_build_config(\@entries);
        VisLlama::Config::load_runtime_configs();
        return VisLlama::HTTP::json_response($sock, 200, { ok=>jtrue, builds=>VisLlama::Builds::build_entries_payload() });
    }
    if ($path eq '/api/model-root-save') {
        my $root = $req->{path} // '';
        $root =~ s/^\s+|\s+$//g;
        return VisLlama::HTTP::fail_json($sock, 'Model root folder is required') unless length $root;
        return VisLlama::HTTP::fail_json($sock, 'Model root folder does not exist on this server') unless -d $root;
        VisLlama::Config::save_model_root_config($root);
        VisLlama::Config::load_runtime_configs();
        return VisLlama::HTTP::json_response($sock, 200, { ok=>jtrue, model_root=>$CFG{model_root}, models=>VisLlama::Models::scan_models() });
    }
    if ($path eq '/api/router-settings-save') {
        my $cfg = eval { VisLlama::Config::save_router_service_config($req) };
        return VisLlama::HTTP::fail_json($sock, $@) if $@;
        return VisLlama::HTTP::json_response($sock, 200, { ok=>jtrue, router_service=>$cfg, config_file=>VisLlama::Config::router_service_config_path() });
    }
    return VisLlama::HTTP::fail_json($sock, "Unknown API route", 404);
}

1;
