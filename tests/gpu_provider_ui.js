// Real templates/functions with synthetic telemetry; no hardware claims.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {JSDOM}=require('jsdom'),ui=require('./support/ui.cjs');
const dom=new JSDOM(ui.html(),{runScripts:'outside-only',url:'http://visllama.test/'}),w=dom.window,d=w.document;
for(const file of ['state','core','stats','dashboard'])vm.runInContext(fs.readFileSync(path.join(ui.root,'public/assets/js',file+'.js'),'utf8'),dom.getInternalVMContext());
w.drawSpark=()=>{};
const record=(vendor,provider)=>({vendor,provider,index:0,name:'Same <GPU>',uuid:'same-provider-uuid',memory_used_mib:1024,memory_total_mib:16384,
 utilization_percent:0,fan_percent:null,temperature_c:45,power_w:72,power_limit_w:null,semantics:{power_domain:'socket',utilization:'GFX activity'},explicit_placement_ready:false});
try{
 const n=record('NVIDIA','nvidia-smi'),a=record('AMD','amd-smi'),i=record('Intel','xpu-smi');
 const j={nvidia:{gpus:[n],sampled_at:'NVIDIA sample'},amd:{gpus:[a],providers:[{id:'amd-smi',status:'monitoring_partial',message:'Some measurements unavailable.'}]},intel:{gpus:[i]}};
 w.renderGpuStats(j);
 assert.equal(d.querySelectorAll('.gpu-card').length,4,'NVIDIA summary plus three vendor cards');
 assert.equal(d.querySelectorAll('.gpu-summary').length,1,'No unsafe cross-vendor aggregate');
 assert.equal(d.querySelector('.gpu-summary .gpu-name').textContent,'NVIDIA GPUs','Mixed-host summary explicitly identifies its NVIDIA-only scope');
 assert.equal(d.querySelector('.gpu-summary .gpu-metric-value').textContent,'1024 MiB / 16384 MiB','Summary retains NVIDIA-only meaning');
 assert.match(d.querySelector('#gpuDashboard').textContent,/AMD \/ amd-smi/);
 assert.match(d.querySelector('#gpuDashboard').textContent,/Intel \/ xpu-smi/);
 assert.match(d.querySelector('#gpuDashboard').textContent,/Verified physical isolation unavailable/);
 assert.equal(d.querySelectorAll('canvas').length,new Set([...d.querySelectorAll('canvas')].map(e=>e.id)).size,'Canvas IDs cannot collide across providers');
 assert.equal(d.querySelector('#gpuDashboard GPU'),null,'Names are escaped');
 assert.equal(vm.runInContext("[...GPU_HISTORY.keys()].filter(x=>x.startsWith('alternate:')).length",dom.getInternalVMContext()),2,'Same UUID in different namespaces does not share history');
 w.renderHardwareStrip(j);
 assert.equal(d.querySelector('#dashGpu').textContent,'3 GPUs','Dashboard does not add different memory pools');
 assert.match(d.querySelector('#dashGpuNote').textContent,/not combined/);
 w.renderGpuStats({nvidia:{gpus:[]},amd:{gpus:[a],sampled_at:'AMD sample'},intel:{gpus:[]}});
 assert.equal(d.querySelectorAll('.gpu-summary').length,0,'AMD-only host does not get a misleading NVIDIA summary');
 assert.equal(d.querySelector('#gpuSampleTime').textContent,'Sampled AMD sample');
 assert.doesNotMatch(d.querySelector('#gpuDashboard').textContent,/placeholders|NVIDIA telemetry unavailable/);
 assert.equal(vm.runInContext("[...GPU_HISTORY.keys()].filter(x=>x.startsWith('alternate:')).length",dom.getInternalVMContext()),1,'Removed provider history is discarded');
 w.renderGpuStats({nvidia:{gpus:[]},amd:{gpus:[],providers:[{id:'amd-smi',message:'GPU tool access denied.',reference:'VL-test'}]}});
 assert.match(d.querySelector('#gpuDashboard').textContent,/access denied/);
 assert.match(d.querySelector('#gpuDashboard').textContent,/VL-test/);
 const requests=[];w.post=async(route,data)=>{requests.push({route,data});return {nvidia:{gpus:[]}}};
 (async()=>{await w.refreshGpuStats(true);assert.equal(requests[0].data.refresh_providers,true,'Explicit refresh queues discovery');
  await w.refreshGpuStats();assert.deepEqual(Object.keys(requests[1].data),[],'Routine polls do not reset provider retry backoff');
  console.log('Cross-vendor GPU UI passed: mixed/sole vendors, nulls, safe summaries, histories, escaping and refresh semantics');w.close();
 })().catch(e=>{console.error(e);w.close();process.exitCode=1});
}catch(e){w.close();throw e}
