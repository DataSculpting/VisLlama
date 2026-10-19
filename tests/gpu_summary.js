// Test arithmetic and actual Stats DOM rendering with synthetic telemetry.
// Native GPU collection and browser pixel layout are outside this test.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {JSDOM}=require('jsdom'),ui=require('./support/ui.cjs');
const dom=new JSDOM(ui.html(),{runScripts:'outside-only',url:'http://visllama.test/'}),w=dom.window,d=w.document;
for(const file of ['state','core','stats'])vm.runInContext(fs.readFileSync(path.join(ui.root,'public/assets/js',file+'.js'),'utf8'),dom.getInternalVMContext());
const plain=x=>JSON.parse(JSON.stringify(x)),sparks=new Map();
w.drawSpark=(canvas,values,max)=>{assert(canvas,'Spark has its own mounted canvas');sparks.set(canvas.id,{values:[...values],max})};
const gpus=Array.from({length:4},(_,i)=>({index:i,uuid:'GPU-'+i,name:'Test GPU '+i,memory_used_mib:1024*(i+1),memory_total_mib:32768,
 utilization_percent:10*(i+1),temperature_c:40+10*i,fan_percent:[null,0,null,60][i],power_w:100+50*i,power_limit_w:300}));
const data={nvidia:{sampled_at:'Test sample',gpus}},original=JSON.stringify(data);
const values=()=>[...d.querySelectorAll('.gpu-summary .gpu-metric-value')].map(e=>e.textContent);
try{
 assert.deepEqual(plain(w.aggregateGpuStats(gpus)),{memory_used_mib:10240,memory_total_mib:131072,utilization_percent:25,temperature_c:55,fan_percent:30,power_w:700});
 w.renderGpuStats(data);
 assert.equal(JSON.stringify(data),original,'Aggregation does not modify original telemetry');
 assert.equal(d.querySelector('#gpuDashboard').firstElementChild.classList.contains('gpu-summary'),true,'Combined row precedes every GPU');
 assert.equal(d.querySelectorAll('.gpu-summary').length,1);assert.equal(d.querySelectorAll('.gpu-card').length,5);
 assert.equal(d.querySelectorAll('.gpu-summary .gpu-metric').length,5);
 assert.deepEqual(values(),['10240 MiB / 131072 MiB','25%','55 C','30%','700 W']);
 assert.equal(d.querySelector('#gpuSampleTime').textContent,'Sampled Test sample');
 assert.match(d.querySelector('.gpu-summary .gpu-meta').textContent,/4 GPUs reporting/);
 assert.equal(sparks.get('gpu-all-memory').values.at(-1),100*10240/131072,'VRAM spark uses combined usage divided by combined capacity');
 assert.equal(sparks.get('gpu-all-fan').values.at(-1),30,'A real zero fan counts; missing fans do not');
 assert.equal(sparks.get('gpu-all-power').values.at(-1),700,'Power is summed across all GPUs');
 assert.equal(d.querySelector('.gpu-summary .gpu-metric:last-child .gpu-metric-label').textContent,'Total power on GPUs');
 assert.equal(d.querySelectorAll('canvas').length,new Set([...d.querySelectorAll('canvas')].map(c=>c.id)).size,'Summary canvas IDs cannot collide with per-GPU IDs');
 const individual=[...d.querySelectorAll('.gpu-card:not(.gpu-summary)')];
 assert.equal(individual[0].querySelectorAll('.gpu-metric-value')[4].textContent,'100 W / 300 W','Individual power/limit display is retained');
 assert.equal(individual[0].querySelectorAll('.gpu-metric-value')[3].textContent,'N/A');

 // Each metric has its own denominator. Bad/missing values never become 0.
 const mixed=[{memory_used_mib:0,memory_total_mib:1024,utilization_percent:0,temperature_c:40,fan_percent:'N/A',power_w:0},
  {memory_used_mib:null,memory_total_mib:3072,utilization_percent:100,temperature_c:undefined,fan_percent:null,power_w:100},
  {memory_used_mib:100,memory_total_mib:1024,utilization_percent:NaN,temperature_c:60,fan_percent:undefined,power_w:Infinity}];
 assert.deepEqual(plain(w.aggregateGpuStats(mixed)),{memory_used_mib:null,memory_total_mib:5120,utilization_percent:50,temperature_c:50,fan_percent:null,power_w:null});
 assert(Object.values(w.aggregateGpuStats([])).every(x=>x===null));
 assert(Object.values(w.aggregateGpuStats([{}])).every(x=>x===null));
 const unequal=[{...gpus[0],memory_used_mib:1024,memory_total_mib:1024},{...gpus[1],memory_used_mib:0,memory_total_mib:3072}];
 w.renderGpuStats({nvidia:{gpus:unequal}});assert.equal(sparks.get('gpu-all-memory').values.at(-1),25,'Different capacity GPUs are not averaged as percentages');
 const unavailableFans=gpus.map(g=>({...g,fan_percent:null}));w.renderGpuStats({nvidia:{gpus:unavailableFans}});
 assert.equal(values()[3],'N/A');assert.equal(sparks.get('gpu-all-fan').values.at(-1),null);
 const missingPower=gpus.map(g=>({...g}));missingPower[0].power_w=null;
 w.renderGpuStats({nvidia:{gpus:missingPower}});assert.equal(values()[4],'N/A','A partial power sum is not a total');
 assert.equal(sparks.get('gpu-all-power').values.at(-1),null);
 assert.equal(w.aggregateGpuStats([{power_w:0},{power_w:50}]).power_w,50,'Zero watts is a valid reading');
 const incomplete=gpus.map(g=>({...g}));incomplete[0].memory_used_mib=null;
 w.renderGpuStats({nvidia:{gpus:incomplete}});assert.equal(values()[0],'N/A / 131072 MiB');
 assert.equal(sparks.get('gpu-all-memory').values.at(-1),null,'Unknown usage does not draw a false zero');
 for(let i=0;i<65;i++)w.renderGpuStats(data);
 assert.equal(sparks.get('gpu-all-power').values.length,60,'Summary uses the existing bounded history');
 w.renderGpuStats({nvidia:{gpus:[]}});assert.equal(d.querySelector('.gpu-summary'),null);
 assert.match(d.querySelector('#gpuDashboard').textContent,/unavailable/);
 w.renderGpuStats({nvidia:{gpus:[gpus[1]]}});
 assert.match(d.querySelector('.gpu-summary .gpu-meta').textContent,/1 GPU reporting/);
 assert.deepEqual(values(),['2048 MiB / 32768 MiB','20%','50 C','0%','150 W']);
 assert.equal(sparks.get('gpu-all-power').values.length,1,'Returning telemetry starts a fresh aggregate history');
 console.log('GPU summary passed: sums, per-metric averages, zero/N/A handling, five-column rendering and bounded live trends');
}finally{w.close()}
