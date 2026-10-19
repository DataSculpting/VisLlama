package VisLlama::Catalog;

# Own the ordered preset catalog and generated per-build Router INIs.
# JSON is the durable source; INIs are derived artifacts regenerated for engines.
use strict;
use VisLlama::Engines ();
use warnings;

use JSON::PP qw(decode_json);
use File::Spec;

use VisLlama::Context qw($STATE);

use VisLlama::GPUPlanner ();
use VisLlama::GPUIsolation ();
use VisLlama::Arguments ();
use VisLlama::PlannerSettings ();
use VisLlama::Paths ();
use VisLlama::Config ();
use VisLlama::Storage ();
use Encode qw(encode);
use Storable qw(dclone);

# -----------------------------------------------------------------------------
# Return paths used for Router presets and runtime cache.
# -----------------------------------------------------------------------------
sub router_paths {
    my $dir = VisLlama::Paths::presets_dir();
    my $cache = File::Spec->catdir($dir, 'router-empty-cache');
    mkdir $cache unless -d $cache;
    return (
        File::Spec->rel2abs(File::Spec->catfile($dir, 'router-presets.json')),
        undef, # Retained positional slot for existing router_paths callers.
        File::Spec->rel2abs($cache),
    );
}

# -----------------------------------------------------------------------------
# Load the durable per-model Router preset catalog.
# -----------------------------------------------------------------------------
sub load_router_presets {
    my ($json_file) = router_paths();
    my $x=VisLlama::Config::read_json_file($json_file,[]);
    die 'Invalid saved model catalog' unless ref($x) eq 'ARRAY';
    # The top-level build is authoritative for Router engine assignment.
    # Keep the editable UI snapshot synchronized so older/cloned presets cannot
    # display a different build from the one the Router will actually launch.
    for my $p (@$x) {
        next unless ref($p) eq 'HASH';
        $p->{ui} = {} unless ref($p->{ui}) eq 'HASH';
        if (!length($p->{build} // '') && length($p->{ui}{build} // '')) {
            $p->{build} = $p->{ui}{build};
        }
        $p->{ui}{build} = $p->{build} if length($p->{build} // '');
        $p->{ui}{model} = $p->{model} if length($p->{model} // '');
        $p->{ui}{alias} = $p->{alias} if length($p->{alias} // '');
    }
    return $x;
}

# -----------------------------------------------------------------------------
# Persist the Router preset catalog.
# -----------------------------------------------------------------------------
sub save_router_presets {
    my ($items,$extra_entries) = @_;
    # Validate before touching derived INIs or the durable catalog. An option
    # name containing a space makes llama.cpp reject the entire build's INI.
    validate_preset_options($_->{options} || []) for grep { ref($_) eq 'HASH' } @$items;
    my ($json_file) = router_paths();
    sync_router_build_inis($items,[$json_file,JSON::PP->new->ascii->pretty->canonical->encode($items)],$extra_entries);
    my %active = map { (($_->{build}//'') . "\x1e" . ($_->{alias}//'')) => 1 }
                 grep { ref($_) eq 'HASH' && $_->{enabled} && ($_->{ui}{gpuPriority}//'') =~ /^(?:priority|priority_split)$/ } @$items;
    for my $build (keys %{$STATE->{priority_plans} || {}}) {
        for my $alias (keys %{$STATE->{priority_plans}{$build}}) {
            delete $STATE->{priority_plans}{$build}{$alias} unless $active{$build . "\x1e" . $alias};
        }
    }

}

# Keep load priority as catalog order. Existing catalogs keep their current
# order without a schema migration; the UI explicitly saves reordering.
sub reorder_router_presets {
    my ($items,$aliases) = @_;
    die 'Provide the complete ordered model list' unless ref($aliases) eq 'ARRAY' && @$aliases == @$items;
    my %by_alias;
    for my $p (@$items) {
        die 'Model catalog contains an invalid or duplicate alias' unless ref($p) eq 'HASH'
            && defined($p->{alias}) && length($p->{alias}) && !$by_alias{$p->{alias}};
        $by_alias{$p->{alias}} = $p;
    }
    my %seen;
    my @ordered;
    for my $alias (@$aliases) {
        die 'Unknown or repeated model in load order' unless defined($alias) && !ref($alias)
            && exists($by_alias{$alias}) && !$seen{$alias}++;
        push @ordered,$by_alias{$alias};
    }
    return \@ordered;
}

# -----------------------------------------------------------------------------
# Escape one value for generated llama.cpp router preset INI syntax.
# -----------------------------------------------------------------------------
sub ini_value {
    my ($v) = @_;
    $v //= '';
    $v =~ s/[\r\n]+/ /g;
    return $v;
}

# -----------------------------------------------------------------------------
# Convert a flat llama-server argument list into router preset INI options.
# -----------------------------------------------------------------------------
sub args_to_preset_options {
    my ($args) = @_;
    $args = VisLlama::Arguments::normalize($args);
    my %skip = map { $_ => 1 } qw(--host --port --threads-http --models-dir --models-preset --models-max --models-autoload --no-models-autoload --alias --model -m);
    my %boolean = map { $_ => 1 } qw(--fit --no-fit --cpu-moe --no-kv-offload --swa-full --no-warmup --mlock --mmap --no-mmap --no-host --no-repack --repack --cont-batching --no-cont-batching);
    my @out;
    for (my $i=0; $i < @$args; $i++) {
        my $flag = $args->[$i];
        die 'Invalid extra arguments. Use one --option value per line and review the command preview.'
            unless defined($flag) && !ref($flag) && ($flag eq '-m' || $flag =~ /^--[A-Za-z_][A-Za-z0-9_.-]*(?:=[^\r\n\x00]*)?$/);
        my $inline;
        ($flag,$inline) = split(/=/,$flag,2) if index($flag,'=') >= 0;
        if ($skip{$flag}) {
            if (!defined($inline) && $flag !~ /^(?:--models-autoload|--no-models-autoload)$/ && $i+1 < @$args && defined($args->[$i+1]) && !ref($args->[$i+1]) && $args->[$i+1] !~ /^--/) { $i++; }
            next;
        }
        my $key = $flag; $key =~ s/^--//;
        my $value = defined($inline) ? $inline : 'true';
        if (!defined($inline) && $i+1 < @$args && defined($args->[$i+1]) && !ref($args->[$i+1]) && $args->[$i+1] !~ /^--/
            && (!$boolean{$flag} || $args->[$i+1] =~ /^(?:on|off|true|false)$/)) {
            $value = $args->[$i + 1]; $i++;
        }
        push @out, [$key, "$value"];
    }
    validate_preset_options(\@out);
    return \@out;
}

# llama.cpp's INI identifiers cannot contain spaces, '=' or section delimiters.
# Keep this boundary even for catalog entries saved by an older application.
sub validate_preset_options {
    my ($options) = @_;
    die 'Invalid saved model options. Open the model editor and correct its extra arguments.' unless ref($options) eq 'ARRAY';
    for my $pair (@$options) {
        die 'Invalid saved model options. Open the model editor and correct its extra arguments.'
            unless ref($pair) eq 'ARRAY' && @$pair == 2 && defined($pair->[0]) && !ref($pair->[0])
                && $pair->[0] =~ /\A[A-Za-z_][A-Za-z0-9_.-]*\z/
                && defined($pair->[1]) && !ref($pair->[1]) && $pair->[1] !~ /\x00/;
    }
}

# -----------------------------------------------------------------------------
# Create a filesystem-safe slug from a human-readable build alias.
# -----------------------------------------------------------------------------
sub safe_build_slug {
    my ($name) = @_;
    $name //= 'build';
    $name =~ s/[^A-Za-z0-9._-]+/_/g;
    $name =~ s/^_+|_+$//g;
    return length($name) ? $name : 'build';
}

# -----------------------------------------------------------------------------
# Generate the models-preset INI for one llama.cpp build group.
# -----------------------------------------------------------------------------
# Write to the supplied path. sync_router_build_inis supplies a staging path,
# but live apply and calculated loads supply the running engine's INI directly.
# Validation/planning precede atomic whole-file publication.
sub write_router_ini_for_build {
    my ($items, $build, $path, $refresh_alias, $engine) = @_;
    if ($engine && $engine->{group_key}) {
        $items=[grep { VisLlama::GPUIsolation::group_key($_) eq $engine->{group_key} } @$items];
    }
    validate_preset_options($_->{options} || [])
        for grep { ref($_) eq 'HASH' && $_->{enabled} && ($_->{build}//'') eq $build } @$items;
    my %priority_plans;
    for my $p (@$items) {
        next unless ref($p) eq 'HASH' && $p->{enabled} && ($p->{build}//'') eq $build;
        next unless ($p->{ui}{gpuPriority}//'') =~ /^(?:priority|priority_split)$/;
        # Calculated splits are refreshed by the central loader immediately
        # before loading. Do not precompute them while starting a router.
        next if ($p->{ui}{gpuPriority}//'') eq 'priority_split'
            && (!defined($refresh_alias) || $refresh_alias ne $p->{alias});
        my $cached = $STATE->{priority_plans}{$build}{$p->{alias}};
        my $same = $cached && ($cached->{mode}//'') eq ($p->{ui}{gpuPriority}//'')
            && ($cached->{model}//'') eq ($p->{model}//'')
            && ($cached->{reserve_mib}//'') eq ($p->{ui}{gpuReserve}//2048)
            && join(',',@{$cached->{requested_devices}||[]}) eq join(',',@{$p->{ui}{devices}||[]});
        $priority_plans{$p->{alias}} = $same && (!defined($refresh_alias) || $refresh_alias ne $p->{alias})
            ? $cached : VisLlama::GPUPlanner::gpu_plan_for_mode($build,$p->{model},$p->{ui}{devices},$p->{ui}{gpuReserve},$p->{ui}{gpuPriority},$p->{ui},VisLlama::PlannerSettings::option_args($p->{options}));
    }
    my $text='';
    open my $fh, '>', \$text or die "Cannot stage INI: $!";
    print $fh "version = 1\n\n";
    for my $p (@$items) {
        next unless ref($p) eq 'HASH' && $p->{enabled};
        next unless ($p->{build} // '') eq $build;
        next if VisLlama::Engines::external($p);
        my $name = $p->{alias} // '';
        next unless length $name;
        print $fh "[$name]\n";
        print $fh "model = " . ini_value($p->{model}) . "\n";
        # The controller starts every startup preset in catalog order and
        # waits for it to load before moving to the next one.
        my $managed = ($p->{ui}{gpuPriority}//'') eq 'priority_split';
        print $fh "load-on-startup = false\n";
        print $fh "stop-timeout = " . int($p->{stop_timeout} || 10) . "\n";
        my @options = @{$p->{options} || []};
        if ($managed || $priority_plans{$name}) {
            @options = grep { ref($_) eq 'ARRAY' && $_->[0] !~ /^(?:device|tensor-split|split-mode|main-gpu|fit|no-fit|fit-target|gpu-layers)$/ } @options;
            if (my $plan = $priority_plans{$name}) {
                for (my $i=0; $i < @{$plan->{args}}; $i+=2) {
                    push @options, [ substr($plan->{args}[$i],2), $plan->{args}[$i+1] ];
                }
            }
        }
        @options = @{VisLlama::GPUIsolation::remap_options(\@options,$engine->{isolation})} if $engine && $engine->{isolation};
        for my $kv (@options) {
            next unless ref($kv) eq 'ARRAY' && @$kv >= 2;
            print $fh ini_value($kv->[0]) . " = " . ini_value($kv->[1]) . "\n";
        }
        print $fh "\n";
    }
    close($fh) or die "Cannot close INI buffer: $!";
    VisLlama::Storage::write($path,encode('UTF-8',$text));
    $STATE->{priority_plans}{$build} = $engine && $engine->{group_key}
        ? { %{$STATE->{priority_plans}{$build}||{}}, %priority_plans } : \%priority_plans;
    return \%priority_plans;
}

# -----------------------------------------------------------------------------
# Regenerate all per-build INIs and remove obsolete generated INIs.
# -----------------------------------------------------------------------------
sub sync_router_build_inis {
    my ($items,$catalog_entry,$extra_entries) = @_;
    $items = [] unless ref($items) eq 'ARRAY';
    my $dir = VisLlama::Paths::presets_dir();

    my %builds;
    for my $p (@$items) {
        next unless ref($p) eq 'HASH' && $p->{enabled};
        next if VisLlama::Engines::external($p);
        my $build = $p->{build} // '';
        next unless length $build;
        $builds{$build} = 1;
    }

    # Calculate every new INI before replacing any existing one. A failed
    # VRAM estimate must not delete a working Router catalog.
    my %pending;
    my $previous=dclone($STATE->{priority_plans}||{});
    my $ok = eval {
        for my $build (sort keys %builds) {
            my $slug = safe_build_slug($build);
            my $path = File::Spec->rel2abs(File::Spec->catfile($dir, "router-models-$slug.ini"));
            my $temp = "$path.pending-$$";
            die 'Build aliases collide in generated INI filenames' if exists $pending{$path};
            $pending{$path} = $temp;
            write_router_ini_for_build($items, $build, $temp);
        }
        1;
    };
    if (!$ok) {
        my $error = $@;
        $STATE->{priority_plans}=$previous;
        unlink $_ for values %pending;
        die $error;
    }
    my @entries=map {[$_,VisLlama::Storage::raw_read($pending{$_})]} sort keys %pending;
    if (opendir(my $dh, $dir)) {
        while (my $name=readdir($dh)) {
            next unless $name =~ /^router-models-.+\.ini$/i;
            my $path=File::Spec->rel2abs(File::Spec->catfile($dir,$name));
            push @entries,[$path,undef] if -f $path && !exists $pending{$path};
        }
        closedir $dh;
    }
    push @entries,@{$extra_entries||[]};
    push @entries,$catalog_entry if $catalog_entry;
    my $published=eval {VisLlama::Storage::transaction(\@entries);1};my $error=$@;
    unlink $_ for values %pending;
    if (!$published) {$STATE->{priority_plans}=$previous;die $error;}
}

# Stage all live group catalogs before publishing any of them. Native engine
# reload calls follow this commit; their outcomes are separately reported.
sub publish_engine_inis {
    my ($items,$engines)=@_;
    my @entries;my @temporary;my $previous=dclone($STATE->{priority_plans}||{});
    my $ok=eval {
        for my $eng (@$engines) {
            next if $eng->{engine};
            my $temp=$eng->{preset_file}.".pending-$$";push @temporary,$temp;
            write_router_ini_for_build($items,$eng->{build},$temp,undef,$eng);
            push @entries,[$eng->{preset_file},VisLlama::Storage::raw_read($temp)];
        }
        VisLlama::Storage::transaction(\@entries);1;
    };my $error=$@;unlink $_ for @temporary;
    if (!$ok) {$STATE->{priority_plans}=$previous;die $error;}
}
1;
