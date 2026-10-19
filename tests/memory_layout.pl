use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use VisLlama::MemoryLayout ();
use VisLlama::PlannerSettings ();
use VisLlama::GPUPlanner ();
use VisLlama::LayerPlanner ();
use VisLlama::API::Models ();
use VisLlama::Router ();
use VisLlama::Context qw(%CFG $STATE);

sub metadata {
    my ($arch,$more)=@_;
    my %m=('general.architecture'=>$arch,
        map {("$arch.$_"=>{block_count=>4,embedding_length=>1024,context_length=>8192,
            'attention.head_count'=>8,'attention.head_count_kv'=>2,'attention.key_length'=>128,
            'attention.value_length'=>128}->{$_})} qw(block_count embedding_length context_length attention.head_count attention.head_count_kv attention.key_length attention.value_length));
    $m{"$arch.$_"}=$more->{$_} for keys %{$more||{}};
    return \%m;
}
my $s={ctx=>1024,parallel=>1,cacheK=>'f16',cacheV=>'f16',batch=>256,ubatch=>32,flash=>1,_swa_profile=>1};
for my $a (qw(llama qwen2 qwen2moe qwen3 qwen3moe gemma phi3)) {
    my $p=VisLlama::MemoryLayout::estimate(metadata($a),$s);
    ok($p->{supported},"$a recognized");is($p->{mib},4,"$a standard KV bytes");
    is_deeply($p->{layer_cache_mib},[1,1,1,1],"$a per-layer ownership");
}
my $quant=VisLlama::MemoryLayout::estimate(metadata('llama'),{%$s,cacheK=>'q8_0',cacheV=>'q4_0'});
is($quant->{mib},1.625,'Quantization block overhead included');
my $round=VisLlama::MemoryLayout::estimate(metadata('llama'),{%$s,ctx=>1000,parallel=>3,kvUnified=>'off'});
is($round->{context},1536,'Per-slot context rounded to allocation boundary');
my $unified=VisLlama::MemoryLayout::estimate(metadata('llama'),{%$s,ctx=>1000,parallel=>3,kvUnified=>'on'});
is($unified->{context},1024,'Unified context is one padded pool');
my $slot=VisLlama::MemoryLayout::estimate(metadata('llama'),{%$s,ctx=>'',parallel=>4,kvUnifiedPerSlot=>2048});
is($slot->{context},8192,'Unset total context uses parallel times per-slot request');
my $pinned=VisLlama::MemoryLayout::estimate(metadata('llama'),{%$s,ctx=>1024,parallel=>4,kvUnifiedPerSlot=>2048});
is($pinned->{context},1024,'Explicit total context is not multiplied by slots');
my $zero=VisLlama::MemoryLayout::estimate(metadata('llama'),{%$s,ctx=>'0',parallel=>4,kvUnifiedPerSlot=>16384});
is($zero->{context},8192,'Explicit zero selects training context instead of per-slot sizing');
my $var=metadata('llama',{'attention.head_count_kv'=>[1,2,1,2]});
is(VisLlama::MemoryLayout::estimate($var,$s)->{mib},3,'Variable KV heads with flash');
is(VisLlama::MemoryLayout::estimate($var,{%$s,flash=>0})->{mib},3.5,'Non-flash V rows padded to widest layer');
my $dimensions=metadata('llama',{'attention.key_length'=>[128,64,128,64],'attention.value_length'=>[64,128,64,128]});
is(VisLlama::MemoryLayout::estimate($dimensions,$s)->{mib},3,'Per-layer key/value dimensions');

