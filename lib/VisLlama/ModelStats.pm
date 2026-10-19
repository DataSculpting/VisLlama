package VisLlama::ModelStats;

# Record metric deltas per model configuration, separate from live hardware
# telemetry. Missing metrics must not be reported as measured zero throughput.
use strict;
use warnings;
use VisLlama::ProcessState ();
use Encode ();
use JSON::PP qw(encode_json decode_json);
use File::Spec;
use File::Basename qw(basename);

use POSIX qw(strftime);
use Time::HiRes qw(time);
use Digest::SHA qw(sha1_hex);
use VisLlama::Context qw($STATE);
use VisLlama::Util qw(jtrue);
use VisLlama::Catalog ();
use VisLlama::Paths ();
use VisLlama::Errors ();
use VisLlama::Lifecycle ();
use VisLlama::Performance ();
my %MODEL_STATS_PREVIOUS;
my $MODEL_STATS_LAST_SAMPLE = 0;
my $MODEL_STATS_CURSOR = 0;
my $ENGINE_CURSOR=0;
my $MODEL_STATS_WARNING = '';
my %METRICS_BUILD_SUPPORT;

# Attempt a periodic statistics sample synchronously in the control loop.
# Failures become a warning rather than a server exception. One engine is
# sampled per interval; lifecycle checkpoints serve status/stop between bounded
# HTTP calls. This remains serialized collection, not a background thread.
sub sample_if_due {
    if (time() - $MODEL_STATS_LAST_SAMPLE >= 15) {
        my $began=time();
        eval { sample_running_model_stats(0) };
        my $failed=$@;
        VisLlama::Performance::record('model_stats_sample',time()-$began);
        $@=$failed;
        $MODEL_STATS_WARNING = 'Model stats collection failed.' if $@;
    }
}

# Discard previous metric counters for this alias after its lifecycle changes,
# so a newly loaded instance is not compared against stale counters.
sub forget_model {
    my ($model) = @_;
    delete $MODEL_STATS_PREVIOUS{$_}
        for grep { (split /\x1e/)[1] eq $model } keys %MODEL_STATS_PREVIOUS;
}

