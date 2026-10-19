package VisLlama::LayerPlanner;

# Reviewed layer-mode accounting. Tensor-split selects layer boundaries
# in llama.cpp; it is not a request to allocate a byte count on each device.
use strict;
use warnings;
use VisLlama::MemoryLayout ();

sub plan {
    my ($meta,$kv,$settings,$devices,$free,$reserve) = @_;
    return undef unless $meta && $kv && $kv->{supported}
        && ref($kv->{layer_cache_mib}) eq 'ARRAY' && ref($meta->{_tensor_mib}) eq 'HASH';
    return undef if $settings->{_unsupported};
    my $layers=$kv->{layers};
    my $main=$kv->{main_layers};
    my $mtp=($settings->{specType}//'') =~ /(?:^|,)draft-mtp(?:,|$)/;
    return undef unless $layers && $main && $layers == @{$kv->{layer_cache_mib}};
    return undef if $mtp && ($kv->{nextn_layers}//0) != 1;
    my @weights=(0) x ($layers+1);
    my ($input,$output,$cpu_weights)=(0,0,0);
    my $cpu_layers=VisLlama::MemoryLayout::integer($settings->{nCpuMoe}||0,1_000_000,1);
    return undef unless defined $cpu_layers;
    for my $name (keys %{$meta->{_tensor_mib}}) {
        my $mib=$meta->{_tensor_mib}{$name};
        if ($name eq 'token_embd.weight') { $input += $mib; }
        elsif ($name =~ /^output(?:_norm)?\.(?:weight|scale)$/) {
            $weights[$layers]+=$mib;
            $output=1 if $name eq 'output.weight';
        } elsif ($name =~ /^blk\.(\d+)\./ && $1 < $layers) {
            my $layer=$1;
            # Match llama.cpp's routed-expert CPU override. Shared experts and
            # routers stay on GPU; selecting fewer experts does not shrink weights.
            if (($settings->{cpuMoe} || $layer<$cpu_layers) && $name =~ /\.ffn_(?:up|down|gate|gate_up)_(?:ch)?exps/) {
                $cpu_weights+=$mib;
            } else { $weights[$layer]+=$mib; }
        } else { return undef; }
    }
    return undef unless $input && !grep { $_<=0 } @weights[0..$main-1];
    # llama.cpp keeps input embeddings on CPU. A tied output is nevertheless a
    # separate GPU allocation; count its copy when output.weight is absent.
    $weights[$layers]+=$input unless $output;
    if ($mtp) { return undef if grep { $_<=0 } @weights[$main..$layers-1]; }
    else { $weights[$_]=0 for $main..$layers-1; }
    # Small tensor padding and allocator overhead remain budgeted. Unlike the
    # old file-size multiplier, CPU embeddings are not charged to the GPUs.
    @weights=map { $_*1.01 } @weights;

    # Compute is still a conservative allowance, not an exact graph estimate.
    # The supplied 256K/ubatch32/FA log used 1096.57 MiB per trunk device.
    # Retain 2 GiB for similarly bounded graphs, 3 GiB otherwise, and a separate
    # 1 GiB for MTP on its own device. Never reuse one log's measured bytes as a
    # universal value or as a reservation in VRAM.
    my $small_graph=$settings->{flash} && $kv->{context}<=262144
        && ($settings->{parallel}//'') =~ /^1$/
        && ($settings->{ubatch}//'') =~ /^\d+$/ && $settings->{ubatch}>0 && $settings->{ubatch}<=64
        && ($settings->{batch}//'') =~ /^\d+$/ && $settings->{batch}>0 && $settings->{batch}<=256;
    my $main_compute=$small_graph ? 2048 : 3072;
    my (@ids,@counts,@weight_parts,@reserves,@cache_parts,@compute_parts);
    my $next=0;
    for my $i (0..$#$devices) {
        my ($weight,$cache,$count,$has_main,$has_mtp)=(0,0,0,0,0);
        while ($next <= $layers) {
            # Keep appended NextN block(s) and the output head together so the
            # separate draft graph/cache is charged only to its owning GPU.
            my $end=$next >= $main ? $layers : $next;
            my ($w,$c)=($weight,$cache);
            for my $j ($next..$end) { $w+=$weights[$j]; $c+=$kv->{layer_cache_mib}[$j]//0; }
            my $trunk=$has_main || $next<$main || $end==$layers;
            my $draft=$has_mtp || ($mtp && $end >= $main);
            my $compute=($trunk ? $main_compute : 0)+($draft ? 1024 : 0);
            # An output-only GPU still executes the main output graph.
            $compute=$main_compute if !$compute;
            my $runtime=$c+$compute;
            my $margin=$runtime>$reserve ? $runtime : $reserve;
            last if int($w+0.999)+int($margin+0.999) > $free->[$i];
            ($weight,$cache,$has_main,$has_mtp)=($w,$c,$trunk,$draft);
            $count += $end-$next+1;
            $next=$end+1;
        }
        if ($count) {
            my $compute=($has_main ? $main_compute : 0)+($has_mtp ? 1024 : 0);
            $compute=$main_compute if !$compute;
            push @ids,$devices->[$i]; push @counts,$count;
            push @weight_parts,int($weight+0.999);
            push @cache_parts,int($cache+0.999); push @compute_parts,$compute;
            push @reserves,int(($cache+$compute>$reserve ? $cache+$compute : $reserve)+0.999);
        }
        last if $next>$layers;
    }
    die "Estimated model weights, KV cache and compute memory exceed selected GPUs' available VRAM. Reduce context or cache precision, free VRAM, or use Adaptive auto-fit"
        if $next <= $layers;
    # Put each split halfway between adjacent layer indices. Integer layer-count
    # ratios put the boundary on a float rounding edge in upper_bound(). These
    # half-step boundaries select the intended whole layers reproducibly.
    my @ratios=map { 2*$_ } @counts;
    if (@ratios>1) { $ratios[0]--; $ratios[-1]++; }
    my @args=('--device',join(',',@ids),'--split-mode','layer','--gpu-layers',($layers>=999?$layers+1:999));
    push @args,('--tensor-split',join(',',@ratios)) if @ids>1;
    push @args,('--fit','off');
    return {args=>\@args,devices=>\@ids,engine_devices=>\@ids,
        weights_mib=>\@weight_parts,effective_reserves_mib=>\@reserves,
        layer_counts=>\@counts,cache_mib=>\@cache_parts,compute_allowance_mib=>\@compute_parts,
        cpu_weights_mib=>int($input+$cpu_weights+0.999),
        note=>join(' ','Layer-aware estimate:', $kv->{note}//'',
            'GGUF weights and caches follow their layers; CPU-resident weights/cache are excluded from VRAM. MTP stays with its output head. Tensor-split encodes layer boundaries, not MiB. Compute is an allowance, not a guaranteed fit; verify the load log.')};
}

1;
