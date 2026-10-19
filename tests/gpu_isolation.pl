# Simulate native processes while exercising real grouping, launcher generation,
# catalog remapping, live apply and cleanup. No Windows/CUDA execution is claimed.
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Temp qw(tempdir);
use File::Spec;
use JSON::PP qw(decode_json encode_json);
our (@created,@killed,%active);
BEGIN {
    $INC{'Win32.pm'}=__FILE__;$INC{'Win32/Process.pm'}=__FILE__;
    *CORE::GLOBAL::system=sub {die 'Unexpected command' unless $_[0] eq 'taskkill';push @killed,[@_];$active{$_[2]}=0;return 0};
}
{ package Win32::Process;
  sub import {} sub NORMAL_PRIORITY_CLASS {0x20} sub CREATE_NEW_PROCESS_GROUP {0x200}
  sub Create {my $pid=91000+@main::created;push @main::created,[@_[1..5]];$main::active{$pid}=1;$_[0]=bless {pid=>$pid},'IsolationProcess';1}
  package IsolationProcess;
  sub GetProcessID {$_[0]{pid}} sub GetExitCode {$_[1]=$main::active{$_[0]{pid}}?259:0;1}
}
use VisLlama::Platform ();
BEGIN { no warnings 'redefine'; *VisLlama::Platform::windows=sub {1}; }
use VisLlama::GPUIsolation ();
use VisLlama::Process ();
use VisLlama::Router ();
use VisLlama::Context qw(%CFG $STATE);
sub readfile {open my $f,'<',$_[0] or die $!;local $/;return <$f>}
my $root=tempdir(CLEANUP=>1);$root=File::Spec->rel2abs($root);
for my $file (qw(llama-server.exe llama_openai_proxy.pl model.gguf cudart64_12.dll)) {open my $f,'>',"$root/$file" or die $!;close $f}
my $map={CUDA0=>{uuid=>'GPU-aaaa'},CUDA1=>{uuid=>'GPU-bbbb'},CUDA2=>{uuid=>'GPU-cccc'},CUDA3=>{uuid=>'GPU-dddd'}};
{
 no warnings 'redefine';
 local *VisLlama::Errors::report=sub {'test-reference'};
 local $CFG{builds}={test=>$root};local $CFG{build_order}=['test'];local $CFG{model_root}=$root;
 local *VisLlama::Paths::app_base_dir=sub {$root};
 local *VisLlama::Paths::presets_dir=sub {mkdir "$root/presets" unless -d "$root/presets";"$root/presets"};
 local *VisLlama::Paths::canonical_under=sub {1};
 # Bus identity handles distinct enumeration orders, never matching by GPU name.
 {
  local *VisLlama::Util::capture_command_stdout=sub {'[{"id":"CUDA0","bus":"0000:0c:00.0","uuid":"GPU-aaaa"},{"id":"CUDA1","bus":"0000:43:00.0","uuid":"GPU-bbbb"}]'};
  local *VisLlama::Util::capture_command=sub {$?=0;$_[0] eq 'nvidia-smi.exe'?"GPU-bbbb, 00000000:43:00.0\nGPU-aaaa, 00000000:0C:00.0\n":"CUDA0: Same GPU (32 MiB free)\nCUDA1: Same GPU (32 MiB free)"};
  {local $ENV{GGML_CUDA_DEVICES}='1,0';eval {VisLlama::GPUIsolation::inventory('test')};like($@,qr/GGML_CUDA_DEVICES/,'Backend-specific ordinal overrides fail rather than misassign GPUs')}
  my $got=VisLlama::GPUIsolation::inventory('test');
  is($got->{CUDA0}{uuid},'GPU-aaaa','CUDA ordinal maps by PCI bus rather than nvidia-smi row');
  is($got->{CUDA1}{uuid},'GPU-bbbb','Identical GPU names remain unambiguous');
  for my $case (
   ['[{"id":"CUDA0","bus":"0000:0c:00.0","uuid":"GPU-aaaa"},{"id":"CUDA1","bus":"0000:0c:00.0","uuid":"GPU-aaaa"}]',qr/Multiple CUDA devices share/, 'Duplicate runtime bus fails rather than aliasing physical GPUs'],
   ['[{"id":"CUDA0","bus":"0000:0c:00.0","uuid":"GPU-ffff"}]',qr/UUID does not match/, 'MIG or mismatched UUID still fails closed'],
   ['{"error":"cuDeviceGetUuid_v2 for CUDA0 failed; CUDA error 999"}',qr/cuDeviceGetUuid_v2 for CUDA0 failed; CUDA error 999/, 'Structured helper failure remains actionable in private diagnostics'],
   ['not JSON',qr/CUDA runtime identity probe failed/, 'Malformed helper output fails cleanly']
  ) {
   local *VisLlama::Util::capture_command_stdout=sub {$?=0;return $case->[0]};
   eval {VisLlama::GPUIsolation::inventory('test')};my $error=$@;
   like($error,$case->[1],$case->[2]);
   my $public=VisLlama::Errors::public_error($error);
   unlike($public->{message},qr/cuDeviceGet|error 999|not JSON|GPU-ffff/, 'Probe details do not escape into public messages');
  }
  {
   local *VisLlama::Util::capture_command_stdout=sub {$?=256;return '[{"id":"CUDA0","bus":"0000:0c:00.0","uuid":"GPU-aaaa"}]'};
   eval {VisLlama::GPUIsolation::inventory('test')};
   like($@,qr/probe failed \(exit 256\)/,'Nonzero helper exit is rejected even with valid JSON');
  }
  local *VisLlama::Util::capture_command_stdout=sub {'[{"id":"CUDA0","bus":"0000:99:00.0"}]'};
  eval {VisLlama::GPUIsolation::inventory('test')};like($@,qr/GPU isolation could not be verified/,'Unmapped physical GPU fails closed');
 }
 local *VisLlama::GPUIsolation::inventory=sub {$map};
 local *VisLlama::Preflight::saved=sub{1}; # Separate fixtures cover static preflight.
 local *VisLlama::ModelStats::metrics_supported=sub {0};
 local *VisLlama::ModelStats::sample_running_model_stats=sub {};
 my $first={alias=>'first',build=>'test',model=>"$root/model.gguf",enabled=>1,load_on_startup=>1,
   ui=>{gpuPriority=>'priority_split',devices=>['CUDA3','CUDA0'],gpuReserve=>256},options=>[['device','CUDA3,CUDA0'],['spec-type','draft-mtp']]};
 my $second={alias=>'second',build=>'test',model=>"$root/model.gguf",enabled=>1,load_on_startup=>1,
   ui=>{gpuPriority=>'even',devices=>['CUDA1','CUDA2']},options=>[['device','CUDA1,CUDA2'],['split-mode','layer'],['tensor-split','1,1']]};
 my $third={%$second,alias=>'demand',load_on_startup=>0};
 my $draft={%$second,options=>[['device','CUDA3'],['spec-draft-device','CUDA2'],['main-gpu','0']]};
 my $profile=VisLlama::GPUIsolation::profile($draft,{});
 is_deeply($profile->{uuids},['GPU-dddd','GPU-cccc'],'Draft GPU included in restricted visibility');
 is_deeply(VisLlama::GPUIsolation::remap_options($draft->{options},$profile),[['device','CUDA0'],['spec-draft-device','CUDA1'],['main-gpu','0']],
   'Main/draft names remap while positional main-gpu stays unchanged');
 is_deeply($draft->{options},[['device','CUDA3'],['spec-draft-device','CUDA2'],['main-gpu','0']],'Saved options are not mutated');
 is(VisLlama::GPUIsolation::profile({build=>'test',ui=>{},options=>[['device','none']]},{})->{visible},'','CPU-only visibility is empty');
 ok(!defined VisLlama::GPUIsolation::profile({build=>'test',ui=>{},options=>[]},{}),'No device selection retains native behavior');
 my $orig_env=$ENV{CUDA_VISIBLE_DEVICES};
 my @events;
 local *VisLlama::GPUPlanner::gpu_plan_for_mode=sub {push @events,'plan';return {mode=>'priority_split',args=>['--device','CUDA0','--split-mode','layer','--tensor-split','1','--fit','off']}};
 local *VisLlama::Router::router_model_status=sub {'unloaded'};
 local *VisLlama::Router::wait_router_model_loaded=sub {push @events,'ready:'.$_[1];1};
 local *VisLlama::Router::router_http_engine=sub {push @events,($_[2] eq '/models/load'?'load:'.$_[3]{model}:$_[2]);return {data=>[]}};
 VisLlama::Config::write_json_file_ascii(VisLlama::Config::router_service_config_path(),{host=>'127.0.0.1',port=>18080,models_max=>4,autoload=>1});
 VisLlama::Catalog::save_router_presets([$first,$second,$third]);
 VisLlama::Process::start_router({});
 is(scalar(keys %{$STATE->{router_engines}}),2,'Same build with disjoint GPU selections launches two engines');
 my $a=VisLlama::Router::router_engine_for_model('first');my $b=VisLlama::Router::router_engine_for_model('second');
 is(VisLlama::Router::router_engine_for_model('demand')->{port},$b->{port},'Same selection shares engine');
 isnt($a->{port},$b->{port},'Groups have independent loopback endpoints');
 like(readfile($a->{launcher}),qr/\$env:CUDA_VISIBLE_DEVICES = 'GPU-dddd,GPU-aaaa'/,'First launcher masks to physical UUIDs in priority order');
 like(readfile($b->{launcher}),qr/\$env:CUDA_VISIBLE_DEVICES = 'GPU-bbbb,GPU-cccc'/,'Second launcher masks to its two GPUs');
 like(readfile($a->{preset_file}),qr/^device = CUDA1$/m,'Calculated subset translates global CUDA0 to group-local CUDA1');
 unlike(readfile($a->{preset_file}),qr/\[second\]/,'Calculated refresh cannot leak another group model into INI');
 like(readfile($b->{preset_file}),qr/^device = CUDA0,CUDA1$/m,'Even split uses local device names');
 like(readfile($b->{preset_file}),qr/^tensor-split = 1,1$/m,'Even weights survive remapping');
 is_deeply([grep {/^load:/} @events],['load:first','load:second'],'Startup follows catalog order across groups');
 my $route=decode_json(readfile($STATE->{router_route_map}));
 is($route->{models}{second}{port},$b->{port},'Public on-demand route targets correct visibility group');
 ok($route->{models}{first}{calculated},'Calculated on-demand handoff retained');
 ok(!$route->{models}{second}{calculated},'Even split retains native on-demand loading');
 is_deeply([map {$_->{build}} @{VisLlama::ProcessState::router_engines_payload()}],['test','test'],'Public build identity does not become internal group key');
 is($ENV{CUDA_VISIBLE_DEVICES},$orig_env,'Control process environment remains unchanged');
 my $alias_args=['-dev','CUDA3','--device-draft=CUDA2','-mmdev','CUDA2','--main-gpu','0'];
 my $alias_profile=VisLlama::GPUIsolation::profile({build=>'test',ui=>{},options=>VisLlama::GPUIsolation::options_from_args($alias_args)},{});
 is_deeply(VisLlama::GPUIsolation::remap_args($alias_args,$alias_profile),
     ['-dev','CUDA0','--device-draft=CUDA1','-mmdev','CUDA1','--main-gpu','0'],
     'Legacy draft/device aliases and projector GPU remap consistently');
 my $public=VisLlama::Errors::public_error('GPU isolation could not be verified: internal/private/path');
 unlike($public->{message},qr/internal|private|path/,'Identity failures keep details out of API response');
 my $applied=VisLlama::Router::apply_router_config_live(0);ok($applied->{applied},'Unchanged groups reload live');
 $third->{options}=[['device','CUDA0']];$third->{ui}{devices}=['CUDA0'];
 VisLlama::Catalog::save_router_presets([$first,$second,$third]);
 my $before=readfile($b->{preset_file});
 my $changed=VisLlama::Router::apply_router_config_live(0);
 ok($changed->{restart_required},'Changed visibility needs new process');
 is(readfile($b->{preset_file}),$before,'Rejected live regroup leaves running INI unchanged');
 eval {VisLlama::Router::load_router_model_centrally('demand',$b)};
 like($@,qr/GPU selection changed/,'Manual/central load cannot use stale visibility group');
 my @pids=map {$_->{pid}} values %{$STATE->{router_engines}};
 VisLlama::Process::stop_server();
 ok(!(grep {$active{$_}} @pids),'Stopping Router kills all group process trees');
 # Direct serving shares isolation but does not pass through INI validation:
 # ordinary short engine flags remain usable, and selected order is preserved.
 VisLlama::Process::start_server({build=>'test',model=>"$root/model.gguf",
     args=>['-c','4096','--device','CUDA2,CUDA0','--spec-draft-device','CUDA0','--main-gpu','1']});
 my ($direct_launcher)=$created[-1][1]=~/-File "([^"]+)"/;
 my $direct_text=readfile($direct_launcher);
 like($direct_text,qr/\$env:CUDA_VISIBLE_DEVICES = 'GPU-cccc,GPU-aaaa'/,'Direct launcher restricts physical visibility');
 like($direct_text,qr/'--device' 'CUDA0,CUDA1'/,'Direct selected device order maps to local names');
 like($direct_text,qr/'--spec-draft-device' 'CUDA1'/,'Direct draft GPU translates separately');
 like($direct_text,qr/'-c' '4096'/,'Direct short engine options remain literal');
 like($direct_text,qr/'--main-gpu' '1'/,'Direct positional main-gpu remains unchanged');
 VisLlama::Process::stop_server();
 # A late failure after engines were created must not abandon them.
 VisLlama::Catalog::save_router_presets([$first,$second]);
 my $write=\&VisLlama::Config::write_json_file_ascii;
 local *VisLlama::Config::write_json_file_ascii=sub {die 'Injected route-map failure' if $_[0]=~/openai-route-map/;goto &$write};
 eval {VisLlama::Process::start_router({})};like($@,qr/Injected route-map failure/,'Late startup failure reaches caller');
 ok(!(grep {$active{$_}} keys %active),'Partial startup cleanup kills every created process');
 ok(!$STATE->{starting_engines},'Partial ownership registry cleared');
}
done_testing();
