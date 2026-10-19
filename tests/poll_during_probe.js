// Real controller, native Perl probe and loopback engine HTTP. Process handles
// and telemetry values are fixtures; no Windows/GPU validation is implied.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),http=require('node:http'),net=require('node:net');
const {spawn}=require('node:child_process'),{once}=require('node:events');
const root=path.resolve(__dirname,'..'),temp=fs.mkdtempSync(path.join(__dirname,'.poll-probe-'));
for(const file of ['lib','templates','public'])fs.cpSync(path.join(root,file),path.join(temp,file),{recursive:true});
let child,port,engine,engineFails=false,output='';
const request=(url,body={})=>new Promise((resolve,reject)=>{
 const data=JSON.stringify(body),req=http.request({host:'127.0.0.1',port,path:url,method:'POST',headers:{'Content-Type':'application/json','Content-Length':Buffer.byteLength(data)}},res=>{let text='';res.on('data',b=>text+=b);res.on('end',()=>{try{resolve({status:res.statusCode,body:JSON.parse(text)})}catch(e){reject(e)}})});
 req.on('error',reject);req.setTimeout(6000,()=>req.destroy(new Error('Request timeout')));req.end(data);
});
const perl=String.raw`
our $alive=1;
BEGIN {*CORE::GLOBAL::system=sub {$main::alive=0;return 0}}
use VisLlama::App;
{package FixtureHandle;sub GetExitCode {$_[1]=$main::alive?259:0;return 1}sub GetProcessID {90002}}
no warnings 'redefine';
*VisLlama::ModelStats::sample_if_due=sub {};
*VisLlama::Telemetry::collect_nvidia_gpu_stats=sub {VisLlama::Util::capture_command($^X,'-e','select undef,undef,undef,0.8');return {gpus=>[]}};
*VisLlama::Telemetry::collect_amd_gpu_stats=sub {{}};
*VisLlama::Telemetry::collect_intel_gpu_stats=sub {{}};
*VisLlama::Telemetry::collect_system_stats=sub {{}};
$VisLlama::Context::CFG{listen_port}=shift @ARGV;
my $state=$VisLlama::Context::STATE;$state->{mode}='router';
$state->{router_engines}={fixture=>{build=>'fixture',port=>shift @ARGV,models=>['alpha','beta','gamma'],proc=>bless({},'FixtureHandle'),pid=>90002}};
exit VisLlama::App::run();`;
(async()=>{try{
 engine=http.createServer((req,res)=>{res.writeHead(engineFails?503:200,{'Content-Type':'application/json'});res.end(JSON.stringify(engineFails?{error:'fixture failure'}:{data:['alpha','beta','gamma'].map(id=>({id,status:{value:'unloaded'}}))}))});
 engine.listen(0,'127.0.0.1');await once(engine,'listening');
 const listener=net.createServer();listener.listen(0,'127.0.0.1');await once(listener,'listening');port=listener.address().port;listener.close();await once(listener,'close');
 child=spawn(process.env.PERL||'perl',['-I',path.join(temp,'lib'),'-e',perl,String(port),String(engine.address().port)],{cwd:temp});
 child.stdout.on('data',b=>output+=b);child.stderr.on('data',b=>output+=b);
 let initial;for(let i=0;i<60;i++){try{initial=await request('/api/router-models');break}catch{await new Promise(r=>setTimeout(r,50))}}
 assert(initial,'Startup: '+output);assert.equal(initial.status,200);assert.equal(initial.body.result.incomplete,false);
 for(let cycle=0;cycle<3;cycle++){
  let finished=false;const probe=request('/api/gpu-stats').then(r=>{finished=true;return r});
  await new Promise(r=>setTimeout(r,100));
  const poll=await request('/api/router-models');
  assert.equal(poll.status,200,'Model poll must not become a busy error during telemetry');
  assert.equal(finished,false,'Model status must be served while the probe is pending');
  assert.equal(poll.body.result.incomplete,false);assert.equal(poll.body.result.data[0].status.value,'unloaded');
  assert.equal((await request('/api/model-root-save',{path:temp})).status,200,'Idle telemetry queues the save rather than rejecting it');
  assert.equal(finished,true,'Queued save runs only after the probe returns');
  assert.equal((await probe).status,200);
 }
 engineFails=true;const failed=await request('/api/router-models');assert.equal(failed.body.result.incomplete,true,'Real engine failure remains visible');
 engineFails=false;assert.equal((await request('/api/router-models')).body.result.incomplete,false,'Recovered engine reports fresh status');
 // Optional real-browser layer uses this same live HTTP controller/engine.
 if(process.env.VISLLAMA_BROWSER){
  const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
  const bundled=process.env.BUNDLED_CHROMIUM_MODULE?require(process.env.BUNDLED_CHROMIUM_MODULE).default:null;
  const browser=await chromium.launch({executablePath:process.env.BROWSER_EXECUTABLE||(bundled?await bundled.executablePath():undefined),args:bundled?.args||[],headless:true});
  try{
   const page=await browser.newPage({viewport:{width:1440,height:950}}),errors=[];
   page.on('pageerror',e=>errors.push(e.message));
   const html=require('./support/ui.cjs').html().replace(/<script src="\/assets\/js\/startup.js[^\"]*"><\/script>/,'');
   await page.route('http://visllama.test/**',async route=>{
    const url=new URL(route.request().url());
    if(url.pathname==='/')return route.fulfill({contentType:'text/html',body:html});
    if(url.pathname.startsWith('/assets/'))return route.fulfill({path:path.join(root,'public',url.pathname)});
    const reply=await request(url.pathname,route.request().postDataJSON()||{});
    return route.fulfill({status:reply.status,json:reply.body});
   });
   await page.goto('http://visllama.test/');
   await page.evaluate(async()=>{
    $('startupSplash').remove();CFG={builds:[{name:'fixture',available:true}],router_service:{},models:[]};
    $('serverMode').value='router';
    ROUTER_PRESETS=['alpha','beta','gamma'].map(alias=>({alias,build:'fixture',enabled:true,options:[],ui:{}}));
    LAST_STATUS=await post('/api/status',{}, {busy:false});await refreshRouterModels();
    window.firstLoadButton=$('dashModels').querySelector('button');
   });
   for(let cycle=0;cycle<3;cycle++){
    await page.evaluate(()=>{window.probeDone=false;window.probe=post('/api/gpu-stats',{}, {busy:false}).then(()=>{window.probeDone=true})});
    await new Promise(r=>setTimeout(r,100));await page.evaluate(()=>refreshRouterModels());
    const observed=await page.evaluate(()=>({unavailable:MODEL_STATUS_ERROR,disabled:[...$('dashModels').querySelectorAll('button')].map(b=>b.disabled),sameButton:window.firstLoadButton===$('dashModels').querySelector('button'),probeDone:window.probeDone,note:$('dashModelNote').textContent}));
    assert.equal(observed.unavailable,false);assert.deepEqual(observed.disabled,[false,false,false]);assert.equal(observed.sameButton,true);assert.equal(observed.probeDone,false);assert.doesNotMatch(observed.note,/unavailable/);
    await page.evaluate(()=>window.probe);
   }
   engineFails=true;await page.evaluate(()=>refreshRouterModels());
   assert.equal(await page.locator('#dashModels button:disabled').count(),3,'Real failure still disables unsafe actions');
   assert.match(await page.locator('#dashModelNote').textContent(),/temporarily unavailable/);
   engineFails=false;await page.evaluate(()=>refreshRouterModels());
   assert.equal(await page.locator('#dashModels button:disabled').count(),0);
   assert.deepEqual(errors,[]);
   const evidence=path.join(root,'tests/evidence/1.4.4');fs.mkdirSync(evidence,{recursive:true});
   await page.screenshot({path:path.join(evidence,'stable-load-buttons.png')});
   fs.writeFileSync(path.join(evidence,'browser-polling.json'),JSON.stringify({passed:true,telemetryCollisions:3,healthyLoadButtons:3,buttonIdentityPreserved:true,genuineFailureDisables:true,recoveryEnables:true,pageErrors:errors,nativeProcesses:'simulated model handle; real Perl probe'},null,2)+'\n');
   console.log('Chromium polling passed: three stable Load buttons through telemetry; genuine failure and recovery still visible');
  }finally{await browser.close()}
 }
 console.log('Poll/probe regression passed: three overlapping telemetry polls, mutation exclusion, genuine engine failure and recovery');
}finally{
 if(child&&child.exitCode===null){child.kill('SIGTERM');await Promise.race([once(child,'exit'),new Promise(r=>setTimeout(r,1500))]);if(child.exitCode===null)child.kill('SIGKILL')}
 if(engine)engine.close();fs.rmSync(temp,{recursive:true,force:true});
}})().catch(e=>{console.error(e);process.exitCode=1});
