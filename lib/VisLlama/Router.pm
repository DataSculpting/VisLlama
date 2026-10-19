package VisLlama::Router;

# Coordinate internal build/GPU-visibility groups behind the public Router endpoint.
# Calculated loads must finish before planning the next model against free VRAM.
use strict;
use VisLlama::Engines ();
use warnings;
use VisLlama::ProcessState ();

use JSON::PP qw(encode_json decode_json);

use Time::HiRes qw(time);

use VisLlama::Context qw(%CFG $STATE);
use VisLlama::Util qw(jtrue jfalse);
use VisLlama::Catalog ();
use VisLlama::GPUIsolation ();
use VisLlama::Config ();
use VisLlama::Errors ();
use VisLlama::Preflight ();
use VisLlama::Lifecycle ();

# -----------------------------------------------------------------------------
# Resolve a model alias to the currently running internal build engine.
# -----------------------------------------------------------------------------
sub router_engine_for_model {
    my ($model) = @_;
    for my $build (keys %{$STATE->{router_engines} || {}}) {
        my $eng = $STATE->{router_engines}{$build};
        for my $m (@{$eng->{models} || []}) {
            return $eng if $m eq $model;
        }
    }
    return undef;
}

# -----------------------------------------------------------------------------
# Perform an HTTP request against one internal llama.cpp router engine.
# -----------------------------------------------------------------------------
sub router_http_engine {
    my ($eng, $method, $path, $body) = @_;
    return VisLlama::Engines::dispatch($eng,$method,$path,$body) if $eng && $eng->{engine};
    die "Router engine is unavailable" unless $eng && $eng->{port};
    require HTTP::Tiny;
    my $ua = HTTP::Tiny->new(timeout => $method eq 'GET'?2:8, no_proxy => ['127.0.0.1', 'localhost']);
    my %opt;
    if (defined $body) {
        $opt{headers} = {'content-type' => 'application/json'};
        $opt{content} = encode_json($body);
    }
    my $url = "http://127.0.0.1:" . int($eng->{port}) . $path;
    my $r = $ua->request($method, $url, \%opt);
    $eng->{ready_checked_at}=time();$eng->{ready}=$r->{success}?1:0;
    die "Router API $method $path failed on $eng->{build}: $r->{status} $r->{reason} $r->{content}" unless $r->{success};
    return {} unless defined $r->{content} && length $r->{content};
    my $j = eval { decode_json($r->{content}) };
    if ($@) {$eng->{ready}=0;die "Router API returned invalid JSON from $eng->{build}: $@";}
    if (ref($j) eq 'HASH' && $j->{error}) {$eng->{ready}=0;die "Router returned an error envelope: " . encode_json($j->{error});}
    return $j;
}

