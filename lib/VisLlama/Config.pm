package VisLlama::Config;

# Existing JSON persistence formats. Router service settings have their own
# authoritative file and explicit save path; do not merge model UI snapshots here.
use strict;
use warnings;

use JSON::PP qw(decode_json);
use File::Spec;

use VisLlama::Context qw(%CFG);
use VisLlama::Util qw(jtrue jfalse);
use VisLlama::Paths ();
use VisLlama::Storage ();

# -----------------------------------------------------------------------------
# Return paths for build and model-root configuration files.
# -----------------------------------------------------------------------------
sub runtime_config_paths {
    my $dir = VisLlama::Paths::presets_dir();
    return (
        File::Spec->catfile($dir, 'llama-builds.json'),
        File::Spec->catfile($dir, 'model-root.json'),
    );
}

# -----------------------------------------------------------------------------
# Start with no configured builds on a new installation.
# -----------------------------------------------------------------------------
sub default_build_entries {
    return [];
}

# -----------------------------------------------------------------------------
# Read JSON after recovery. Missing files use defaults; invalid files fail closed.
# -----------------------------------------------------------------------------
sub read_json_file {
    my ($path, $fallback) = @_;
    my $txt=VisLlama::Storage::read($path);
    return $fallback unless defined $txt;
    my $obj=eval {decode_json($txt)};
    die "Invalid saved JSON in $path: $@" if $@;
    return $obj;
}

# -----------------------------------------------------------------------------
# Write stable, pretty, ASCII-only JSON for portable Windows config files.
# -----------------------------------------------------------------------------
sub write_json_file_ascii {
    my ($path, $obj) = @_;
    my $json = JSON::PP->new->ascii(1)->pretty(1)->canonical(1)->encode($obj);
    VisLlama::Storage::write($path,$json);
}

# -----------------------------------------------------------------------------
# Persist the list of configured llama.cpp build aliases/paths.
# -----------------------------------------------------------------------------
sub save_build_config {
    my ($entries) = @_;
    my ($build_file) = runtime_config_paths();
    write_json_file_ascii($build_file, $entries);
}

# -----------------------------------------------------------------------------
# Persist the GGUF model root directory.
# -----------------------------------------------------------------------------
sub save_model_root_config {
    my ($root) = @_;
    my (undef, $model_file) = runtime_config_paths();
    write_json_file_ascii($model_file, { model_root => $root });
}

# Locate the persisted build-discovery search root beside the other presets.
sub discovery_root_config_path {
    return File::Spec->catfile(VisLlama::Paths::presets_dir(), 'build-discovery.json');
}

# Save the discovery root and update the in-memory copy used by the UI.
sub save_discovery_root_config {
    my ($root) = @_;
    write_json_file_ascii(discovery_root_config_path(), { root => $root });
    $CFG{discovery_root} = $root;
}

# -----------------------------------------------------------------------------
# Return the persistent Router service configuration path.
# -----------------------------------------------------------------------------
sub router_service_config_path {
    return File::Spec->catfile(VisLlama::Paths::presets_dir(), 'router-service.json');
}

# -----------------------------------------------------------------------------
# Default public Router endpoint and engine limits.
# -----------------------------------------------------------------------------
sub default_router_service_config {
    return {
        host => '0.0.0.0',
        port => 8080,
        models_max => 4,
        threads_http => '',
        autoload => jtrue,
    };
}

# -----------------------------------------------------------------------------
# Load Router service settings and backfill missing defaults.
# -----------------------------------------------------------------------------
sub load_router_service_config {
    my $path = router_service_config_path();
    # Recover any interrupted generation before deciding this is first run.
    my $cfg=read_json_file($path,undef);
    if (!defined $cfg) { $cfg=default_router_service_config();write_json_file_ascii($path,$cfg); }
    die 'Invalid saved Router service configuration' unless ref($cfg) eq 'HASH';
    my $d = default_router_service_config();
    for my $k (keys %$d) { $cfg->{$k} = $d->{$k} unless exists $cfg->{$k}; }
    return $cfg;
}

# -----------------------------------------------------------------------------
# Validate and save public Router service settings.
# -----------------------------------------------------------------------------
sub save_router_service_config {
    my ($req) = @_;
    die 'Router public host is required' unless defined $req->{host};
    my $host = $req->{host};
    $host =~ s/^\s+|\s+$//g;
    die 'Router public host is required' unless length $host;
    my $port = int($req->{port} || 8080);
    die 'Router public port must be between 1 and 65535' unless $port >= 1 && $port <= 65535;
    my $models_max = int($req->{models_max} // 4);
    die 'models-max must be >= 0' if $models_max < 0;
    my $threads_http = defined($req->{threads_http}) ? "$req->{threads_http}" : '';
    $threads_http =~ s/^\s+|\s+$//g;
    die 'HTTP threads must be a non-negative integer or blank' if length($threads_http) && $threads_http !~ /^\d+$/;
    my $cfg = {
        host => $host,
        port => $port,
        models_max => $models_max,
        threads_http => $threads_http,
        autoload => $req->{autoload} ? jtrue : jfalse,
    };
    write_json_file_ascii(router_service_config_path(), $cfg);
    return $cfg;
}

# -----------------------------------------------------------------------------
# Load persistent build/model-root settings into the in-memory CFG structure.
# -----------------------------------------------------------------------------
sub load_runtime_configs {
    my ($build_file, $model_file) = runtime_config_paths();
    my $entries = read_json_file($build_file, default_build_entries());
    $entries = [] unless ref($entries) eq 'ARRAY';
    my (%builds, @order);
    for my $entry (@$entries) {
        next unless ref($entry) eq 'HASH';
        my $alias = $entry->{alias} // '';
        my $path = $entry->{path} // '';
        $alias =~ s/^\s+|\s+$//g;
        $path =~ s/^\s+|\s+$//g;
        next unless length($alias) && length($path);
        next if exists $builds{$alias};
        $builds{$alias} = $path;
        push @order, $alias;
    }
    $CFG{builds} = \%builds;
    $CFG{build_order} = \@order;

    my $model_cfg = read_json_file($model_file, { model_root => '' });
    my $root = ref($model_cfg) eq 'HASH' ? ($model_cfg->{model_root} // '') : '';
    $root =~ s/^\s+|\s+$//g;
    $CFG{model_root} = $root;
    my $discovery = read_json_file(discovery_root_config_path(), {});
    $CFG{discovery_root} = ref($discovery) eq 'HASH' ? ($discovery->{root} // '') : '';
}

1;
