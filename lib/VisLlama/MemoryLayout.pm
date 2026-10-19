package VisLlama::MemoryLayout;

# Architecture adapters describe cache ownership; LayerPlanner owns placement.
# Rules are traced to llama.cpp b11223 model loaders, hparams, recurrent memory,
# context padding and ISWA allocation. b10819's ISWA formula is also checked.
use strict;
use warnings;

sub integer {
    my ($x,$max,$zero)=@_;
    return undef if !defined($x)||ref($x)||"$x"!~/^\d+$/||$x>$max||(!$zero&&!$x);
    return 0+$x;
}
sub pad { my ($x,$n)=@_; return int(($x+$n-1)/$n)*$n; }
sub vector {
    my ($x,$n,$max,$zero)=@_;
    my @v=ref($x) eq 'ARRAY' ? @$x : ($x)x$n;
    return undef unless @v==$n;
    return undef if grep { !defined(integer($_,$max,$zero)) } @v;
    return \@v;
}
sub row_bytes {
    my ($n,$type)=@_;
    my %types=(f32=>[1,4],f16=>[1,2],bf16=>[1,2],q8_0=>[32,34],q8_1=>[32,36],
        q4_0=>[32,18],q4_1=>[32,20],q5_0=>[32,22],q5_1=>[32,24]);
    my $t=$types{lc($type||'f16')} or return undef;
    return undef if $n%$t->[0];
    return $n/$t->[0]*$t->[1];
}
sub unsupported { return {supported=>0,reason=>$_[0]}; }

