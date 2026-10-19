// Real HTTP and bounded native probe; model handles/build capabilities are fixtures.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),http=require('node:http'),net=require('node:net');
const {spawn}=require('node:child_process'),{once}=require('node:events');
const root=path.resolve(__dirname,'..'),temp=fs.mkdtempSync(path.join(__dirname,'.phase3-http-'));
for(const file of ['lib','templates','public','VisLlama.pl','llama_openai_proxy.pl'])fs.cpSync(path.join(root,file),path.join(temp,file),{recursive:true});
fs.mkdirSync(path.join(temp,'presets'));fs.mkdirSync(path.join(temp,'build'));
const model=path.join(temp,'model.gguf');fs.writeFileSync(model,'fixture');fs.writeFileSync(path.join(temp,process.platform==='win32'?'build/llama-server.exe':'build/llama-server'),'fixture',{mode:0o755});
fs.writeFileSync(path.join(temp,'presets/llama-builds.json'),JSON.stringify([{alias:'fixture',path:path.join(temp,'build')}]));
fs.writeFileSync(path.join(temp,'presets/model-root.json'),JSON.stringify({model_root:temp}));
let child,port,output='';
const request=(url,body={})=>new Promise((resolve,reject)=>{
 const data=JSON.stringify(body),req=http.request({host:'127.0.0.1',port,path:url,method:'POST',headers:{'Content-Type':'application/json','Content-Length':Buffer.byteLength(data)}},res=>{let text='';res.on('data',b=>text+=b);res.on('end',()=>{try{resolve({status:res.statusCode,body:JSON.parse(text)})}catch(e){reject(e)}})});
 req.on('error',reject);req.setTimeout(12000,()=>req.destroy(new Error('Fixture request timed out')));req.end(data);
});
const perl=String.raw`
our $alive=0;
BEGIN {*CORE::GLOBAL::system=sub {die 'unexpected native command' unless $_[0] eq 'taskkill';$main::alive=0;return 0;};}
use VisLlama::App;
{package FixtureHandle;sub GetExitCode {$_[1]=$main::alive?259:0;return 1}sub GetProcessID {90001}}
no warnings 'redefine';
*VisLlama::Paths::canonical_under=sub {index($_[0],$_[1].'/')==0};
*VisLlama::Builds::checked_probe=sub {'--model --ctx-size --fit --device'};
*VisLlama::Process::start_server=sub {
 my ($req)=@_;die 'Already running' if $alive;
 VisLlama::Lifecycle::rotate();$alive=1;
 my $state=$VisLlama::Context::STATE;$state->{proc}=bless {},'FixtureHandle';$state->{pid}=90001;$state->{mode}='single';
 VisLlama::Util::capture_command($^X,'-e','select undef,undef,undef,5') if $req->{slow_probe};
 return VisLlama::ProcessState::state_payload();
};
$VisLlama::Context::CFG{listen_port}=shift @ARGV;
exit VisLlama::App::run();`;
(async()=>{try{
 const server=net.createServer();server.listen(0,'127.0.0.1');await once(server,'listening');port=server.address().port;server.close();await once(server,'close');
 child=spawn(process.env.PERL||'perl',['-I',path.join(temp,'lib'),'-e',perl,String(port)],{cwd:temp});
 child.stdout.on('data',b=>output+=b);child.stderr.on('data',b=>output+=b);
 let status;for(let i=0;i<80;i++){try{status=await request('/api/status');break}catch{await new Promise(r=>setTimeout(r,50))}}
 assert(status,'Server startup: '+output);const initial=status.body.runtime_token;
 assert.equal((await request('/api/stop')).status,409,'Missing runtime identity rejected');
 let response=await request('/api/start',{mode:'single',build:'fixture',model:model+'.missing',runtime_token:initial});
 assert.equal(response.status,500);assert.equal((await request('/api/status')).body.running,false,'Failed preflight does not launch');
 response=await request('/api/start',{mode:'single',build:'fixture',model,args:[],runtime_token:initial});
 assert.equal(response.status,200);assert.equal(response.body.running,true);const running=response.body.runtime_token;assert.notEqual(running,initial);
 assert.equal((await request('/api/stop',{runtime_token:initial})).status,409,'Stale stop rejected');
 assert.equal((await request('/api/status')).body.running,true,'Stale stop leaves current process alive');
 const second=spawn(process.env.PERL||'perl',['-I',path.join(temp,'lib'),'-MVisLlama::App','-e','$VisLlama::Context::CFG{listen_port}=0;VisLlama::App::run()'],{cwd:temp});
 let secondError='';second.stderr.on('data',b=>secondError+=b);await once(second,'exit');assert.match(secondError,/Another VisLlama controller/,'Installation lock is independent of port');
 response=await request('/api/stop',{runtime_token:running});assert.equal(response.body.running,false);
 const action='cancel-fixture';let slowDone=false;
 const slow=request('/api/start',{mode:'single',build:'fixture',model,args:[],runtime_token:response.body.runtime_token,slow_probe:true,action_id:action}).then(r=>{slowDone=true;return r});
 await new Promise(r=>setTimeout(r,100));
 const started=performance.now();status=await request('/api/status');const latency=Math.round(performance.now()-started);
 assert.equal(status.body.active_operation.id,action,'Status served during active operation');assert.equal(slowDone,false,'Probe still pending when status returns');assert(latency<1500,'Status did not wait for the five-second probe');
 assert.equal((await request('/api/model-root-save',{root:temp})).status,409,'Competing mutation cannot reenter the planner');
 assert.equal((await request('/api/stop',{runtime_token:status.body.runtime_token,cancel_operation:'other'})).status,409,'Cancellation cannot target another operation');
 const cancelStarted=performance.now();response=await request('/api/stop',{runtime_token:status.body.runtime_token,cancel_operation:action});const cancelLatency=Math.round(performance.now()-cancelStarted);
 assert.equal(response.status,200);assert.equal(response.body.running,false);
 const cancelled=await slow;assert.equal(cancelled.status,500);assert.match(cancelled.body.error,/cancelled/);assert.doesNotMatch(JSON.stringify(cancelled.body),/FixtureHandle|Command.pm|line \d+|open3/);
 assert.equal((await request('/api/status')).body.running,false,'Cancelled operation cannot restart after cleanup');
 console.log(JSON.stringify({result:'Phase 3 HTTP acceptance passed',probe_duration_ms:5000,status_during_probe_ms:latency,cancel_during_probe_ms:cancelLatency,native_handles:'simulated'}));
}finally{if(child&&child.exitCode===null){child.kill('SIGTERM');await Promise.race([once(child,'exit'),new Promise(r=>setTimeout(r,2000))]);if(child.exitCode===null)child.kill('SIGKILL')}fs.rmSync(temp,{recursive:true,force:true})}})().catch(e=>{console.error(e);process.exitCode=1});