my $g3=metadata('gemma3',{block_count=>6,'attention.sliding_window'=>1024});
my $sw={%$s,ctx=>8192,parallel=>2,ubatch=>128,kvUnified=>'off'};
my $gp=VisLlama::MemoryLayout::estimate($g3,$sw);
is_deeply($gp->{layer_cache_mib},[2.5,2.5,2.5,2.5,2.5,8],'SWA includes window, ubatch, 256 padding and streams');
is(VisLlama::MemoryLayout::estimate($g3,{%$sw,kvUnified=>'on'})->{mib},19.25,'Unified SWA window scales with slots before padding');
is(VisLlama::MemoryLayout::estimate($g3,{%$sw,swaFull=>1})->{mib},48,'swa-full budgets full cache for every layer');
my $unknown_build=VisLlama::MemoryLayout::estimate($g3,{%$sw,_swa_profile=>0});
is($unknown_build->{mib},48,'Unknown engine uses full-context upper budget');like($unknown_build->{note},qr/unverified/,'Unknown SWA engine disclosed');
my $g2=VisLlama::MemoryLayout::estimate(metadata('gemma2'),{%$s,ctx=>8192,ubatch=>256});
is_deeply($g2->{layer_cache_mib},[4.25,8,4.25,8],'Gemma2 alternating pattern and default 4096 window');
my $explicit=VisLlama::MemoryLayout::estimate(metadata('gemma3',{block_count=>4,'attention.sliding_window'=>1024,'attention.sliding_window_pattern'=>[0,1,0,1]}),{%$s,ctx=>8192,ubatch=>256});
is_deeply($explicit->{layer_cache_mib},[8,1.25,8,1.25],'Explicit SWA map overrides repeating default');
is(VisLlama::MemoryLayout::estimate(metadata('phi3',{'attention.sliding_window'=>1024}),{%$s,ctx=>8192})->{mib},32,'Phi loader receives no unverified SWA savings');

my $state=(3*(64+2*2*16)+16*64)*4/1048576;
for my $a (qw(qwen35 qwen35moe qwen3next)) {
    my $m=metadata($a,{block_count=>5,nextn_predict_layers=>1,'ssm.conv_kernel'=>4,'ssm.inner_size'=>64,'ssm.state_size'=>16,'ssm.group_count'=>2});
    my $p=VisLlama::MemoryLayout::estimate($m,{%$s,specType=>'draft-mtp',draftTokens=>4});
    is($p->{mib},1,"$a one full-attention main layer");
    is($p->{recurrent_mib},3*$state*5,"$a rollback state included");
    is($p->{mtp_mib},1,"$a separate default F16 MTP cache");
    is(VisLlama::MemoryLayout::estimate($m,{%$s,specType=>'draft-mtp',draftTypeK=>'q8_0',draftTypeV=>'q4_0'})->{mtp_mib},0.40625,"$a configured draft cache types");
}
my $j=metadata('jamba',{'attention.head_count_kv'=>[0,2,0,2],'ssm.conv_kernel'=>4,'ssm.inner_size'=>2048,'ssm.state_size'=>16});
my $jp=VisLlama::MemoryLayout::estimate($j,$s);
is($jp->{mib},2,'Jamba heads distinguish attention and Mamba');
is($jp->{recurrent_mib},2*(3*2048+16*2048)*4/1048576,'Jamba group count defaults to zero');
for my $a (qw(nemotron_h nemotron_h_moe)) {
    my $m=metadata($a,{'attention.head_count_kv'=>[0,2,0,0],feed_forward_length=>[0,0,4096,0],'ssm.conv_kernel'=>4,'ssm.inner_size'=>64,'ssm.state_size'=>16,'ssm.group_count'=>2});
    my $p=VisLlama::MemoryLayout::estimate($m,$s);
    is_deeply($p->{layer_kinds},['recurrent','attention','feed-forward','recurrent'],"$a separates feed-forward-only layers");
    is($p->{recurrent_mib},2*$state,"$a recurrent state bytes");
}
my $cpu=VisLlama::MemoryLayout::estimate($j,{%$s,noKvOffload=>1});
is($cpu->{mib},0,'CPU KV not charged to GPUs');is($cpu->{recurrent_mib},0,'CPU recurrent state not charged to GPUs');
is($cpu->{cpu_cache_mib},$jp->{mib}+$jp->{recurrent_mib},'CPU cache still reported');
for my $m (metadata('future'),metadata('gemma3',{'attention.sliding_window_pattern'=>[1,0],'attention.sliding_window'=>1024}),metadata('jamba',{'attention.head_count_kv'=>[0,2,0,2]}),metadata('llama',{'attention.key_length'=>33})) {
    ok(!VisLlama::MemoryLayout::estimate($m,{%$s,cacheK=>'q4_0'})->{supported},'Unknown/malformed geometry is not treated as reviewed');
}

# Effective options, not a contradictory UI snapshot, govern all calculations.
my $resolved=VisLlama::PlannerSettings::from_args({ctx=>999999,parallel=>99,swaFull=>1,cpuMoe=>1,extra=>'stale'},
    ['--ctx-size','2048','--cache-type-k=q8_0','--ctx-size','4096','--parallel','2','--no-kv-unified','--spec-draft-type-v','q4_0','--flash-attn','off'], '',11223);
