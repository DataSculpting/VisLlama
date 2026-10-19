use strict;
use warnings;
use File::Temp qw(tempfile);
use File::Basename qw(basename dirname);
use File::Spec;

use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use VisLlama::GPUPlanner ();
use VisLlama::Catalog ();
use VisLlama::Router ();
use VisLlama::Context qw(%CFG $STATE);
no warnings 'redefine';
$CFG{builds} = { test => '/mock-build' };
$STATE = {};
sub VisLlama::Builds::find_server_exe { return '/mock-build/llama-server.exe' }
sub VisLlama::Catalog::ini_value { return $_[0] // '' }
my $device_output = "CUDA1: Test 1, 2052 MiB free\nCUDA0: Test 0, 2058 MiB free\n";
my $help_output = '--fit [on|off] --fit-target MiB --tensor-split ratios';
my ($help_calls,$device_calls) = (0,0);
sub VisLlama::Util::capture_command { if ($_[1] eq '--help') { $help_calls++; return $help_output } $device_calls++; return $device_output }
sub VisLlama::Builds::parse_devices {
    my ($raw) = @_;
    return [ map { /^([^:]+):\s*(.+)$/; { id=>$1, description=>$2 } } split /\n/, $raw ];
}

my ($fh,$model) = tempfile(SUFFIX=>'.gguf',UNLINK=>1);
print $fh 'X' x (4*1048576);
close $fh;
my $plan = &VisLlama::GPUPlanner::gpu_priority_plan('test',$model,['CUDA1','CUDA0'],2048);
die 'GPU priority fitter arguments incorrect' unless
    join(',',@{$plan->{devices}}) eq 'CUDA1,CUDA0' &&
    join(',',@{$plan->{engine_devices}}) eq 'CUDA0,CUDA1' &&
    join(',',@{$plan->{args}}) eq '--device,CUDA0,CUDA1,--split-mode,layer,--fit,on,--fit-target,2048';
$help_calls=$device_calls=0;
my $split = &VisLlama::GPUPlanner::gpu_plan_for_mode('test',$model,['CUDA1','CUDA0'],2048,'priority_split');
die 'Calculated planning must probe build support and devices once each' unless $help_calls == 1 && $device_calls == 1;
# A cleared numeric input arrives as an empty string. The shared validator's
# default must reach the arithmetic and reported reserves, not just its args.
for my $reserve ('',undef) {
    my @warnings;
    my $defaulted;
    { local $SIG{__WARN__}=sub { push @warnings,@_ };
      $defaulted=VisLlama::GPUPlanner::gpu_plan_for_mode('test',$model,['CUDA1','CUDA0'],$reserve,'priority_split'); }
    die 'Blank/missing reserve emitted a numeric warning' if @warnings;
    die 'Blank/missing reserve did not use the validated 2048 MiB default' unless
        $defaulted->{reserve_mib}==2048 &&
        join(',',@{$defaulted->{args}}) eq join(',',@{$split->{args}}) &&
        join(',',@{$defaulted->{effective_reserves_mib}}) eq join(',',@{$split->{effective_reserves_mib}});
}
for my $reserve (0,'invalid',255,32769) {
    eval { VisLlama::GPUPlanner::gpu_plan_for_mode('test',$model,['CUDA1','CUDA0'],$reserve,'priority_split') };
    die 'Invalid reserve was silently replaced by the default' unless $@ =~ /reserve must be between/;
}
die 'Calculated priority order must explicitly split layers in UI order' unless
    join(',',@{$split->{devices}}) eq 'CUDA1,CUDA0' &&
    join(',',@{$split->{weights_mib}}) eq '4,1' &&
    join(',',@{$split->{args}}) eq '--device,CUDA1,CUDA0,--split-mode,layer,--tensor-split,4,1,--fit,off';
my $chosen = &VisLlama::GPUPlanner::priority_args(['--device','CUDA0','--tensor-split','1,1','--split-mode','row','--main-gpu','0','--fit-target','64','--no-fit','--gpu-layers','all','--ctx-size','4096'],$plan);
die 'Manual GPU flags were not replaced' unless join('|',@$chosen) eq '--ctx-size|4096|--device|CUDA0,CUDA1|--split-mode|layer|--fit|on|--fit-target|2048';
truncate $model, 1048576 or die $!;
my $single = &VisLlama::GPUPlanner::gpu_priority_plan('test',$model,['CUDA1','CUDA0'],2048);
die 'Selected GPUs must stay available to the native fitter' unless join(',',@{$single->{devices}}) eq 'CUDA1,CUDA0' && join(',',@{$single->{engine_devices}}) eq 'CUDA0,CUDA1';
my $single_split = &VisLlama::GPUPlanner::gpu_plan_for_mode('test',$model,['CUDA1','CUDA0'],2048,'priority_split');
die 'Calculated split must omit unneeded later GPUs' unless
    join(',',@{$single_split->{devices}}) eq 'CUDA1' && !grep { $_ eq '--tensor-split' } @{$single_split->{args}};
$device_output = "CUDA3: First, 300 MiB free\nCUDA0: Second, 300 MiB free\n";
truncate $model, 42*1048576 or die $!;
my $tight = &VisLlama::GPUPlanner::gpu_plan_for_mode('test',$model,['CUDA3','CUDA0'],256,'priority_split');
my $roomy = &VisLlama::GPUPlanner::gpu_plan_for_mode('test',$model,['CUDA3','CUDA0'],270,'priority_split');
die 'Increasing headroom must shift more weights to the second GPU' unless
    $roomy->{weights_mib}[0] < $tight->{weights_mib}[0] &&
    $roomy->{weights_mib}[1] > $tight->{weights_mib}[1] &&
    join(',',@{$roomy->{args}}) =~ /--fit,off$/ &&
    !grep { $_ eq '--fit-target' } @{$roomy->{args}};
$device_output = "CUDA1: Test 1, 2052 MiB free\nCUDA0: Test 0, 2058 MiB free\n";
eval { &VisLlama::GPUPlanner::gpu_priority_plan('test',$model,['CUDA0','CUDA0'],2048) };
die 'Duplicate device accepted' unless $@ =~ /duplicate device/;
truncate $model, 4*1048576 or die $!;
my ($ini_fh,$ini_path) = tempfile(SUFFIX=>'.ini',UNLINK=>1);
close $ini_fh;
my $items=[{enabled=>1,build=>'test',alias=>'sample',model=>$model,
    ui=>{gpuPriority=>'priority',devices=>['CUDA1','CUDA0'],gpuReserve=>2048},
    options=>[['device','CUDA0'],['tensor-split','1,1'],['main-gpu','0'],['ctx-size','4096'],['fit-target','64'],['no-fit','true'],['gpu-layers','all']]}];
&VisLlama::Catalog::write_router_ini_for_build($items,'test',$ini_path);
my $ini=do { local $/; open my $f,'<',$ini_path or die $!; <$f> };
die 'Router INI did not replace manual GPU options' unless
    $ini =~ /device = CUDA0,CUDA1/ && $ini =~ /fit-target = 2048/ &&
    $ini =~ /fit = on/ && $ini =~ /split-mode = layer/ && $ini =~ /ctx-size = 4096/ &&
    $ini !~ /main-gpu|no-fit|tensor-split|gpu-layers|fit-target = 64/;
$items->[0]{ui}{gpuPriority}='priority_split';
&VisLlama::Catalog::write_router_ini_for_build($items,'test',$ini_path,'sample');
$ini=do { local $/; open my $f,'<',$ini_path or die $!; <$f> };
die 'Router INI did not apply calculated layer split' unless
    $ini =~ /device = CUDA1,CUDA0/ && $ini =~ /tensor-split = 4,1/ &&
    $ini =~ /fit = off/ && $ini !~ /fit-target =/;
# Startup presets are held for the controller to plan after earlier models
# settle; a startup INI must never contain a stale calculated split.
$items->[0]{load_on_startup}=1;
&VisLlama::Catalog::write_router_ini_for_build($items,'test',$ini_path);
$ini=do { local $/; open my $f,'<',$ini_path or die $!; <$f> };
die 'Calculated startup model was loaded before dynamic planning' unless
    $ini =~ /load-on-startup = false/ && $ini !~ /tensor-split =/;
$items->[0]{ui}{gpuPriority}='priority';
$device_output = "CUDA1: Test 1, 2048 MiB free\nCUDA0: Test 0, 2048 MiB free\n";
&VisLlama::Catalog::write_router_ini_for_build($items,'test',$ini_path);
&VisLlama::Catalog::write_router_ini_for_build($items,'test',$ini_path,'sample');
$help_output = '--device --tensor-split';
eval { &VisLlama::GPUPlanner::gpu_priority_plan('test',$model,['CUDA1','CUDA0'],2048) };
die 'Unsupported build should be rejected clearly' unless $@ =~ /supporting --fit-target/;
# Explicit loads, startup and proxy-triggered requests call the same central
# loader. Simulate an earlier model consuming VRAM before the next load.
$help_output = '--fit [on|off] --fit-target MiB --tensor-split ratios';
$device_output = "CUDA1: First, 300 MiB free\nCUDA0: Second, 300 MiB free\n";
truncate $model, 42*1048576 or die $!;
my $managed = [map {{enabled=>1,build=>'test',alias=>$_,model=>$model,
    ui=>{gpuPriority=>'priority_split',devices=>['CUDA1','CUDA0'],gpuReserve=>256},options=>[]}} qw(alpha beta)];
my %live;
sub VisLlama::Catalog::load_router_presets { return $managed }
sub VisLlama::Router::router_http_engine {
    my ($eng,$method,$path,$body)=@_;
    if ($method eq 'POST') { $live{$body->{model}}='loaded'; return {} }
    return {data=>[map {{id=>$_,status=>{value=>$live{$_}||'unloaded'}}} qw(alpha beta)]};
}
my $engine={build=>'test',preset_file=>$ini_path};
my $first=&VisLlama::Router::load_router_model_centrally('alpha',$engine);
$device_output = "CUDA1: First, 280 MiB free\nCUDA0: Second, 300 MiB free\n";
my $second=&VisLlama::Router::load_router_model_centrally('beta',$engine);
die 'Second model reused the first calculated split after VRAM changed' unless
    $first->{gpu_priority_plan}{weights_mib}[0] > $second->{gpu_priority_plan}{weights_mib}[0] &&
    $first->{gpu_priority_plan}{weights_mib}[1] < $second->{gpu_priority_plan}{weights_mib}[1];

# This synthetic GGUF uses metadata dimensions whose 262144-token q8_0
# KV estimate is 8704 MiB, matching the large-context failure reported by
# llama.cpp. The user's floor must not replace the larger calculated need.
my ($meta_fh,$gguf_file) = tempfile(SUFFIX=>'.gguf',UNLINK=>1);
binmode($meta_fh);
my @meta=(
    ['general.architecture',8,'llama'],
    ['llama.block_count',4,32],
    ['llama.embedding_length',4,4096],
    ['llama.attention.head_count',4,32],
    ['llama.attention.head_count_kv',4,4],
    ['llama.attention.key_length',4,128],
    ['llama.attention.value_length',4,128],
    ['llama.context_length',4,262144],
);
print $meta_fh 'GGUF',pack('V',3),pack('Q<',0),pack('Q<',scalar @meta);
for my $entry (@meta) {
    my ($key,$type,$value)=@$entry;
    print $meta_fh pack('Q<',length($key)),$key,pack('V',$type);
    print $meta_fh $type == 8 ? pack('Q<',length($value)).$value : pack('V',$value);
}
truncate $meta_fh,128*1048576 or die $!;
close $meta_fh;
my $kv = &VisLlama::GPUPlanner::estimated_kv_mib($gguf_file,{ctx=>262144,cacheK=>'q8_0',cacheV=>'q8_0'});
die 'GGUF metadata KV estimate is wrong' unless $kv && $kv->{mib} == 8704;
$device_output="CUDA1: First, 10800 MiB free\nCUDA0: Second, 30000 MiB free\n";
my $dynamic=&VisLlama::GPUPlanner::gpu_plan_for_mode('test',$gguf_file,['CUDA1','CUDA0'],2048,'priority_split',
    {ctx=>262144,cacheK=>'q8_0',cacheV=>'q8_0'});
die 'Calculated split ignored large KV cache and minimum reserve' unless
    $dynamic->{kv_estimate_mib} == 8704 &&
    $dynamic->{effective_reserves_mib}[0] > 2048 &&
    $dynamic->{weights_mib}[0] < 10800-2048;
my $short=&VisLlama::GPUPlanner::gpu_plan_for_mode('test',$gguf_file,['CUDA1','CUDA0'],2048,'priority_split',
    {ctx=>32768,cacheK=>'q8_0',cacheV=>'q8_0'});
die 'Smaller context should reduce the calculated KV allowance' unless
    $short->{kv_estimate_mib} == 1088 && $short->{effective_reserves_mib}[0] < $dynamic->{effective_reserves_mib}[0];
my $floor=&VisLlama::GPUPlanner::gpu_plan_for_mode('test',$gguf_file,['CUDA1','CUDA0'],12288,'priority_split',
    {ctx=>262144,cacheK=>'q8_0',cacheV=>'q8_0'});
die 'Minimum reserve floor was not honored' unless
    $floor->{devices}[0] eq 'CUDA0' && $floor->{effective_reserves_mib}[0] >= 12288;
# Hybrid fixtures use the GGUF fields consumed by llama.cpp b11223, not the
# filename/alias. A sparse file supplies a realistic weight size without a GPU.
sub hybrid_fixture {
    my ($overrides,$remove,$arch,$tensors) = @_;
    $arch ||= 'qwen35';
    my %fields=(block_count=>65,embedding_length=>5120,
        'attention.head_count'=>24,'attention.head_count_kv'=>4,
        'attention.key_length'=>256,'attention.value_length'=>256,
        context_length=>262144,full_attention_interval=>4,nextn_predict_layers=>1,
        'ssm.conv_kernel'=>4,'ssm.inner_size'=>6144,'ssm.state_size'=>128,'ssm.group_count'=>16,
        %{$overrides||{}});
    delete @fields{@{$remove||[]}};
    my @entries=(['general.architecture',8,$arch],map {["$arch.$_",ref($fields{$_}) ? 9 : 4,$fields{$_}]} sort keys %fields);
    my ($fh,$file)=tempfile(SUFFIX=>'.gguf',UNLINK=>1);
    binmode($fh);
    print $fh 'GGUF',pack('V',3),pack('Q<',scalar @{$tensors||[]}),pack('Q<',scalar @entries);
    for my $e (@entries) {
        my ($key,$type,$v)=@$e;
        print $fh pack('Q<',length($key)),$key,pack('V',$type);
        if ($type==8) { print $fh pack('Q<',length($v)),$v; }
        elsif ($type==9) { print $fh pack('V',7),pack('Q<',scalar @$v),pack('C*',@$v); }
        else { print $fh pack('V',$v); }
    }
    if ($tensors) {
        my $offset=0;
        for my $t (@$tensors) {
            my ($name,$mib)=@$t;
            print $fh pack('Q<',length($name)),$name,pack('V',1),pack('Q<',32),pack('V',8),pack('Q<',$offset);
            $offset+=int($mib*1048576);
        }
        truncate $fh,int((tell($fh)+31)/32)*32+$offset or die $!;
    } else { truncate $fh,27*1024*1048576 or die $!; }
    close $fh;
    return $file;
}
my $hybrid_file=hybrid_fixture();
my $hybrid_settings={ctx=>262144,cacheK=>'q8_0',cacheV=>'q4_0',parallel=>1,specType=>'draft-mtp',draftTokens=>4};
my $hybrid=VisLlama::GPUPlanner::estimated_kv_mib($hybrid_file,$hybrid_settings);
die 'Hybrid full-attention KV must be 6656 MiB, not all 65 blocks' unless
    $hybrid->{mib}==6656 && $hybrid->{full_attention_layers}==16 && $hybrid->{recurrent_layers}==48;
die 'Hybrid recurrent state/rollback or MTP cache omitted' unless
    $hybrid->{recurrent_mib}==748.125 && $hybrid->{mtp_mib}==1024;
my $without_mtp=VisLlama::GPUPlanner::estimated_kv_mib($hybrid_file,{%$hybrid_settings,specType=>'none'});
die 'Inactive MTP must not allocate draft cache or rollback snapshots' unless
    $without_mtp->{mib}==6656 && $without_mtp->{mtp_mib}==0 && $without_mtp->{recurrent_mib}==149.625;
my $parallel_kv=VisLlama::GPUPlanner::estimated_kv_mib($hybrid_file,{%$hybrid_settings,parallel=>4});
die 'Recurrent state must scale with slots, not context length' unless
    $parallel_kv->{recurrent_mib}==4*$hybrid->{recurrent_mib} && $parallel_kv->{mib}==$hybrid->{mib};
my $short_hybrid=VisLlama::GPUPlanner::estimated_kv_mib($hybrid_file,{%$hybrid_settings,ctx=>32768});
die 'Context must scale attention/MTP caches without scaling recurrent state' unless
    $short_hybrid->{mib}==832 && $short_hybrid->{mtp_mib}==128 && $short_hybrid->{recurrent_mib}==$hybrid->{recurrent_mib};
my $default_draft=VisLlama::GPUPlanner::estimated_kv_mib($hybrid_file,{%$hybrid_settings,draftTokens=>''});
die 'Unset draft token count should retain b11223 rollback default' unless $default_draft->{recurrent_mib}==598.5;
my $cpu_cache=VisLlama::GPUPlanner::estimated_kv_mib($hybrid_file,{%$hybrid_settings,noKvOffload=>1});
die 'CPU cache must not consume planned GPU cache memory' unless $cpu_cache->{mib}==0;

# An explicit recurrent map takes precedence, including non-periodic layouts.
my @map=map { $_ < 64 && ($_+1)%4 ? 1 : 0 } 0..64;
$map[0]=0;
my $mapped=VisLlama::GPUPlanner::estimated_kv_mib(hybrid_fixture({'attention.recurrent_layers'=>\@map,full_attention_interval=>8}),$hybrid_settings);
die 'Explicit recurrent map was ignored or MTP counted as trunk' unless
    $mapped->{full_attention_layers}==17 && $mapped->{recurrent_layers}==47 && $mapped->{mib}==7072;
my $default_interval=VisLlama::GPUPlanner::estimated_kv_mib(hybrid_fixture({},['full_attention_interval']),$hybrid_settings);
die 'Qwen35 default attention interval differs from llama.cpp' unless $default_interval->{mib}==6656;
my $no_nextn=VisLlama::GPUPlanner::estimated_kv_mib(hybrid_fixture({block_count=>64},['nextn_predict_layers']),{%$hybrid_settings,specType=>'none'});
die 'Non-MTP GGUF layout changed attention count' unless $no_nextn->{mib}==6656 && $no_nextn->{mtp_mib}==0;
my $moe=VisLlama::GPUPlanner::estimated_kv_mib(hybrid_fixture({},[],'qwen35moe'),$hybrid_settings);
die 'Qwen35 MoE must follow the same hybrid layout rules' unless $moe->{mib}==6656;
for my $file (hybrid_fixture({},['ssm.inner_size']),hybrid_fixture({'attention.recurrent_layers'=>[1,0]}),
              hybrid_fixture({full_attention_interval=>0}),hybrid_fixture({nextn_predict_layers=>65}),
              hybrid_fixture({'attention.recurrent_layers'=>[(2)x65]})) {
    my $fallback=VisLlama::GPUPlanner::estimated_kv_mib($file,$hybrid_settings);
    die 'Incomplete hybrid metadata silently reduced the memory budget' unless
        $fallback && $fallback->{mib}==27040 && $fallback->{note}=~/conservative all-layer/;
}

# Regression for two 32 GiB GPUs: prefer the first GPU, but retain room for
# main KV, recurrent snapshots, MTP and compute. Re-query free VRAM each time.
$device_output="CUDA3: First, 32768 MiB free\nCUDA0: Second, 32768 MiB free\n";
my $hybrid_plan=VisLlama::GPUPlanner::gpu_plan_for_mode('test',$hybrid_file,['CUDA3','CUDA0'],256,'priority_split',$hybrid_settings);
die 'Corrected hybrid plan still spreads about half the weights to each GPU' unless
    $hybrid_plan->{weights_mib}[0]>22000 && $hybrid_plan->{weights_mib}[1]<8000 &&
    $hybrid_plan->{kv_estimate_mib}==6656 && $hybrid_plan->{recurrent_estimate_mib}==749 &&
    $hybrid_plan->{mtp_cache_allowance_mib}==1024 && join(',',@{$hybrid_plan->{args}})=~/--fit,off$/;
$device_output="CUDA3: First, 20000 MiB free\nCUDA0: Second, 32768 MiB free\n";
my $pressure=VisLlama::GPUPlanner::gpu_plan_for_mode('test',$hybrid_file,['CUDA3','CUDA0'],256,'priority_split',$hybrid_settings);
die 'Hybrid plan reused a stale VRAM snapshot' unless $pressure->{weights_mib}[0]<$hybrid_plan->{weights_mib}[0];
$device_output="CUDA3: First, 1000 MiB free\nCUDA0: Second, 1000 MiB free\n";
eval { VisLlama::GPUPlanner::gpu_plan_for_mode('test',$hybrid_file,['CUDA3','CUDA0'],256,'priority_split',$hybrid_settings) };
die 'Insufficient hybrid memory was accepted' unless $@;
print "GPU priority planner checks passed (dense and hybrid)\n";

# Real GGUF directory traversal plus a representative 64+1-layer layout. The
# sparse weights approximate the user's allocation log; no GPU is simulated as
# actually loading them. Check the same upper_bound split rule as model.cpp.
my @tensors=(['token_embd.weight',1288.28],['output.weight',1288.28],['output_norm.weight',0.02],
    (map { ["blk.$_.attn_norm.weight",385.85] } 0..63),['blk.64.nextn.eh_proj.weight',420]);
my $layer_file=hybrid_fixture({},[],'qwen35',\@tensors);
my $layer_settings={%$hybrid_settings,flash=>1,batch=>256,ubatch=>32};
$device_output="CUDA3: First, 32334 MiB free\nCUDA0: Second, 32305 MiB free\n";
my $exact=VisLlama::GPUPlanner::gpu_plan_for_mode('test',$layer_file,['CUDA3','CUDA0'],256,'priority_split',$layer_settings);
die 'Tensor directory failed to activate layer-aware placement' unless $exact->{layer_counts} && $exact->{note}=~/Layer-aware/;
die 'Layer-aware plan did not improve first GPU fill' unless $exact->{layer_counts}[0]>=58 && $exact->{weights_mib}[0]>22551;
die 'MTP compute still charged to every GPU' unless join(',',@{$exact->{compute_allowance_mib}}) eq '2048,3072';
my $first_layers=$exact->{layer_counts}[0];
my $first_attention=int($first_layers/4);
my $first_recurrent=$first_layers-$first_attention;
die 'Main cache does not follow actual layer boundaries' unless $exact->{cache_mib}[0]==int($first_attention*416+$first_recurrent*748.125/48+0.999);
die 'MTP cache was duplicated across GPUs' unless abs($exact->{cache_mib}[0]+$exact->{cache_mib}[1]-(6656+748.125+1024))<2;
for my $i (0..1) { die 'Layer plan exceeds current VRAM' if $exact->{weights_mib}[$i]+$exact->{effective_reserves_mib}[$i]>(32334,32305)[$i]; }
my %args=@{$exact->{args}};
die 'Layer plan must explicitly offload all layers and disable fitting' unless $args{'--gpu-layers'} eq '999' && $args{'--fit'} eq 'off';
my @ratios=split /,/,$args{'--tensor-split'};
my $total=0; $total+=$_ for @ratios;
my @assigned=(0)x@ratios;
for my $layer (0..65) {
    # Round to the float precision used by llama.cpp's boundary comparison.
    my $x=unpack('f',pack('f',$layer/66));my $sum=0;
    for my $gpu (0..$#ratios) {
        $sum+=$ratios[$gpu];
        if ($x < unpack('f',pack('f',$sum/$total))) { $assigned[$gpu]++; last; }
    }
}
die 'Tensor split does not reproduce the chosen whole-layer boundaries' unless join(',',@assigned) eq join(',',@{$exact->{layer_counts}});
my $again=VisLlama::GPUPlanner::gpu_plan_for_mode('test',$layer_file,['CUDA3','CUDA0'],256,'priority_split',$layer_settings);
die 'Cached metadata changed the plan' unless join(',',@{$again->{args}}) eq join(',',@{$exact->{args}});
$device_output="CUDA3: First, 20000 MiB free\nCUDA0: Second, 32305 MiB free\n";
my $layer_tight=VisLlama::GPUPlanner::gpu_plan_for_mode('test',$layer_file,['CUDA3','CUDA0'],256,'priority_split',$layer_settings);
die 'Layer-aware plan reused stale free VRAM' unless $layer_tight->{layer_counts}[0]<$first_layers;
$device_output="CUDA3: First, 65536 MiB free\nCUDA0: Second, 32305 MiB free\n";
my $layer_single=VisLlama::GPUPlanner::gpu_plan_for_mode('test',$layer_file,['CUDA3','CUDA0'],256,'priority_split',$layer_settings);
die 'Unneeded GPU not omitted' unless @{$layer_single->{devices}}==1 && !grep { $_ eq '--tensor-split' } @{$layer_single->{args}};
my @tied=grep { $_->[0] ne 'output.weight' } @tensors;
my $tied=VisLlama::GPUPlanner::gpu_plan_for_mode('test',hybrid_fixture({},[],'qwen35',\@tied),['CUDA3','CUDA0'],256,'priority_split',$layer_settings);
die 'Tied GPU output copy not counted' unless abs($tied->{weights_mib}[0]-$layer_single->{weights_mib}[0])<=1;
my $unknown=VisLlama::GPUPlanner::gpu_plan_for_mode('test',hybrid_fixture({},[],'qwen35',[@tensors,['unexpected.weight',1]]),['CUDA3','CUDA0'],256,'priority_split',$layer_settings);
die 'Unknown tensor roles did not fall back visibly' unless !$unknown->{layer_counts} && $unknown->{note}=~/fallback/;
my $inactive=VisLlama::GPUPlanner::gpu_plan_for_mode('test',$layer_file,['CUDA3','CUDA0'],256,'priority_split',{%$layer_settings,specType=>'none'});
die 'Disabled MTP still budgets its weights/cache' unless $inactive->{weights_mib}[0]<$layer_single->{weights_mib}[0] && $inactive->{mtp_cache_allowance_mib}==0;
my $large=VisLlama::GPUPlanner::gpu_plan_for_mode('test',$layer_file,['CUDA3','CUDA0'],256,'priority_split',{%$layer_settings,ubatch=>4096});
die 'Large graphs inherited the small-graph compute allowance' unless $large->{compute_allowance_mib}[0]==4096;
print "Layer-aware checks passed: tensor headers, float boundaries, KV/RS/MTP ownership, tied output, fallbacks and fresh VRAM\n";
