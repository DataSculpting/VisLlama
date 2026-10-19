package VisLlama::GPUPlanner;

# Plan explicit priority placement from current free VRAM and GGUF metadata.
# Estimates are allowances, not guaranteed allocation caps. Metadata alone is cached;
# live VRAM must be sampled again when a calculated model actually loads.
use strict;
use warnings;

use File::Spec;
use File::Basename qw(dirname basename);

use Time::HiRes qw(time);

use VisLlama::Context qw(%CFG);
use VisLlama::Util ();
use VisLlama::Builds ();
use VisLlama::LayerPlanner ();
use VisLlama::MemoryLayout ();
use VisLlama::PlannerSettings ();
# Entries are invalidated when the source file size or modification time changes.
my %GGUF_META_CACHE;

# Let llama.cpp fit the complete model and context to the requested VRAM
# margin. Its fitter fills devices from last to first, so reverse the UI's
# preferred-first order in --device. An explicit tensor split prevents the
# fitter from changing the layer allocation when memory is tight.
sub gpu_priority_plan {
    my ($build, $model, $selected, $reserve_mib, $skip_fit_check) = @_;
    die "Priority order requires a configured llama.cpp build" unless exists $CFG{builds}{$build};
    die "Priority order requires a GGUF model file" unless defined($model) && -f $model;
    die "Select at least one CUDA device for priority order" unless ref($selected) eq 'ARRAY' && @$selected;
    die "Priority order supports CUDA devices only" if grep { !defined($_) || $_ !~ /^CUDA\d+$/ } @$selected;
    die "Priority order contains a duplicate device" if @$selected != keys %{ { map { $_=>1 } @$selected } };
    $reserve_mib = 2048 unless defined($reserve_mib) && "$reserve_mib" ne '';
    die "GPU memory reserve must be between 256 and 32768 MiB"
        unless "$reserve_mib" =~ /^\d+$/ && $reserve_mib >= 256 && $reserve_mib <= 32768;
    my $exe = VisLlama::Builds::find_server_exe($CFG{builds}{$build}) or die "llama-server executable not found for '$build'";
    if (!$skip_fit_check) {
        my $help = VisLlama::Util::capture_command($exe, '--help');
        die "Adaptive auto-fit needs a llama.cpp build supporting --fit-target and --fit; choose a newer build or use Manual mode"
            unless $help =~ /--fit-target\b/ && $help =~ /--fit\b/;
    }
    my %found = map { $_->{id} => $_ } @{VisLlama::Builds::parse_devices(VisLlama::Util::capture_command($exe, '--list-devices'))};
    for my $id (@$selected) {
        die "Device $id is not reported by llama.cpp build '$build'" unless $found{$id};
    }
    my @engine_order = reverse @$selected;
    my @args = ('--device',join(',',@engine_order),'--split-mode','layer',
                '--fit','on','--fit-target',int($reserve_mib));
    return { args=>\@args, devices=>$selected, requested_devices=>[@$selected], model=>$model, mode=>'priority', engine_devices=>\@engine_order,
             reserve_mib=>int($reserve_mib),
             ($skip_fit_check ? (device_snapshot=>\%found) : ()),
             note=>'llama.cpp calculates placement using model, KV and compute memory at load. The margin is a target, not a hard cap; check its load log for actual placement.' };
}