sub estimate {
    my ($m,$s)=@_;
    return unsupported('GGUF metadata is unavailable.') unless $m;
    my $a=$m->{'general.architecture'}//'';
    my %known=map {$_=>1} qw(llama qwen2 qwen2moe qwen3 qwen3moe gemma gemma2 gemma3 phi3 qwen3next qwen35 qwen35moe jamba nemotron_h nemotron_h_moe);
    return unsupported('This architecture has no reviewed cache-layout adapter.') unless !ref($a) && $known{$a};
    return unsupported($s->{_unsupported}) if $s->{_unsupported};
    my $n=integer($m->{"$a.block_count"},1000);
    my $embd=integer($m->{"$a.embedding_length"},131072);
    return unsupported('Layer count or embedding dimensions are invalid.') unless $n && $embd;
    my $next=integer($m->{"$a.nextn_predict_layers"}//0,$n,1);
    return unsupported('Appended draft layer metadata is invalid.') unless defined($next)&&$next<$n;
    my $main=$n-$next;
    my $hybrid=$a=~/^(?:qwen35|qwen35moe|qwen3next|jamba|nemotron_h|nemotron_h_moe)$/;
    my $mtp=($s->{specType}//'')=~/(?:^|,)draft-mtp(?:,|$)/;
    return unsupported('MTP cache ownership is not reviewed for this architecture.') if $mtp && (!$next || $a!~/^(?:qwen35|qwen35moe|qwen3next|nemotron_h_moe)$/);
    return unsupported('Appended layers on this architecture need an explicit adapter.') if $next && !$hybrid;
    my $heads=vector($m->{"$a.attention.head_count"},$n,1024,1);
    my $kvheads=vector($m->{"$a.attention.head_count_kv"}//$m->{"$a.attention.head_count"},$n,1024,1);
    return unsupported('Per-layer head metadata is incomplete.') unless $heads && $kvheads;
    my (@key_dim,@value_dim);
    for my $i (0..$n-1) {
        for my $pair (['key_length',\@key_dim],['value_length',\@value_dim]) {
            my $raw=$m->{"$a.attention.$pair->[0]"};
            return unsupported('Per-layer head dimensions have the wrong length.') if ref($raw) eq 'ARRAY' && @$raw!=$n;
            my $v=ref($raw) eq 'ARRAY'?$raw->[$i]:$raw;
            $v=$heads->[$i] ? $embd/$heads->[$i]:0 unless defined $v;
            my $dim=integer($v,131072,1);
            return unsupported('Attention head dimensions are invalid.') unless defined $dim;
            push @{$pair->[1]},$dim;
        }
    }
    # Without flash attention, llama.cpp pads V rows to the widest layer.
    # For auto FA, the wider value is also a safe upper budget.
    my $max_v=0;
    for my $i (0..$n-1) {$max_v=$value_dim[$i]*$kvheads->[$i] if $value_dim[$i]*$kvheads->[$i]>$max_v}
    my $parallel=integer($s->{parallel}||1,1024);
    my $ctx=integer($s->{ctx}||$m->{"$a.context_length"},4_194_304);
    my $slot=integer($s->{kvUnifiedPerSlot}||0,4_194_304,1);
    # An absent ctx-size allows per-slot sizing; explicit ctx-size=0 means use
    # the model's training context, so must not be treated as an absent flag.
    $ctx=$slot*$parallel if $parallel && $slot && (!defined($s->{ctx}) || $s->{ctx} eq '');
    return unsupported('Context or parallel slot settings are invalid.') unless $ctx && $parallel && defined($slot) && $ctx<=4_194_304;
    my $unified=($s->{kvUnified}//'off') eq 'on';
    my $total=pad($ctx,256);
    my $per=$unified ? $total : pad(int($total/$parallel),256);
    my $streams=$unified ? 1:$parallel;
    $total=$per*$streams;
    my $batch=integer($s->{batch}||2048,4_194_304);
    my $ubatch=integer($s->{ubatch}||512,4_194_304);
    return unsupported('Batch settings are invalid.') unless $batch && $ubatch;
    $ubatch=$batch if $batch<$ubatch;
    $ubatch=$total if $total<$ubatch;
    my $draft=integer(defined($s->{draftTokens})&&$s->{draftTokens} ne ''?$s->{draftTokens}:3,4096,1);
    return unsupported('Draft token count is invalid.') unless defined $draft;
    my @recr=(0)x$n;my @ffonly=(0)x$n;
    if ($a=~/^(?:qwen35|qwen35moe|qwen3next)$/) {
        if (exists $m->{"$a.attention.recurrent_layers"}) {
            my $map=vector($m->{"$a.attention.recurrent_layers"},$n,1,1);
            return unsupported('Recurrent layer map is invalid.') unless $map;
            @recr=@$map;
        } else {
            my $interval=integer($m->{"$a.full_attention_interval"}//4,1000);
            return unsupported('Full-attention interval is invalid.') unless $interval;
            @recr=map {$_<$main && ($_+1)%$interval ? 1:0} 0..$n-1;
        }
    } elsif ($a eq 'jamba') {
        @recr=map { $kvheads->[$_]==0 ? 1:0 } 0..$n-1;
    } elsif ($a=~/^nemotron_h/) {
        my $ff=vector($m->{"$a.feed_forward_length"},$n,16_777_216,1);
        return unsupported('Hybrid feed-forward layer map is missing.') unless $ff;
        @ffonly=map {$_<$main && $ff->[$_]>0 ? 1:0} 0..$n-1;
        @recr=map {$_<$main && !$ffonly[$_] && !$kvheads->[$_] ? 1:0} 0..$n-1;
    }
    return unsupported('Draft blocks cannot be recurrent.') if $next && grep {$_} @recr[$main..$n-1];
    my $recurrent=grep {$_} @recr;
    my $state_mib=0;
    if ($recurrent) {
        my $conv=integer($m->{"$a.ssm.conv_kernel"},1024);
        my $inner=integer($m->{"$a.ssm.inner_size"},131072);
        my $state=integer($m->{"$a.ssm.state_size"},8192);
        my $groups=integer($m->{"$a.ssm.group_count"}//($a eq 'jamba'?0:undef),1024,1);
        return unsupported('Recurrent state dimensions are incomplete.') unless $conv && $inner && $state && defined($groups);
        $state_mib=(($conv-1)*($inner+2*$groups*$state)+$state*$inner)*4*$parallel*(1+($mtp?$draft:0))/1048576;
    }
    my @swa=(0)x$n;
    my $window=integer($m->{"$a.attention.sliding_window"}//($a eq 'gemma2'?4096:0),4_194_304,1);
    return unsupported('Sliding-window metadata is invalid.') unless defined $window;
    my @notes;
    # Phi3's inspected loader explicitly disables SWA; Llama/Mistral GGUFs
    # mapped to the llama loader also use full KV. Do not infer savings merely
    # because a model advertises a window in metadata.
    if (($a eq 'gemma2'||$a eq 'gemma3') && $window) {
        my $pattern=$m->{"$a.attention.sliding_window_pattern"}//($a eq 'gemma2'?2:6);
        if (ref($pattern) eq 'ARRAY') {
            my $v=vector($pattern,$n,1,1);return unsupported('Sliding-window layer map is invalid.') unless $v;@swa=@$v;
        } else {
            $pattern=integer($pattern,1000,1);return unsupported('Sliding-window pattern is invalid.') unless defined $pattern;
            @swa=map {!$pattern || $_%$pattern<$pattern-1 ? 1:0} 0..$n-1;
        }
    } elsif ($window) { push @notes,'Full-context cache budget retained for this loader; no window savings assumed.'; }
    my $swa_cells=$per;
    if (grep {$_} @swa) {
        if (!$s->{swaFull} && $s->{_swa_profile}) {
            my $need=$window*($unified?$parallel:1)+$ubatch;
            $swa_cells=pad($need<$per?$need:$per,256);
        } elsif (!$s->{swaFull}) { push @notes,'Build-specific SWA allocation is unverified; using a full-context cache upper budget.'; }
    }
    my (@cache,@kind);my ($kv_mib,$rs_mib,$mtp_mib)=(0,0,0);
    for my $i (0..$n-1) {
        if ($ffonly[$i]) { push @cache,0;push @kind,'feed-forward';next; }
        if ($recr[$i]) { push @cache,$state_mib;push @kind,'recurrent';$rs_mib+=$state_mib;next; }
        if ($i>=$main && !$mtp) { push @cache,0;push @kind,'inactive-draft';next; }
        return unsupported('Attention head count is zero.') unless $heads->[$i] && $kvheads->[$i];
        my $key=$key_dim[$i];
        my $value=$value_dim[$i];
        return unsupported('Attention head dimensions are invalid.') unless $key && $value;
        my $k=row_bytes($key*$kvheads->[$i],$i>=$main?$s->{draftTypeK}:$s->{cacheK});
        my $v=row_bytes($s->{flash}?$value*$kvheads->[$i]:$max_v,$i>=$main?$s->{draftTypeV}:$s->{cacheV});
        return unsupported('Cache type or quantization block geometry is unsupported.') unless defined($k)&&defined($v);
        my $cells=$i<$main && $swa[$i] ? $swa_cells:$per;
        my $mib=($k+$v)*$cells*$streams/1048576;
        push @cache,$mib;push @kind,$i>=$main?'mtp':$swa[$i]?'sliding':'attention';
        if ($i>=$main) {$mtp_mib+=$mib} else {$kv_mib+=$mib}
    }
    my $cpu_cache=0;
    if ($s->{noKvOffload}) {$cpu_cache=$kv_mib+$rs_mib+$mtp_mib;@cache=(0)x$n;($kv_mib,$rs_mib,$mtp_mib)=(0,0,0)}
    push @notes,$s->{_default_note} if $s->{_default_note};
    my $family=$hybrid?'hybrid':(grep {$_} @swa)?'sliding-window':'full-attention';
    return {supported=>1,architecture=>$a,layout=>$family,layers=>$n,main_layers=>$main,nextn_layers=>$next,
        context=>$total,parallel=>$parallel,layer_cache_mib=>\@cache,layer_kinds=>\@kind,
        mib=>$kv_mib,recurrent_mib=>$rs_mib,mtp_mib=>$mtp_mib,cpu_cache_mib=>$cpu_cache,
        full_attention_layers=>scalar(grep {$_ eq 'attention'} @kind),recurrent_layers=>$recurrent,
        note=>join(' ',"$family cache layout; $total allocated context cells across $parallel slot(s).",@notes)};
}

1;
