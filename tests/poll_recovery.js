// Real shared transport with a controlled clock; no service, browser or GPU claims.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {JSDOM}=require('jsdom'),ui=require('./support/ui.cjs');
const dom=new JSDOM(ui.html(),{runScripts:'outside-only',url:'http://127.0.0.1:9090/'}),w=dom.window;
for(const name of ['state','core'])vm.runInContext(fs.readFileSync(path.join(ui.root,'public/assets/js',name+'.js'),'utf8'),dom.getInternalVMContext());
let now=0,requests=[],mode='offline',release;w.Date.now=()=>now;
w.fetch=async(url)=>{requests.push(url);if(mode==='offline')throw new w.TypeError('Failed to fetch');if(mode==='waiting')return new Promise(resolve=>release=resolve);return new Response(JSON.stringify(mode==='conflict'?{ok:false,error:'Controller is busy.'}:{ok:true,running:false}),{status:mode==='conflict'?409:200})};
const post=path=>w.post(path,{}, {busy:false}),paused=error=>error.pollPaused===true;
(async()=>{try{
 await assert.rejects(post('/api/gpu-stats'),error=>error.controlTransportFailure===true);
 assert.match(w.document.getElementById('controlPollNotice').textContent,/stale.*automatically/);
 for(const route of ['/api/status','/api/gpu-stats','/api/router-models','/api/model-stats','/api/chat-info'])await assert.rejects(post(route),paused);
 assert.equal(requests.length,1,'All read polls pause after transport failure');
 now=5000;mode='waiting';const recovery=post('/api/status');
 await assert.rejects(post('/api/status'),paused);await assert.rejects(post('/api/gpu-stats'),paused);
 assert.equal(requests.length,2,'Only one recovery status request is allowed');
 // A failed recovery moves from 5 seconds to 15 seconds.
 release(Promise.reject(new w.TypeError('Failed to fetch')));await assert.rejects(recovery);
 now=19999;await assert.rejects(post('/api/status'),paused);
 now=20000;mode='ok';await post('/api/status');await post('/api/gpu-stats');
 assert(w.document.getElementById('controlPollNotice').classList.contains('hidden'));
 // Busy telemetry is separate from transport reachability and status remains available.
 mode='conflict';await assert.rejects(post('/api/gpu-stats'),error=>error.httpStatus===409);
 const count=requests.length;mode='ok';await post('/api/status');await assert.rejects(post('/api/gpu-stats'),paused);
 assert.equal(requests.length,count+1,'Status succeeds while telemetry backs off');
 now=25000;mode='conflict';await assert.rejects(post('/api/gpu-stats'));
 now=39999;await assert.rejects(post('/api/gpu-stats'),paused);
 now=40000;mode='ok';await post('/api/gpu-stats');
 vm.runInContext('SERVER_ACTION_BUSY=true',dom.getInternalVMContext());await assert.rejects(post('/api/gpu-stats'),paused);await post('/api/status');
 vm.runInContext('SERVER_ACTION_BUSY=false;LAST_STATUS={active_operation:{id:"load"}}',dom.getInternalVMContext());await assert.rejects(post('/api/model-stats'),paused);
 // Explicit mutations are attempted once, never automatically replayed.
 mode='offline';await assert.rejects(post('/api/status'));mode='ok';await post('/api/router-preset-save');
 const afterMutation=requests.length;await assert.rejects(post('/api/gpu-stats'),paused);assert.equal(requests.length,afterMutation);
 console.log('Poll recovery passed: shared outage pause, automatic backoff, single recovery, HTTP 409 separation, lifecycle telemetry pause and no mutation replay');
}finally{dom.window.close()}})().catch(error=>{console.error(error);process.exitCode=1});
