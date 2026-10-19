// Delayed API replies reproduce real request races without timers or live GPUs.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {JSDOM}=require('jsdom'),ui=require('./support/ui.cjs');
const dom=new JSDOM(ui.html(),{runScripts:'outside-only',url:'http://visllama.test/'}),w=dom.window,$=id=>w.document.getElementById(id);
for(const file of ['state','core','arguments','editor','stats'])vm.runInContext(fs.readFileSync(path.join(ui.root,'public/assets/js',file+'.js'),'utf8'),dom.getInternalVMContext());
let queue=[],renders=0,notices=0;
w.post=(url,body)=>new Promise((resolve,reject)=>queue.push({url,body,resolve,reject}));
w.toast=()=>notices++;w.updateCommand=()=>{};
async function main(){try{
 $('build').innerHTML='<option>Old</option><option>New</option>';
 const old=w.loadDevices();$('build').value='New';const current=w.loadDevices(['CUDA1']);
 queue[1].resolve({devices:[{id:'CUDA1',description:'new GPU'}],raw:'new'});await current;
 const expected=$('device').innerHTML;
 queue[0].resolve({devices:[{id:'CUDA0',description:'old GPU'}],raw:'old'});await old;
 assert.equal($('device').innerHTML,expected,'Stale discovery cannot replace the new selection');
 assert.equal($('deviceRaw').textContent,'new');
 const older=w.loadDevices(),newer=w.loadDevices(['CUDA1']);
 queue[3].resolve({devices:[{id:'CUDA1',description:'new GPU'}],raw:'latest'});await newer;
 queue[2].reject(new Error('Old request failed'));await older;
 assert.equal($('deviceRaw').textContent,'latest','Stale failure does not clear current devices');assert.equal(notices,0);
 // Telemetry timers share one in-flight request and release it after failure.
 queue=[];w.renderGpuStats=()=>renders++;w.renderSystemStats=()=>{};w.renderHardwareStrip=()=>{};
 const first=w.refreshGpuStats(),second=w.refreshGpuStats();assert.equal(queue.length,1,'Overlapping GPU polls coalesce');
 queue[0].reject(new Error('Temporary outage'));await Promise.all([first,second]);
 const third=w.refreshGpuStats();assert.equal(queue.length,2,'Failed poll does not lock future refreshes');
 queue[1].resolve({system:{}});await third;assert.equal(renders,1);
 // Status and telemetry have separate gates; manual waiters still await completion.
 queue=[];w.syncServerButtons=()=>{};w.updateDashboard=()=>{};w.refreshRouterModels=()=>{};
 const a=w.status(),b=w.status(),c=w.refreshGpuStats();assert.equal(queue.length,2);
 assert.equal(queue.filter(x=>x.url==='/api/status').length,1);
 queue.find(x=>x.url==='/api/status').resolve({running:false,mode:'single'});
 queue.find(x=>x.url==='/api/gpu-stats').resolve({system:{}});await Promise.all([a,b,c]);
 const d=w.status();assert.equal(queue.length,3,'Completed status is not cached');
 const manual=w.status(true);assert.equal(queue.length,3,'Manual refresh waits for older poll');
 queue[2].resolve({running:false,mode:'single'});await d;await Promise.resolve();
 assert.equal(queue.length,4,'Manual/action refresh fetches new state after older poll');
 queue[3].resolve({running:false,mode:'single'});await manual;
 console.log('Async recovery passed: stale device success/failure, coalesced polls and retry after failure');
}finally{dom.window.close()}}
main().catch(e=>{console.error(e);process.exitCode=1});