# Probe and cache whether this executable advertises the metrics switch.
sub metrics_supported {
    my ($exe) = @_;
    my @stat=stat($exe);
    my $signature=join(':',map {defined($_)?$_:''} @stat[1,7,9,10]);
    $signature=VisLlama::Docker::resolve($exe)->{Id} if VisLlama::Docker::is_ref($exe);
    my $cached=$METRICS_BUILD_SUPPORT{$exe};
    return $cached->{supported} if $cached && $cached->{signature} eq $signature;
    # Failed probes are transient evidence, not a permanent capability result.
    my $help=eval {
        my $text=VisLlama::Util::capture_command($exe,'--help');
        die "Metrics capability probe failed: $?" if $?;
        $text;
    };
    if ($@) {VisLlama::Errors::report($@,'probe_error');return 0;}
    my $supported=($help// '') =~ /--metrics\b/ ? 1 : 0;
    $METRICS_BUILD_SUPPORT{$exe}={signature=>$signature,supported=>$supported};
    return $supported;
}

# Return the append-only statistics log location, creating logs/ if needed.
sub model_stats_path {
    my $dir = File::Spec->catdir(VisLlama::Paths::app_base_dir(), 'logs');
    mkdir $dir unless -d $dir;
    return File::Spec->catfile($dir, 'model-stats.jsonl');
}

# Hash only build, model path and effective options into the configuration ID.
# Presentation changes and timestamps do not split one configuration history.
sub model_config_id {
    my ($p) = @_;
    my $settings = { build=>$p->{build} // '', model=>$p->{model} // '', options=>$p->{options} || [] };
    return substr(sha1_hex(JSON::PP->new->utf8(1)->canonical(1)->encode($settings)), 0, 12);
}

# Parse the four supported cumulative llama.cpp counters. Require a complete
# set so partial metrics cannot produce misleading token rates.
sub metric_values {
    my ($raw) = @_;
    my %found;
    for my $line (split /\r?\n/, $raw // '') {
        next unless $line =~ /^llamacpp:(prompt_tokens_total|prompt_seconds_total|tokens_predicted_total|tokens_predicted_seconds_total)(?:\{[^}]*\})?\s+([0-9]+(?:\.[0-9]+)?(?:[eE][+-]?\d+)?)\s*$/;
        $found{$1} = 0 + $2;
    }
    return undef unless keys(%found) == 4;
    return \%found;
}

# Encode an alias as UTF-8 query bytes; do not apply filesystem quoting here.
sub url_encode_model {
    my ($s) = @_;
    my $bytes = Encode::encode('UTF-8', $s // '');
    $bytes =~ s/([^A-Za-z0-9._~-])/sprintf('%%%02X', ord($1))/ge;
    return $bytes;
}

# Convert cumulative counters into deltas keyed by instance, alias and config.
# A counter reset starts a new increment; write only intervals with token activity.
sub append_model_stats {
    my ($alias, $config, $build, $model, $instance, $metrics, $now) = @_;
    my $key = join("\x1e", $instance, $alias, $config);
    my $previous = $MODEL_STATS_PREVIOUS{$key} || {};
    my @names = qw(prompt_tokens_total tokens_predicted_total prompt_seconds_total tokens_predicted_seconds_total);
    my @delta = map { my $old = $previous->{$_} // 0; my $cur = $metrics->{$_}; $cur >= $old ? $cur-$old : $cur } @names;
    if ($delta[0] <= 0 && $delta[1] <= 0) {
        $MODEL_STATS_PREVIOUS{$key} = { %$metrics };
        return;
    }
    my $record = { schema=>1, at_ms=>int($now*1000), date=>strftime('%Y-%m-%d', localtime($now)),
                   alias=>$alias, config_id=>$config, build=>$build, model=>$model,
                   prompt_tokens=>int($delta[0]), decode_tokens=>int($delta[1]),
                   prompt_seconds=>$delta[2], decode_seconds=>$delta[3] };
    my $file = model_stats_path();
    open my $fh, '>>:raw', $file or die "Cannot write model stats log: $!";
    print {$fh} encode_json($record) . "\n" or die "Cannot append model stats: $!";
    close($fh) or die "Cannot finish model stats write: $!";
    # Commit the baseline only after the record is written. A later sample can
    # then recover cumulative tokens from a temporarily unwritable log.
    $MODEL_STATS_PREVIOUS{$key} = { %$metrics };
}

# Read loopback metrics with a short timeout and autoload disabled for aliases.
# Observing statistics must not itself trigger a model load.
sub fetch_metrics_text {
    my ($port, $alias) = @_;
    require HTTP::Tiny;
    my $ua = HTTP::Tiny->new(timeout => 1.5, no_proxy => ['127.0.0.1', 'localhost']);
    my $path = defined($alias) ? '?model=' . url_encode_model($alias) . '&autoload=false' : '';
    my $r = $ua->get('http://127.0.0.1:' . int($port) . '/metrics' . $path);
    return $r->{success} ? $r->{content} : undef;
}

# Sample loaded models only, rotating through a bounded set on normal polls.
# Forced samples may target one alias before unloading to retain its final totals.
sub sample_running_model_stats {
    my ($force, $target_alias) = @_;
    my $now = time();
    return if !$force && $now - $MODEL_STATS_LAST_SAMPLE < 15;
    $MODEL_STATS_LAST_SAMPLE = $now;
    $MODEL_STATS_WARNING = '';
    my (%present, %scanned);
    if (($STATE->{mode} // '') eq 'router' && VisLlama::ProcessState::router_any_running()) {
        my %presets = map { ($_->{alias} // '') => $_ } @{VisLlama::Catalog::load_router_presets()};
        my @targets;
        my @builds=sort keys %{$STATE->{router_engines}||{}};
        @builds=($builds[$ENGINE_CURSOR++ % @builds]) if !$force && @builds;
        my $expected=VisLlama::Lifecycle::token();
        for my $build (@builds) {
            VisLlama::Lifecycle::checkpoint($expected);
            my $eng = $STATE->{router_engines}{$build};
            next unless VisLlama::ProcessState::router_engine_running($eng);
            if (!$eng->{metrics_enabled}) {
                $MODEL_STATS_WARNING = "Build $eng->{build} does not advertise --metrics; no history can be collected for it.";
                next;
            }
            require HTTP::Tiny;
            my $ua = HTTP::Tiny->new(timeout => 1.5, no_proxy => ['127.0.0.1', 'localhost']);
            my $r = $ua->get('http://127.0.0.1:' . int($eng->{port}) . '/v1/models');
            if (!$r->{success}) {
                $MODEL_STATS_WARNING = "Could not inspect loaded models on $eng->{build}; collection will retry.";
                next;
            }
            my $json = eval { decode_json($r->{content}) };
            next unless ref($json) eq 'HASH' && ref($json->{data}) eq 'ARRAY';
            my $instance = join(':', $eng->{pid} // '', $eng->{port});
            $scanned{$instance} = 1;
            for my $m (@{$json->{data}}) {
                next unless ref($m) eq 'HASH' && ref($m->{status}) eq 'HASH' && ($m->{status}{value} // '') eq 'loaded';
                my $alias = $m->{id} // '';
                my $p = $presets{$alias};
                next unless $p && ($p->{build} // '') eq $eng->{build};
                my $cfg = model_config_id($p);
                my $key = join("\x1e", $instance, $alias, $cfg);
                $present{$key} = 1;
                push @targets, {eng=>$eng,alias=>$alias,preset=>$p,config=>$cfg,instance=>$instance};
            }
        }
        if (@targets) {
            my $limit = $force ? scalar(@targets) : (@targets < 3 ? scalar(@targets) : 3);
            my $offset = $force ? 0 : $MODEL_STATS_CURSOR % @targets;
            my @selected = $force && defined($target_alias)
                ? grep { $_->{alias} eq $target_alias } @targets
                : map { $targets[($offset+$_) % @targets] } (0..$limit-1);
            $MODEL_STATS_CURSOR += scalar(@selected) unless $force;
            for my $item (@selected) {
                VisLlama::Lifecycle::checkpoint($expected);
                my ($eng,$alias,$p,$cfg,$instance) = @{$item}{qw(eng alias preset config instance)};
                my $values = metric_values(fetch_metrics_text($eng->{port}, $alias));
                if (!$values) { $MODEL_STATS_WARNING = "Metrics for $alias are unavailable; confirm this llama.cpp build supports --metrics."; next; }
                eval { append_model_stats($alias, $cfg, $eng->{build}, $p->{model}, $instance, $values, time()) };
                $MODEL_STATS_WARNING = 'Could not write the model stats log.' if $@;
            }
        }
    } elsif (($STATE->{mode} // '') eq 'single' && VisLlama::ProcessState::proc_running() && $STATE->{direct_metrics}) {
        my $alias = $STATE->{direct_alias} || basename($STATE->{model} || 'Direct model');
        my $cfg = $STATE->{direct_config_id} || '';
        my $instance = join(':', $STATE->{pid} // '', $STATE->{direct_port} // '');
        my $key = join("\x1e", $instance, $alias, $cfg);
        $present{$key} = 1;
        my $values = metric_values(fetch_metrics_text($STATE->{direct_port}, undef));
        eval { append_model_stats($alias, $cfg, $STATE->{build}, $STATE->{model}, $instance, $values, time()) } if $values;
        $MODEL_STATS_WARNING = 'Could not write the model stats log.' if $@;
    } elsif (($STATE->{mode} // '') eq 'single' && VisLlama::ProcessState::proc_running()) {
        $MODEL_STATS_WARNING = 'The direct-server build does not advertise --metrics; history is unavailable for this session.';
    }
    for my $key (keys %MODEL_STATS_PREVIOUS) {
        my ($instance) = split /\x1e/, $key;
        delete $MODEL_STATS_PREVIOUS{$key} if $scanned{$instance} && !$present{$key};
    }
}

# Aggregate valid JSONL records by alias, configuration and day. Return totals
# and the latest records alongside the current catalog for historical UI filters.
sub model_stats_payload {
    my $file = model_stats_path();
    my %days;
    my %latest;
    if (-f $file && open(my $fh, '<:raw', $file)) {
        while (my $line = <$fh>) {
            my $r = eval { decode_json($line) };
            next unless ref($r) eq 'HASH' && ($r->{schema} // 0) == 1;
            my $key = join("\x1e", map { $r->{$_} // '' } qw(alias config_id date));
            my $d = $days{$key} ||= { alias=>$r->{alias}, config_id=>$r->{config_id},
                                       date=>$r->{date}, build=>$r->{build}, model=>$r->{model},
                                       at_ms=>$r->{at_ms}, prompt_tokens=>0, decode_tokens=>0,
                                       prompt_seconds=>0, decode_seconds=>0 };
            $d->{$_} += $r->{$_} || 0 for qw(prompt_tokens decode_tokens prompt_seconds decode_seconds);
            $d->{at_ms} = $r->{at_ms} if $r->{at_ms} > $d->{at_ms};
            my $cfgkey = join("\x1e", $r->{alias}, $r->{config_id});
            $latest{$cfgkey} = $r if !$latest{$cfgkey} || $r->{at_ms} > $latest{$cfgkey}{at_ms};
        }
        close $fh;
    }
    my @presets = map { { alias=>$_->{alias}, build=>$_->{build}, model=>$_->{model},
                          config_id=>model_config_id($_) } } @{VisLlama::Catalog::load_router_presets()};
    return { ok=>jtrue, path=>$file, presets=>\@presets,
             days=>[sort { $a->{date} cmp $b->{date} } values %days],
             latest=>[values %latest], warning=>VisLlama::Errors::public_text($MODEL_STATS_WARNING,'diagnostic') };
}

1;