is($resolved->{ctx},4096,'Last effective option wins');is($resolved->{parallel},2,'CLI slots authoritative');
ok(!$resolved->{cpuMoe} && !$resolved->{swaFull},'Omitted booleans cannot inherit stale UI values');
is($resolved->{cacheK},'q8_0','Equals syntax normalized');is($resolved->{draftTypeV},'q4_0','Draft type normalized');ok(!$resolved->{flash},'Explicit FA off');
my $auto=VisLlama::PlannerSettings::from_args({},['--no-kv-unified'],'',11223);
is($auto->{parallel},4,'Known server auto slots');is($auto->{kvUnified},'on','Auto slots force unified cache, matching engine');
my $help="  --parallel N  number of slots (default: 2)\n  --ubatch-size N  physical batch (default: 128)\n  --batch-size N  logical batch (default: 512)\n  --ctx-size N  context (default: 4096)\n  --cache-type-k TYPE  key cache type (default: q8_0)\n";
my $defaults=VisLlama::PlannerSettings::from_args({},[],$help,9999);
is($defaults->{parallel},2,'Selected build help supplies slot default');
is($defaults->{ubatch},128,'Selected build help supplies ubatch default');
is($defaults->{ctx},4096,'Selected build help supplies nonzero context default');
is($defaults->{kvUnified},'off','Positive slot default does not force unified KV');
is($defaults->{cacheK},'q8_0','Selected build cache-type default is used');
ok(VisLlama::PlannerSettings::from_args({},['--override-tensor','x=CPU'],'',11223)->{_unsupported},'Arbitrary tensor overrides guarded');
ok(VisLlama::PlannerSettings::from_args({},['--model-draft','other.gguf'],'',11223)->{_unsupported},'Separate draft residency guarded');
is_deeply(VisLlama::PlannerSettings::option_args([['parallel','4'],['no-kv-offload','true']]),['--parallel','4','--no-kv-offload','true'],'Catalog uses same argument resolver');

# Stored expert tensors count in full, including shared experts. Active expert
# count alone is not a VRAM multiplier; CPU expert overrides match native regex.
my $moe_meta=metadata('qwen3moe');
$moe_meta->{_tensor_mib}={'token_embd.weight'=>1,'output.weight'=>1,
    map {("blk.$_.attn_norm.weight"=>1,"blk.$_.ffn_gate_exps.weight"=>20,"blk.$_.ffn_gate_shexp.weight"=>2)} 0..3};
my $moe_kv=VisLlama::MemoryLayout::estimate($moe_meta,$s);
my $all=VisLlama::LayerPlanner::plan($moe_meta,$moe_kv,$s,['CUDA0'],[100000],256);
my $off=VisLlama::LayerPlanner::plan($moe_meta,$moe_kv,{%$s,cpuMoe=>1},['CUDA0'],[100000],256);
is($all->{weights_mib}[0],94,'All routed and shared expert weights included');
is($off->{weights_mib}[0],14,'CPU routed experts excluded but shared experts retained');
is($off->{cpu_weights_mib},81,'CPU embeddings and routed experts reported');
my $first=VisLlama::LayerPlanner::plan($moe_meta,$moe_kv,{%$s,nCpuMoe=>2},['CUDA0'],[100000],256);
is($first->{weights_mib}[0],54,'First N layers of CPU experts');

