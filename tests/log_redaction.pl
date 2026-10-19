# Full log usefulness and privacy are separate assertions: never satisfy privacy
# by dropping the messages administrators need to diagnose inference failures.
use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use VisLlama::Errors ();
use VisLlama::API::Diagnostics ();
use VisLlama::Context qw($STATE);
my $normal=join("\n",
 '===== CUDA build b10819 =====',
 '47.37.644.677 I srv proxy_reques: proxying request to model Qwen-27B-Q8 on port 62214',
 '47.37.646.612 I load_tensors: offloading 42 repeating layers to GPU',
 '47.37.649.120 I CUDA0 model buffer size = 24576.00 MiB',
 '47.37.650.120 I llama_kv_cache: CUDA1 KV buffer size = 4096.00 MiB',
 '47.37.651.120 E ggml_backend_cuda_buffer_type_alloc_buffer: allocating 8192 MiB on device 1: out of memory',
 '47.37.652.120 W context: requested n_ctx = 65536, trained context = 32768',
 '47.37.653.120 I sampler: top_k = 40, top_p = 0.950, temp = 0.800',
 '47.37.654.120 I slot print_timing: prompt eval time = 1042.22 ms / 8192 tokens (7860.14 tokens per second)',
 '47.37.655.120 I unknown_future_component: useful diagnostic not known to VisLlama',
 'request path="/v1/chat/completions" status=200',
 'GET /v1/models?reload=1 HTTP 200; endpoint http://127.0.0.1:8080/v1/chat/completions',
 '47.37.656.120 E CUDA error: out of memory',
 '47.37.656.120 E CUDA error: out of memory','');
is(VisLlama::Errors::browser_log($normal),$normal,'Timestamps, severity, model/GPU details, warnings, timings, unknown and repeated lines are unchanged');
my @cases=(
 ['Authorization: Bearer PRIVATE_AUTH','PRIVATE_AUTH',qr/Authorization: \[redacted\]/],
 ['{"Authorization":"Basic PRIVATE_BASIC","status":401}','PRIVATE_BASIC',qr/"status":401/],
 ['Cookie: session=PRIVATE_COOKIE; other=SECRET','PRIVATE_COOKIE|SECRET',qr/Cookie: \[redacted\]/],
 ['Set-Cookie: session=PRIVATE_SET; HttpOnly','PRIVATE_SET',qr/Set-Cookie:/],
 ['--api-key="PRIVATE_EQUALS" --ctx-size 8192','PRIVATE_EQUALS',qr/--ctx-size 8192/],
 ['$env:LLAMA_API_KEY="PRIVATE_ENV"; loading model','PRIVATE_ENV',qr/loading model/],
 ['--api-key PRIVATE_CLI --ctx-size 8192','PRIVATE_CLI',qr/--ctx-size 8192/],
 [q{'--api-key' 'PRIVATE_QUOTED' '--parallel' '2'},'PRIVATE_QUOTED',qr/'--parallel' '2'/],
 ['{"api_key":"PRIVATE_JSON","n_ctx":8192}','PRIVATE_JSON',qr/"n_ctx":8192/],
 ['{"api_keys":["PRIVATE_ARRAY1","PRIVATE_ARRAY2"],"n_ctx":8192}','PRIVATE_ARRAY1|PRIVATE_ARRAY2',qr/"n_ctx":8192/],
 ['--api-key PRIVATE_MULTI1,PRIVATE_MULTI2 --ctx-size 8192','PRIVATE_MULTI1|PRIVATE_MULTI2',qr/--ctx-size 8192/],
 ['from /srv/private folder/model/Qwen.gguf: wrong tensor count','private folder',qr/Qwen\.gguf.*wrong tensor count/],
 ['control_token=PRIVATE_CONTROL; n_batch=512','PRIVATE_CONTROL',qr/n_batch=512/],
 ['https://user:PRIVATE_PASS@example.test/v1?api_key=PRIVATE_QUERY&stream=true','PRIVATE_PASS|PRIVATE_QUERY',qr/stream=true/],
 ['from "C:\Users\Private Person\models\Qwen-27B.gguf": invalid tensor size','Private Person',qr/Qwen-27B\.gguf.*invalid tensor size/],
 ['from D:/Private Models/Qwen-27B.gguf: invalid tensor size','Private Models',qr/Qwen-27B\.gguf.*invalid tensor size/],
 ['Cannot read /srv/private-user/presets/router.json: Permission denied','private-user',qr/Cannot read.*Permission denied/],
 ['Cannot open settings at C:\Private User\VisLlama\lib\Config.pm line 42.','Config\.pm|line 42|Private User',qr/Cannot open settings/],
 ['open failed at lib/VisLlama/Config.pm line 23, <GEN1> line 4.','Config\.pm|line 23|GEN1',qr/open failed/],
 ['VisLlama::Config::read_file("PRIVATE_STACK_ARG") called at /srv/private/App.pm line 18','PRIVATE_STACK_ARG|App\.pm|VisLlama::',qr/internal stack frame/],
 ['key hf_abcdefghijklmnopqrstuvwxyz123456 and ready','hf_abcdefghijklmnopqrstuvwxyz123456',qr/and ready/],
 ["-----BEGIN PRIVATE KEY-----\nPRIVATE_PEM\n-----END PRIVATE KEY-----\nRouter ready",'PRIVATE_PEM',qr/Router ready/],
);
for my $c (@cases) {
 my $out=VisLlama::Errors::browser_log($c->[0]);
 unlike($out,qr/$c->[1]/,'Sensitive portion removed');
 like($out,$c->[2],'Useful surrounding diagnostic retained');
}
{
 local $STATE->{router_control_token}='PRIVATE_KNOWN_CONTROL';
 is(VisLlama::Errors::browser_log('unexpected PRIVATE_KNOWN_CONTROL message'),'unexpected [redacted] message','Known controller secret is removed even without a label');
}
my $dir=tempdir(DIR=>$RealBin,CLEANUP=>1);
my $file="$dir/engine.log";
my $original=$normal."ERROR token=PRIVATE_ENDPOINT native allocation failed for model Qwen-27B-Q8\n";
open my $fh,'>:raw',$file or die $!;print {$fh} $original;close $fh;
{
 no warnings 'redefine';local *VisLlama::Errors::log_dir=sub {$dir};
 local $STATE->{mode}='single';local $STATE->{proc}=undef;local $STATE->{log_file}=$file;
 local $STATE->{log_clear_offset}=0;local $STATE->{last_error}=undef;
 for (1..2) {
  my $wire='';open my $sock,'>',\$wire or die $!;
  VisLlama::API::Diagnostics::handle($sock,'/api/status',{});close $sock;
  my (undef,$body)=split /\r\n\r\n/,$wire,2;my $j=decode_json($body);
  like($j->{log_tail},qr/8192 MiB on device 1: out of memory/,'Status API serves useful native error text');
  like($j->{log_tail},qr/native allocation failed for model Qwen-27B-Q8/,'Status API keeps redacted error context');
  unlike($j->{log_tail},qr/PRIVATE_ENDPOINT|Safe activity summary|Reference: VL-/,'No credential or summary substitution in log tail');
 }
 is(scalar(glob("$dir/diagnostics-*.jsonl")),undef,'Polling logs does not generate reference records for every error line');
}
open $fh,'<:raw',$file or die $!;local $/;my $disk=<$fh>;close $fh;
is($disk,$original,'Server-side process log is unchanged');
done_testing;
