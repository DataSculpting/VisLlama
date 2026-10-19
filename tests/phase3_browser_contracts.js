// Production polling/transport with a deterministic DOM and synthetic responses.
// Real pointer/layout checks are recorded separately in release evidence.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {JSDOM}=require('jsdom'),ui=require('./support/ui.cjs');
const dom=new JSDOM(ui.html(),{runScripts:'outside-only',url:'http://visllama.test/'}),w=dom.window,ctx=dom.getInternalVMContext();
const run=code=>vm.runInContext(code,ctx),source=name=>fs.readFileSync(path.join(ui.root,'public/assets/js',name+'.js'),'utf8');
run(source('state'));run(source('core'));
let hidden=false,counts={},timers=[];
Object.defineProperty(w.document,'hidden',{get:()=>hidden});
w.setInterval=(fn,ms)=>{timers.push({fn,ms})};
for(const name of ['status','refreshGpuStats','refreshModelStats','refreshRouterModels','renderRouterPresets','updateDashboard'])Object.defineProperty(w,name,{value:()=>{counts[name]=(counts[name]||0)+1},configurable:true,writable:true});
w.routerInteractionActive=()=>false;
const tail=source('startup').slice(source('startup').indexOf('setInterval(()=>'));
run(tail.slice(0,tail.indexOf('init().finally')));
run("LAST_STATUS={running:true,mode:'router',runtime_token:'original'};CFG={};APP_VIEW='modelStats';");
const poll=()=>{for(const timer of timers)if(timer.ms!==1000)timer.fn()};
try{
 poll();assert.equal(counts.status,1);assert.equal(counts.refreshGpuStats,1);assert.equal(counts.refreshModelStats,1);assert.equal(counts.refreshRouterModels,1);
 counts={};hidden=true;poll();assert.deepEqual(counts,{},'Hidden idle page sends no periodic HTTP polls');
 run("MODEL_ACTION_PENDING.set('alpha','load')");poll();assert.equal(counts.status,1);assert.equal(counts.refreshRouterModels,1);assert.equal(counts.refreshGpuStats,undefined);
 counts={};run('MODEL_ACTION_PENDING.clear()');hidden=false;w.document.dispatchEvent(new w.Event('visibilitychange'));
 assert.equal(counts.status,1);assert.equal(counts.refreshGpuStats,1);assert.equal(counts.refreshRouterModels,1);
 // The cancellation UI must not send Stop if its operation has been replaced.
 const requests=[],messages=[];w.toast=message=>messages.push(message);
 w.fetch=async(url,options)=>{requests.push({url,body:JSON.parse(options.body)});return {status:200,text:async()=>JSON.stringify({ok:true,runtime_token:'replacement',active_operation:{id:'other'}})}};
 run("CANCELLABLE_ACTION='wanted'");
 (async()=>{try{
  await w.cancelCurrentOperation();assert.deepEqual(requests.map(r=>r.url),['/api/status']);assert.match(messages[0],/finished or changed/);
  requests.length=0;
  await w.post('/api/stop',{}, {busy:false});assert.equal(requests[0].body.runtime_token,'original','Transport captures intended runtime, not a later server reply');
  assert.equal(run('REQUEST_TIMINGS.length'),2);assert.equal(w.document.getElementById('cancelOperation').disabled,false);
  console.log('Phase 3 browser contracts passed: visibility polling, completion polling, cancellation identity and request timings');
 }finally{w.close()}})().catch(e=>{console.error(e);process.exitCode=1});
}catch(e){w.close();throw e}