# Sparse sharded GGUF fixtures exercise the real header reader and aggregation.
my $dir=tempdir(CLEANUP=>1);
sub gguf {
    my ($path,$meta,$names)=@_;
    open my $f,'>:raw',$path or die $!;
    print $f 'GGUF',pack('VQ<Q<',3,scalar(@$names),scalar(keys %$meta));
    for my $key (sort keys %$meta) {
        my $v=$meta->{$key};my $type=ref($v) eq 'ARRAY'?9:$key eq 'general.architecture'?8:4;
        print $f pack('Q<',length $key),$key,pack('V',$type);
        if ($type==8) {print $f pack('Q<',length $v),$v}
        elsif ($type==9) {print $f pack('VQ<',4,scalar @$v),pack('V*',@$v)}
        else {print $f pack('V',$v)}
    }
    my $offset=0;
    for my $name (@$names) {print $f pack('Q<',length $name),$name,pack('VQ<VQ<',1,524288,1,$offset);$offset+=1048576}
    truncate $f,VisLlama::MemoryLayout::pad(tell($f),32)+$offset or die $!;close $f;
}
my $f1="$dir/test-00001-of-00002.gguf";my $f2="$dir/test-00002-of-00002.gguf";
gguf($f1,metadata('qwen3moe'),['token_embd.weight','blk.0.attn_norm.weight','blk.1.attn_norm.weight']);
gguf($f2,metadata('qwen3moe'),['output.weight','blk.2.attn_norm.weight','blk.3.attn_norm.weight']);
{
 no warnings 'redefine';
 local $CFG{builds}={test=>'mock'};
 local *VisLlama::Builds::find_server_exe=sub {'mock.exe'};
 local *VisLlama::Builds::planner_build_number=sub {11223};
 local *VisLlama::Util::capture_command=sub {$_[1] eq '--help'?'--tensor-split':'CUDA0: GPU, 32768 MiB free'};
 local *VisLlama::Builds::parse_devices=sub {[{id=>'CUDA0',description=>'32768 MiB free'}]};
 my $p=VisLlama::GPUPlanner::gpu_plan_for_mode('test',$f1,['CUDA0'],256,'priority_split',$s);
 is($p->{planning_quality},'layer_estimate','Sharded tensors use layer planner');is($p->{layer_counts}[0],5,'Shards form four blocks plus output');
 my $second=VisLlama::GPUPlanner::gpu_plan_for_mode('test',$f2,['CUDA0'],256,'priority_split',$s);
 is_deeply($second->{weights_mib},$p->{weights_mib},'Selection of a later shard still uses complete model');
 # Real preview/save/catalog/central-load paths receive deliberately stale UI
 # values. Their effective options must produce identical memory calculations.
 local $CFG{model_root}=$dir;
 local $STATE={};
 mkdir "$dir/presets" or die $!;
 local *VisLlama::Paths::presets_dir=sub {"$dir/presets"};
 local *VisLlama::Paths::canonical_under=sub {1};
 my $reply;
 local *VisLlama::HTTP::json_response=sub {$reply=$_[2]};
 local *VisLlama::HTTP::fail_json=sub {die 'API rejected integration fixture: '.($_[1]//'')};
 my $ui={%$s,ctx=>999999,cacheK=>'f32',noKvOffload=>0,gpuPriority=>'priority_split',gpuReserve=>256,devices=>['CUDA0']};
 my $launch=['--ctx-size 4096','--parallel','2','--cache-type-k','q8_0','--cache-type-v','q4_0','--no-kv-offload','--log-verbosity 4'];
 VisLlama::API::Models::handle(undef,'/api/gpu-priority-preview',{build=>'test',model=>$f1,mode=>'priority_split',devices=>['CUDA0'],reserve=>256,settings=>$ui,args=>$launch});
 my $preview=$reply->{plan};
 is($preview->{kv_estimate_mib},0,'Preview follows actual CPU cache option');
 is($preview->{cpu_cache_estimate_mib},7,'Preview uses actual context and cache types instead of UI');
 VisLlama::API::Models::handle(undef,'/api/router-preset-save',{alias=>'aligned',build=>'test',model=>$f1,ui=>$ui,args=>$launch});
 ok($reply->{ok},'Model saves through actual handler');
 is_deeply([grep {$_->[0] eq 'log-verbosity'} @{$reply->{presets}[0]{options}}],[['log-verbosity','4']],
     'Combined verbosity token saves as a valid INI pair through the actual handler');
 is_deeply($launch,['--ctx-size 4096','--parallel','2','--cache-type-k','q8_0','--cache-type-v','q4_0','--no-kv-offload','--log-verbosity 4'],
     'Request normalization does not mutate the caller argument list');
 local *VisLlama::Router::router_model_status=sub {'unloaded'};
 local *VisLlama::Router::wait_router_model_loaded=sub {1};
 my @requests;
 local *VisLlama::Router::router_http_engine=sub {push @requests,$_[2];return {}};
 my $loaded=VisLlama::Router::load_router_model_centrally('aligned',{build=>'test',preset_file=>"$dir/presets/router-models-test.ini"});
 is_deeply($loaded->{gpu_priority_plan},$preview,'Central loader re-creates preview from saved effective options');
 is_deeply(\@requests,['/v1/models?reload=1','/models/load'],'Calculated INI reload precedes native load');
 unlink $f2 or die $!;
 eval {VisLlama::GPUPlanner::gpu_plan_for_mode('test',$f1,['CUDA0'],256,'priority_split',$s)};
 like($@,qr/shard 2 of 2 is missing/,'Missing shard never becomes optimistic partial plan');
}
done_testing();