# -----------------------------------------------------------------------------
# Merge model status returned by all internal build engines.
# -----------------------------------------------------------------------------
sub router_models_merged {
    my @data;my $incomplete=0;
    for my $build (sort keys %{$STATE->{router_engines} || {}}) {
        my $eng = $STATE->{router_engines}{$build};
        unless ($eng->{engine} || VisLlama::ProcessState::router_engine_running($eng)) {$incomplete=1;next;}
        my $j = eval { router_http_engine($eng, 'GET', '/v1/models', undef) };
        if ($@ || ref($j) ne 'HASH' || ref($j->{data}) ne 'ARRAY') {$incomplete=1;$eng->{ready}=0;next;}
        for my $m (@{$j->{data}}) {
            next unless ref($m) eq 'HASH';
            # Project the fields used by VisLlama instead of forwarding arbitrary
            # upstream debug/error objects inside an otherwise successful reply.
            next unless defined($m->{id}) && grep { $_ eq $m->{id} } @{$eng->{models} || []};
            my $status=ref($m->{status}) eq 'HASH' ? $m->{status} : {};
            my $value=$status->{value}//'unknown';
            $value='unknown' unless $value =~ /^(?:loaded|loading|unloaded|unloading|sleeping|failed|error|unknown)$/;
            my @args;
            my $argv=ref($status->{args}) eq 'ARRAY' ? $status->{args} : [];
            # These three non-secret fields are needed by reload verification.
            for (my $i=0;$i<@$argv;$i++) {
                my $v=$argv->[$i]//'';
                if ($v =~ /^(--ctx-size|-c|--parallel|-np|--load-mode|-lm)(?:=(.*))?$/) {
                    my ($flag,$arg)=($1,defined($2)?$2:$argv->[++$i]);
                    push @args,$flag,$arg if defined($arg) && $arg =~ /^(?:-?\d+|auto|none|mmap|mlock|mmap\+mlock|dio)$/;
                }
            }
            my %copy=(id=>$m->{id},object=>'model',visllama_build=>$eng->{build},
                status=>{value=>$value,args=>\@args,failed=>$status->{failed}?jtrue:jfalse});
            $copy{status}{error}=VisLlama::Errors::public_text($status->{error},'process_error') if $status->{error};
            for my $startup (@{$STATE->{startup_models}||[]}) {
                if (($startup->{alias}//'') eq $m->{id} && $value eq 'loaded') {$startup->{state}='loaded';delete $startup->{error};}
            }
            push @data, \%copy;
        }
    }
    return { object=>'list', data=>\@data, incomplete=>$incomplete?jtrue:jfalse };
}

# A calculated layer split must be planned against the VRAM available at the
# moment the model is loaded. The control server processes requests in order,
# and this routine waits for each child to finish loading before the next
# calculated model can measure free VRAM. Other modes retain llama.cpp loading.
sub router_model_status {
    my ($eng,$alias) = @_;
    my $data;
    my $expected=VisLlama::Lifecycle::token();
    my $deadline = time() + 20;
    while (1) {
        VisLlama::Lifecycle::checkpoint($expected);
        $data = eval { router_http_engine($eng,'GET','/v1/models',undef) };
        last unless $@;
        die $@ if time() >= $deadline;
        select(undef,undef,undef,0.25);
    }
    for my $row (@{$data->{data} || []}) {
        next unless ref($row) eq 'HASH' && ($row->{id}//'') eq $alias;
        return ref($row->{status}) eq 'HASH' ? ($row->{status}{value}//'') : '';
    }
    return '';
}

# Poll the engine until the requested model is loaded, fails or times out.
# This completion barrier prevents the next calculated load using premature VRAM.
sub wait_router_model_loaded {
    my ($eng,$alias,$seconds) = @_;
    my $deadline = time() + $seconds;
    my $expected=VisLlama::Lifecycle::token();
    my $saw_loading = 0;
    while (time() < $deadline) {
        VisLlama::Lifecycle::checkpoint($expected);
        my $status = router_model_status($eng,$alias);
        return 1 if $status eq 'loaded';
        $saw_loading = 1 if $status eq 'loading';
        die "Model '$alias' failed to load on $eng->{build}; check Logs / Diagnostics"
            if $status =~ /^(?:error|failed)$/ || ($saw_loading && $status eq 'unloaded');
        select(undef,undef,undef,0.35);
    }
    die "Timed out waiting for '$alias' to load on $eng->{build}; check Logs / Diagnostics";
}

# Use the serialized control path for calculated placement: measure, regenerate
# the build INI, request loading and wait for completion. Other modes retain
# the native Router load path and llama.cpp fitting behavior.
sub load_router_model_centrally {
    my ($alias,$eng) = @_;
    return VisLlama::Engines::load($alias,$eng) if $eng->{engine};
    my $items = VisLlama::Catalog::load_router_presets();
    my ($preset) = grep { ($_->{alias}//'') eq $alias && ($_->{build}//'') eq $eng->{build} && $_->{enabled} } @$items;
    die "Enabled model '$alias' is not configured on $eng->{build}" unless $preset;
    if ($eng->{proc} && $eng->{proc}->isa('VisLlama::Docker::Process')) {
        my @files=($preset->{model});
        push @files,map {$_->[1]} grep {$_->[0] =~ /\A(?:chat-template-file|spec-draft-model|model-draft|mmproj|lora)\z/} @{$preset->{options}||[]};
        VisLlama::Docker::check_live($eng->{proc},$CFG{builds}{$preset->{build}},\@files);
    }
    die 'GPU selection changed. Apply configuration or restart Router before loading this model.'
        if $eng->{group_key} && VisLlama::Engines::group_key($preset) ne $eng->{group_key};
    my $status = router_model_status($eng,$alias);
    return { already_loaded=>1 } if $status eq 'loaded';
    if ($status eq 'loading') {
        wait_router_model_loaded($eng,$alias,300);
        return { already_loaded=>1 };
    }
    my $plan;
    if (($preset->{ui}{gpuPriority}//'') eq 'priority_split') {
        my $all = VisLlama::Catalog::write_router_ini_for_build($items,$eng->{build},$eng->{preset_file},$alias,$eng);
        $plan = $all->{$alias};
    } else {
        # Ordinary loads must also use the saved catalog, not an old group INI.
        # Existing resident children retain their settings; only this unloaded
        # model is started. A changed visibility group requires explicit apply.
        VisLlama::Catalog::write_router_ini_for_build($items,$eng->{build},$eng->{preset_file},undef,$eng);
    }
    # A failed publication or native catalog reload must stop before spawning.
    router_http_engine($eng,'GET','/v1/models?reload=1',undef);
    router_http_engine($eng,'POST','/models/load',{model=>$alias});
    wait_router_model_loaded($eng,$alias,300) if $plan;
    return { gpu_priority_plan=>$plan };
}

# -----------------------------------------------------------------------------
# Return the public Router API base URL.
# -----------------------------------------------------------------------------
sub router_api_base {
    my $port = int($STATE->{router_internal_port} || $STATE->{router_port} || 8080);
    return "http://127.0.0.1:$port";
}

# -----------------------------------------------------------------------------
# HTTP helper for requests sent to the internal llama.cpp Router engines.
# -----------------------------------------------------------------------------
sub router_http {
    my ($method, $path, $body) = @_;
    require HTTP::Tiny;
    my $ua = HTTP::Tiny->new(timeout => 8, no_proxy => ['127.0.0.1', 'localhost']);
    my %opt;
    if (defined $body) {
        $opt{headers} = {'content-type' => 'application/json'};
        $opt{content} = encode_json($body);
    }
    my $url = router_api_base() . $path;
    my $r = $ua->request($method, $url, \%opt);
    die "Router API $method $path failed: $r->{status} $r->{reason} $r->{content}" unless $r->{success};
    return {} unless defined $r->{content} && length $r->{content};
    my $j = eval { decode_json($r->{content}) };
    die "Router API returned invalid JSON: $@" if $@;
    die "Router returned an error envelope: " . encode_json($j->{error}) if ref($j) eq 'HASH' && $j->{error};
    return $j;
}

# -----------------------------------------------------------------------------
# Tell running internal routers to reread their generated model catalogs.
# -----------------------------------------------------------------------------
sub reload_router_catalogs {
    return unless ($STATE->{mode}//'') eq 'router';
    for my $eng (values %{$STATE->{router_engines} || {}}) {
        next unless VisLlama::ProcessState::router_engine_running($eng);
        eval { router_http_engine($eng, 'GET', '/v1/models?reload=1', undef) };
    }
}

# -----------------------------------------------------------------------------
# Apply saved preset/build changes to running engines when possible; request restart only when necessary.
# -----------------------------------------------------------------------------
sub apply_router_config_live {
    my ($force_unload_moved) = @_;
    return { applied=>jfalse, restart_required=>jfalse, reason=>'Router is not running' }
        unless VisLlama::ProcessState::proc_running() && ($STATE->{mode}//'') eq 'router';

    my $items = VisLlama::Catalog::load_router_presets();
    my %desired_by_alias;
    my %desired_by_build;
    for my $p (@$items) {
        next unless ref($p) eq 'HASH' && $p->{enabled};
        my $alias = $p->{alias} // '';
        my $build = $p->{build} // '';
        next unless length($alias) && length($build);
        my $key=VisLlama::Engines::group_key($p);
        if (VisLlama::Engines::external($p) && $STATE->{router_engines}{$key}
            && ($STATE->{router_engines}{$key}{build}//'') ne $build) {
            return {applied=>jfalse,restart_required=>jtrue,reason=>'Restart Router to activate the changed engine build.'};
        }
        $desired_by_alias{$alias} = $key;
        push @{$desired_by_build{$key}}, $alias;
    }

    my %current_builds = map { $_=>1 } keys %{$STATE->{router_engines} || {}};
    my @missing = sort grep { !$current_builds{$_} } keys %desired_by_build;
    if (@missing) {
        return { applied=>jfalse, restart_required=>jtrue,
                 reason=>'Restart Router to apply the new build or GPU visibility groups.' };
    }

    VisLlama::Preflight::saved($_,1) for grep {$_->{enabled}} @$items;

    my %old_owner;
    for my $build (keys %{$STATE->{router_engines} || {}}) {
        my $eng = $STATE->{router_engines}{$build};
        for my $alias (@{$eng->{models} || []}) { $old_owner{$alias} = $build; }
    }

    my @moved = grep { !exists($desired_by_alias{$_}) || $desired_by_alias{$_} ne $old_owner{$_} } keys %old_owner;
    my @blocked;
    for my $alias (@moved) {
        my $old_build = $old_owner{$alias};
        my $eng = $STATE->{router_engines}{$old_build};
        next unless $eng && VisLlama::ProcessState::router_engine_running($eng);
        my $models = eval { router_http_engine($eng,'GET','/v1/models',undef) };
        if ($@ || ref($models) ne 'HASH' || ref($models->{data}) ne 'ARRAY') {push @blocked,'Could not establish the moved model state.';next;}
        my ($row) = grep { ref($_) eq 'HASH' && (($_->{id}//'') eq $alias) } @{$models->{data}};
        next unless $row;
        my $status = ref($row->{status}) eq 'HASH' ? ($row->{status}{value}//'') : '';
        next unless $status eq 'loaded' || $status eq 'loading';
        if ($force_unload_moved) {
            my $ok = eval { router_http_engine($eng,'POST','/models/unload',{model=>$alias});
                my $until=time()+30;my $expected=VisLlama::Lifecycle::token();
                while (1) {
                    VisLlama::Lifecycle::checkpoint($expected);
                    my $state=router_model_status($eng,$alias);
                    last if $state eq 'unloaded';
                    die 'Timed out confirming moved model unload' if time()>=$until;
                    select(undef,undef,undef,0.15);
                }
                1 };
            push @blocked, VisLlama::Errors::public_text($@,'reload_error') unless $ok;
        } else {
            push @blocked, 'A moved or removed model is still loaded.';
        }
    }
    if (@blocked) {
        return { applied=>jfalse, restart_required=>jfalse, blocked=>jtrue,
                 reason=>'Unload moved/removed models first, or use Save and reload: '.join('; ',@blocked) };
    }

    # Every currently running engine keeps its preset file, even if it now has
    # zero models.  This lets llama.cpp reload the catalog without restarting.
    $STATE->{catalog_apply_incomplete}=1;
    VisLlama::Catalog::publish_engine_inis($items,[values %{$STATE->{router_engines}||{}}]);

    for my $build (keys %{$STATE->{router_engines} || {}}) {
        my $eng = $STATE->{router_engines}{$build};
        next if $eng->{engine};
        next unless $eng && VisLlama::ProcessState::router_engine_running($eng);
        my $ok = eval { router_http_engine($eng,'GET','/v1/models?reload=1',undef); 1 };
        if (!$ok) {
            return { applied=>jfalse, restart_required=>jtrue,
                     reason=>VisLlama::Errors::public_text($@,'reload_error') };
        }
        $eng->{models} = [ sort @{$desired_by_build{$build} || []} ];
    }

    my %route_map;
    for my $alias (sort keys %desired_by_alias) {
        my $build = $desired_by_alias{$alias};
        my $eng = $STATE->{router_engines}{$build};
        next unless $eng && $eng->{port};
        my ($preset) = grep { ($_->{alias}//'') eq $alias } @$items;
        $route_map{$alias} = { host=>'127.0.0.1', port=>int($eng->{port}), build=>$eng->{build},
            calculated=>(($preset->{ui}{gpuPriority}//'') eq 'priority_split' ? 1 : 0),
            ($eng->{engine}?(managed=>1,engine=>$eng->{engine}):()) };
    }
    my @backends = map {
        my $build=$_; my $eng=$STATE->{router_engines}{$build};
        { build=>$eng->{build}, host=>'127.0.0.1', port=>int($eng->{port}) }
    } sort grep { @{$desired_by_build{$_} || []} } keys %{$STATE->{router_engines} || {}};
    VisLlama::Config::write_json_file_ascii($STATE->{router_route_map},{models=>\%route_map,backends=>\@backends,
        control=>{host=>'127.0.0.1',port=>$CFG{listen_port},token=>$STATE->{router_control_token}}}) if $STATE->{router_route_map};
    delete $STATE->{catalog_apply_incomplete};
    return { applied=>jtrue, restart_required=>jfalse, moved=>\@moved };
}

1;