# Read GGUF attention dimensions without loading weight tensors. Cache metadata
# by file path, size and mtime; an unsupported file returns a diagnostic fallback.
sub gguf_attention_metadata {
    my ($file) = @_;
    my @stat = stat($file);
    if (@stat && $GGUF_META_CACHE{$file}
        && $GGUF_META_CACHE{$file}{size} == $stat[7]
        && $GGUF_META_CACHE{$file}{mtime} == $stat[9]) {
        return $GGUF_META_CACHE{$file}{metadata};
    }
    my $result = eval {
        open my $fh, '<:raw', $file or die "Cannot read GGUF: $!";
        my $size = -s $file;
        my $read = sub {
            my ($n) = @_;
            die 'Invalid GGUF metadata length' if $n < 0 || $n > 32*1048576 || tell($fh)+$n > $size;
            my $bytes = '';
            while (length($bytes) < $n) {
                my $got = read($fh,my $part,$n-length($bytes));
                die 'Truncated GGUF metadata' unless $got;
                $bytes .= $part;
            }
            return $bytes;
        };
        my $skip = sub {
            my ($n) = @_;
            die 'Invalid GGUF metadata offset' if $n < 0 || tell($fh)+$n > $size;
            seek($fh,$n,1) or die 'Cannot skip GGUF metadata';
        };
        my $u32 = sub { unpack('V',$read->(4)) };
        my $u64 = sub { unpack('Q<',$read->(8)) };
        my $string = sub {
            my ($keep) = @_;
            my $n = $u64->();
            return $read->($n) if $keep;
            $skip->($n);
            return undef;
        };
        die 'Invalid GGUF header' unless $read->(4) eq 'GGUF';
        my $version = $u32->();
        die 'Unsupported GGUF version' unless $version == 3 || $version == 2;
        my $tensor_count = $u64->(); # Only descriptors are read, never tensor data.
        my $count = $u64->();
        die 'GGUF metadata count is too large' if $count > 200000;
        my %meta;
        for (1..$count) {
            my $key = $string->(1);
            die 'GGUF metadata key is too large' if length($key) > 1024;
            my $type = $u32->();
            my $wanted = $key eq 'general.architecture' || $key eq 'general.alignment' || $key =~ /\.(?:embedding_length|block_count|context_length|feed_forward_length|expert_count|nextn_predict_layers|full_attention_interval|ssm\.(?:conv_kernel|inner_size|state_size|group_count)|attention\.(?:head_count|head_count_kv|key_length|value_length|recurrent_layers|sliding_window|sliding_window_pattern))$/;
            if ($type == 8) {
                my $value = $string->($wanted);
                $meta{$key} = $value if $wanted;
            } elsif ($type == 9) {
                my $element_type = $u32->();
                my $n = $u64->();
                die 'GGUF array is too large' if $n > 10_000_000;
                # Only the bounded layer map is needed. Never materialize large
                # tokenizer/tensor arrays just to calculate a memory estimate.
                if ($wanted && $key =~ /\.(?:feed_forward_length|head_count|head_count_kv|key_length|value_length|recurrent_layers|sliding_window_pattern)$/) {
                    die 'Invalid GGUF recurrent layer map' unless $n > 0 && $n <= 1000 && $element_type =~ /^(?:0|4|7)$/;
                    my @map = map { $element_type == 4 ? $u32->() : unpack('C',$read->(1)) } 1..$n;
                    $meta{$key} = \@map;
                    next;
                }
                if ($element_type == 8) { $string->(0) for 1..$n; }
                else {
                    my %width=(0=>1,1=>1,2=>2,3=>2,4=>4,5=>4,6=>4,7=>1,10=>8,11=>8,12=>8);
                    die 'Unsupported GGUF array type' unless $width{$element_type};
                    $skip->($n*$width{$element_type});
                }
            } else {
                my %width=(0=>1,1=>1,2=>2,3=>2,4=>4,5=>4,6=>4,7=>1,10=>8,11=>8,12=>8);
                die 'Unsupported GGUF metadata type' unless $width{$type};
                my $bytes = $wanted ? $read->($width{$type}) : do { $skip->($width{$type}); undef };
                if (defined $bytes && $type =~ /^(?:0|2|4|7|10)$/) {
                    $meta{$key} = unpack($type == 0 || $type == 7 ? 'C' : $type == 2 ? 'v' : $type == 4 ? 'V' : 'Q<',$bytes);
                }
            }
        }
        # Offsets give stored tensor spans independent of mixed quantization.
        # A failed/unsupported tensor directory must not discard usable KV metadata.
        my $tensor_spans = eval {
            die 'Unsupported tensor directory' unless $tensor_count > 0 && $tensor_count <= 200000;
            my (@tensors,%names);
            for (1..$tensor_count) {
                my $name = $string->(1);
                die 'Invalid tensor name' if length($name)>1024 || $names{$name}++;
                my $dims = $u32->();
                die 'Invalid tensor dimensions' unless $dims >= 1 && $dims <= 4;
                for (1..$dims) { my $dim=$u64->(); die 'Invalid tensor dimension' unless $dim>0 && $dim<2**40; }
                my $type = $u32->();
                # CUDA repacking of exotic formats can change their allocation.
                die 'Unsupported tensor storage' unless $type =~ /^(?:0|1|2|3|6|7|8|9|10|11|12|13|14|15|30)$/;
                push @tensors, [$name,$u64->()];
            }
            my $align = memory_integer($meta{'general.alignment'} // 32,4096);
            die 'Invalid tensor alignment' unless $align && !($align & ($align-1));
            my $data_start = int((tell($fh)+$align-1)/$align)*$align;
            my $data_size = $size-$data_start;
            @tensors = sort { $a->[1] <=> $b->[1] } @tensors;
            die 'Invalid tensor start' unless $tensors[0][1] == 0;
            my %spans;
            for my $i (0..$#tensors) {
                my $end = $i==$#tensors ? $data_size : $tensors[$i+1][1];
                my $length = $end-$tensors[$i][1];
                die 'Invalid tensor extent' unless $length>0 && $end <= $data_size;
                # Include storage padding plus at most one CUDA alignment unit.
                $spans{$tensors[$i][0]} = ($length+256)/1048576;
            }
            \%spans;
        };
        $meta{'_tensor_mib'} = $tensor_spans if ref($tensor_spans) eq 'HASH';
        close $fh;
        \%meta;
    };
    if (@stat && ref($result) eq 'HASH') {
        $GGUF_META_CACHE{$file} = {size=>$stat[7],mtime=>$stat[9],metadata=>$result};
    }
    return ref($result) eq 'HASH' ? $result : undef;
}

# Accept bounded integer metadata/settings without warnings or accidental
# arithmetic on unsupported GGUF arrays. Zero is allowed only when requested.
sub memory_integer {
    my ($value,$max,$zero) = @_;
    return undef if !defined($value) || ref($value) || "$value" !~ /^\d+$/;
    return undef if $value > $max || (!$zero && $value == 0);
    return 0+$value;
}

# Estimate cache memory, not weights or compute buffers. Ordinary dense models
# retain the existing formula. Qwen35's GGUF architecture also covers Qwen3.8:
# b11223 src/models/qwen35{,moe}.cpp gives the recurrent map precedence over
# full_attention_interval (default 4), and block_count includes NextN blocks.
sub estimated_kv_mib {
    my ($file,$settings) = @_;
    my $layout=VisLlama::MemoryLayout::estimate(gguf_attention_metadata($file),$settings);
    return $layout if $layout->{supported};
    my $fallback=legacy_kv_mib($file,$settings);
    if ($fallback) {
        delete @$fallback{qw(layer_cache_mib main_layers nextn_layers)};
        $fallback->{fallback_reason}=$layout->{reason};
        $fallback->{note}=join(' ', $layout->{reason},$fallback->{note}//'Unverified aggregate cache estimate.');
    }
    return $fallback;
}

# Retained only as an explicitly approximate fallback. It must never opt an
# unknown layout into per-layer placement merely because scalar metadata exists.
sub legacy_kv_mib {
    my ($file,$settings) = @_;
    return { mib=>0,context=>0 } if $settings->{noKvOffload};
    my $m = gguf_attention_metadata($file) or return undef;
    my $arch = $m->{'general.architecture'} // '';
    return undef if ref($arch) || $arch !~ /^[a-z0-9]+$/;
    my $layers = memory_integer($m->{"$arch.block_count"},1000);
    my $heads = memory_integer($m->{"$arch.attention.head_count"},1024);
    my $kv_heads = memory_integer($m->{"$arch.attention.head_count_kv"} // $heads,1024);
    my $embd = memory_integer($m->{"$arch.embedding_length"},131072);
    my $ctx = memory_integer($settings->{ctx} || $m->{"$arch.context_length"},4_194_304);
    return undef unless $layers && $heads && $kv_heads && $embd && $ctx;
    my $head_size = $embd / $heads;
    my $key = memory_integer($m->{"$arch.attention.key_length"} // $head_size,131072);
    my $value = memory_integer($m->{"$arch.attention.value_length"} // $head_size,131072);
    return undef unless $key && $value;
    my %bytes=(f16=>2,bf16=>2,f32=>4,q8_0=>34/32,q8_1=>36/32,q4_0=>18/32,q4_1=>20/32,q5_0=>22/32,q5_1=>24/32);
    my $k_type = lc($settings->{cacheK} || 'f16');
    my $v_type = lc($settings->{cacheV} || 'f16');
    # Unknown quantization uses an f16 upper estimate, never an optimistic 0.
    my $k_bytes = $bytes{$k_type} || 2;
    my $v_bytes = $bytes{$v_type} || 2;
    my $per_layer = $ctx * $kv_heads * ($key*$k_bytes + $value*$v_bytes) / 1048576;
    my $result = { mib=>$per_layer*$layers, context=>$ctx, layers=>$layers, architecture=>$arch };
    return $result unless $arch eq 'qwen35' || $arch eq 'qwen35moe';

    # Do not reduce the old estimate if a hybrid layout/state cannot be read.
    # This fallback is visible in the existing planner status, not silent.
    $result->{note} = 'Hybrid metadata is incomplete or invalid; retaining the conservative all-layer KV estimate.';
    my $nextn = memory_integer($m->{"$arch.nextn_predict_layers"} // 0,$layers,1);
    return $result unless defined($nextn) && $nextn < $layers;
    my $main_layers = $layers-$nextn;
    my $map = $m->{"$arch.attention.recurrent_layers"};
    my @recurrent;
    if (defined $map) {
        if (ref($map) eq 'ARRAY') {
            return $result unless @$map == $layers;
            @recurrent = @$map;
        } elsif (defined(memory_integer($map,1,1))) {
            @recurrent = ($map) x $layers;
        } else { return $result; }
        return $result if grep { !defined(memory_integer($_,1,1)) } @recurrent;
        return $result if $nextn && grep { $_ } @recurrent[$main_layers..$layers-1];
    } else {
        my $interval = memory_integer($m->{"$arch.full_attention_interval"} // 4,1000);
        return $result unless $interval;
        @recurrent = map { $_ < $main_layers && (($_+1) % $interval != 0) ? 1 : 0 } 0..$layers-1;
    }
    my $recurrent_layers = grep { $_ } @recurrent[0..$main_layers-1];
    my $attention_layers = $main_layers-$recurrent_layers;
    my $mtp = ($settings->{specType}//'') =~ /(?:^|,)draft-mtp(?:,|$)/;
    my $parallel = memory_integer($settings->{parallel} || 1,1024);
    my $draft = memory_integer(defined($settings->{draftTokens}) && $settings->{draftTokens} ne '' ? $settings->{draftTokens} : 3,4096,1);
    return $result unless $parallel && (!$mtp || defined($draft));
    my $recurrent_mib = 0;
    if ($recurrent_layers) {
        my $conv = memory_integer($m->{"$arch.ssm.conv_kernel"},1024);
        my $inner = memory_integer($m->{"$arch.ssm.inner_size"},131072);
        my $state = memory_integer($m->{"$arch.ssm.state_size"},8192);
        my $groups = memory_integer($m->{"$arch.ssm.group_count"},1024);
        return $result unless $conv && $inner && $state && $groups;
        # llama-hparams.cpp n_embd_r/n_embd_s; llama-memory-recurrent.cpp
        # allocates F32 R/S state for each slot and each rollback snapshot.
        my $state_elements = ($conv-1)*($inner+2*$groups*$state) + $state*$inner;
        $recurrent_mib = $state_elements*4*$recurrent_layers*$parallel*(1+($mtp ? $draft : 0))/1048576;
    }
    # MTP is a separate dense context. Its cache belongs to the NextN blocks,
    # not every trunk GPU. The fallback retains a per-device upper allowance.
    my $mtp_mib = $mtp ? $ctx*$nextn*$kv_heads*($key*($k_bytes > 2 ? $k_bytes : 2)+$value*($v_bytes > 2 ? $v_bytes : 2))/1048576 : 0;
    my @layer_cache = map { $_ >= $main_layers ? ($nextn ? $mtp_mib/$nextn : 0)
        : $recurrent[$_] ? ($recurrent_layers ? $recurrent_mib/$recurrent_layers : 0) : $per_layer } 0..$layers-1;
    return { %$result, mib=>$per_layer*$attention_layers,
             layer_cache_mib=>\@layer_cache, main_layers=>$main_layers, nextn_layers=>$nextn,
             full_attention_layers=>$attention_layers, recurrent_layers=>$recurrent_layers,
             recurrent_mib=>$recurrent_mib, mtp_mib=>$mtp_mib,
             note=>sprintf('Hybrid estimate: %d full-attention layers, %d recurrent layers; %.0f MiB main KV, %.0f MiB recurrent state, %.0f MiB MTP cache allowance per used GPU. Compute allowance is conservative; layer placement and actual allocations can differ.',
                 $attention_layers,$recurrent_layers,$per_layer*$attention_layers,$recurrent_mib,$mtp_mib) };
}

# A deterministic layer split for users who want an earlier GPU to hold as
# many layers as current VRAM permits. The saved reserve is a minimum; GGUF
# context and KV dimensions can increase it for each GPU's layer share.
sub gpu_priority_split_plan {
    my ($build, $model, $selected, $reserve_mib, $settings, $arguments) = @_;
    $settings = {} unless ref($settings) eq 'HASH';
    my $base = gpu_priority_plan($build, $model, $selected, $reserve_mib, 1);
    # The helper validates/defaults its own argument copy. Carry that numeric
    # value forward so a cleared field cannot become zero during subtraction.
    $reserve_mib = $base->{reserve_mib};
    my $exe = VisLlama::Builds::find_server_exe($CFG{builds}{$build});
    my $help = VisLlama::Util::capture_command($exe, '--help');
    die "Calculated GPU split needs a llama.cpp build supporting --tensor-split"
        unless $help =~ /--tensor-split\b/;
    $settings=VisLlama::PlannerSettings::from_args($settings,$arguments,$help,VisLlama::Builds::planner_build_number($exe));
    die 'Calculated placement cannot account for these custom allocation or draft-model options. Use Adaptive auto-fit or Manual mode.' if $settings->{_unsupported};
    my %found = %{$base->{device_snapshot}};
    my @free_mib;
    for my $id (@$selected) {
        my $description = $found{$id}{description} // '';
        my ($number, $unit) = $description =~ /([\d,.]+)\s*(MiB|GiB)\s+free\b/i;
        die "Cannot read free VRAM for $id from --list-devices; select Adaptive auto-fit or set a Manual tensor split"
            unless defined($number) && defined($unit);
        $number =~ s/,//g;
        my $free = $number * (lc($unit) eq 'gib' ? 1024 : 1);
        push @free_mib, int($free);
    }
    my $model_bytes = -s $model;
    my @model_files=($model);
    if (basename($model) =~ /^(.*)-(\d{5})-of-(\d{5})\.gguf$/i) {
        my ($prefix,$count) = ($1,int($3));
        die "Invalid GGUF shard count" if $count < 1 || $count > 9999;
        $model_bytes = 0;
        @model_files=();
        for my $part (1..$count) {
            my $file = File::Spec->catfile(dirname($model),sprintf('%s-%05d-of-%05d.gguf',$prefix,$part,$count));
            die "GGUF shard $part of $count is missing" unless -f $file;
            $model_bytes += -s $file;
            push @model_files,$file;
        }
    }
    my $remaining = int($model_bytes / 1048576 * 1.06 + 0.999);
    $remaining = 1 if $remaining < 1;
    my $weights_total = $remaining;
    my $kv = estimated_kv_mib($model_files[0],$settings);
    # Each shard has its own relative tensor offsets. Read/cache it separately,
    # then combine names without counting a shard's metadata as GPU weights.
    {
        my $first=gguf_attention_metadata($model_files[0]);
        my $meta=$first ? {%$first} : undef;
        my (%tensors,$complete);$complete=1;
        for my $file (@model_files) {
            my $part=gguf_attention_metadata($file);
            if (!$part || ref($part->{_tensor_mib}) ne 'HASH') {$complete=0;last}
            for my $name (keys %{$part->{_tensor_mib}}) {
                if (exists $tensors{$name}) {$complete=0;last}
                $tensors{$name}=$part->{_tensor_mib}{$name};
            }
            last unless $complete;
        }
        if ($meta) { $meta->{_tensor_mib}=$complete?\%tensors:undef; }
        my $layer_plan=VisLlama::LayerPlanner::plan($meta,$kv,$settings,$selected,\@free_mib,$reserve_mib);
        if ($layer_plan) {
            return {%$layer_plan,requested_devices=>[@$selected],model=>$model,mode=>'priority_split',reserve_mib=>int($reserve_mib),
                kv_estimate_mib=>int($kv->{mib}+0.999),recurrent_estimate_mib=>int(($kv->{recurrent_mib}//0)+0.999),
                mtp_cache_allowance_mib=>int(($kv->{mtp_mib}//0)+0.999),
                planning_quality=>'layer_estimate',layout=>$kv->{layout},architecture=>$kv->{architecture},
                cpu_cache_estimate_mib=>int(($kv->{cpu_cache_mib}//0)+0.999)};
        }
    }
    my $kv_ratio = $kv ? ($kv->{mib}+($kv->{recurrent_mib}//0))/$weights_total : 0;
    my $compute_mib = $kv ? (($settings->{specType}//'') =~ /(?:^|,)draft-mtp(?:,|$)/ ? 3072 : 2048) : 0;
    my $fixed_mib = $compute_mib + ($kv ? ($kv->{mtp_mib}//0) : 0);
    my (@ids,@parts,@effective_reserves);
    for my $i (0..$#$selected) {
        my $available = $free_mib[$i]-$reserve_mib;
        if ($kv) {
            # Layer mode places KV alongside its layer. Approximate the
            # layer fraction by its weight share and leave compute room.
            my $runtime_capacity = int(($free_mib[$i]-$fixed_mib)/(1+$kv_ratio));
            $available = $runtime_capacity if $runtime_capacity < $available;
        }
        $available = 0 if $available < 0;
        my $take = $remaining < $available ? $remaining : $available;
        if ($take > 0) {
            push @ids, $selected->[$i]; push @parts, $take;
            my $runtime_reserve = int($fixed_mib+$kv_ratio*$take+0.999);
            push @effective_reserves, $runtime_reserve > $reserve_mib ? $runtime_reserve : int($reserve_mib);
            $remaining -= $take;
        }
        last if $remaining <= 0;
    }
    die "No selected GPU has free VRAM above the $reserve_mib MiB reserve" unless @ids;
    die "Estimated model weights, KV cache and compute memory exceed selected GPUs' available VRAM. Reduce context or cache precision, free VRAM, or use Adaptive auto-fit"
        if $remaining > 0;
    my @args = ('--device',join(',',@ids),'--split-mode','layer');
    push @args, ('--tensor-split',join(',',@parts)) if @ids > 1;
    push @args, ('--fit','off');
    return { args=>\@args, devices=>\@ids, requested_devices=>[@$selected], model=>$model, mode=>'priority_split', engine_devices=>\@ids,
             weights_mib=>\@parts, reserve_mib=>int($reserve_mib), effective_reserves_mib=>\@effective_reserves,
             planning_quality=>$kv?'approximate':'reserve_only',layout=>$kv ? $kv->{layout}:undef,
             kv_estimate_mib=>$kv ? int($kv->{mib}+0.999) : undef,
             recurrent_estimate_mib=>$kv ? int(($kv->{recurrent_mib}//0)+0.999) : undef,
             mtp_cache_allowance_mib=>$kv ? int(($kv->{mtp_mib}//0)+0.999) : undef,
             note=>$kv ? ('Approximate aggregate fallback: layer-level weight placement is unavailable for this file or configuration. This is not a verified fit; Adaptive auto-fit is recommended. ' . ($kv->{note} // 'Actual llama.cpp allocations can differ.'))
                       : 'Insufficient metadata: weight-only estimate with the minimum reserve; KV and compute are not accounted for. Adaptive auto-fit is recommended.' };
}

# Choose calculated placement only for priority_split; callers use this helper
# for priority modes, while manual/even modes bypass these planners.
sub gpu_plan_for_mode {
    my ($build, $model, $selected, $reserve_mib, $mode, $settings, $arguments) = @_;
    return gpu_priority_split_plan($build,$model,$selected,$reserve_mib,$settings,$arguments)
        if ($mode // '') eq 'priority_split';
    return gpu_priority_plan($build,$model,$selected,$reserve_mib);
}

# Replace planner-owned flags in an existing argument array with the fresh plan.
# Other user arguments retain their order and values.
sub priority_args {
    my ($args,$plan) = @_;
    my $clean = [ @$args ];
    $clean = VisLlama::Util::strip_arg_with_value($clean,$_) for qw(--device --tensor-split --split-mode --main-gpu --fit-target --gpu-layers);
    $clean = [ grep { $_ ne '--no-fit' } @$clean ];
    $clean = VisLlama::Util::strip_arg_with_value($clean,'--fit');
    return [ @$clean, @{$plan->{args}} ];
}

1;
