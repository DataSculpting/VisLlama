// Full embedded UI integration with a simulated DOM and synthetic API data.
// No layout engine or actual Windows/GPU processes are used. See README.md.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const {JSDOM,VirtualConsole} = require('jsdom');
const root = path.resolve(__dirname, '..');
const source = require('./support/ui.cjs').inlineHTML();
const html = source;
const aliases = ['Qwen3.8-27B-Q8_0-MTP-PP', 'Qwen3-Coder-30B-Q4_K_M', 'Llama-3.3-70B-Q4_K_M'];
const builds = [{name:'b10819 CUDA 12.4',dir:'C:/llama.cpp/b10819/cuda12.4',exe:'C:/llama.cpp/b10819/cuda12.4/llama-server.exe',available:true}];
const models = aliases.map((alias,i)=>({supplier:'Local',variant:alias,file:alias+'.gguf',path:'D:/GGUF/models/Local/'+alias+'/'+alias+'.gguf',size:(28+i*7)*1073741824}));
let presets = aliases.map((alias,i)=>({alias,model:models[i].path,build:builds[0].name,enabled:true,load_on_startup:i<2,options:[],ui:{alias,build:builds[0].name,model:models[i].path,supplier:'Local',variant:alias,ctx:'65536',parallel:'2',cacheK:'q8_0',cacheV:'q8_0',gpuPriority:'manual',devices:['CUDA0','CUDA1'],gpuReserve:'2048'}}));
const requests=[],errors=[];
let rejectOrder=false,telemetryAvailable=true,modelState='loaded';
const api=(url,body)=>{
 requests.push({url,body});
 const base={ok:true};
 switch(url){
 case '/api/stop':return {ok:false,error:'Managed processes could not be confirmed stopped. Retry Stop before starting again. Reference: VL-TEST-STOP'};
 case '/api/config':return {...base,models,builds,model_root:'D:/GGUF/models',router_presets:presets,router_service:{host:'127.0.0.1',port:8080,models_max:4,autoload:true},router_json:'presets/router-presets.json'};
 case '/api/help':return {...base,options:[],raw:'Fixture help'};
 case '/api/devices':return {...base,devices:[{id:'CUDA0',description:'Tesla PG500-216'},{id:'CUDA1',description:'NVIDIA RTX A4000'}],raw:''};
 case '/api/status':return {...base,running:true,mode:'router',router_host:'127.0.0.1',router_port:8080,proxy_running:true,router_engines:[{build:builds[0].name,running:true,models:aliases}],started:'2026-09-26 10:00:00',log_tail:'Router ready.\n'+aliases[0]+' loaded.\nListening on 127.0.0.1:8080'};
 case '/api/router-models':return {...base,result:{data:aliases.map((id,i)=>({id,status:{value:i===0?modelState:i===1?'sleeping':'unloaded',args:[]}}))}};
 case '/api/gpu-stats':return telemetryAvailable?{...base,nvidia:{sampled_at:'2026-09-26 10:00:00',gpus:[{index:0,uuid:'GPU-0001',name:'Tesla PG500-216',memory_used_mib:24484,memory_total_mib:32768,utilization_percent:36,temperature_c:48,power_w:138,power_limit_w:250},{index:1,uuid:'GPU-0002',name:'NVIDIA RTX A4000',memory_used_mib:6410,memory_total_mib:15352,utilization_percent:17,temperature_c:58,fan_percent:41,power_w:77,power_limit_w:140}]},system:{cpu_percent:12,memory_used_mib:32000,memory_total_mib:128000}}:{ok:false,error:'Telemetry temporarily unavailable'};
 case '/api/router-presets':return {...base,presets};
 case '/api/router-preset-order':
  if(rejectOrder)return {ok:false,error:'Could not save model order'};
  presets=body.aliases.map(alias=>presets.find(p=>p.alias===alias));return {...base,presets};
 case '/api/model-stats':return {...base,presets:presets.map(p=>({...p,config_id:'fixture'})),days:Array.from({length:7},(_,i)=>({date:new Date(Date.now()-i*86400000).toISOString().slice(0,10),alias:aliases[0],build:builds[0].name,config_id:'fixture',prompt_tokens:4000+i*123,decode_tokens:2000+i*75,prompt_seconds:3,decode_seconds:45}))};
 case '/api/fs-list':return {...base,path:'C:/llama.cpp',parent:'C:/',folders:[{name:'b10819',path:'C:/llama.cpp/b10819'}],files:[]};
 case '/api/build-details':return {...base,exe:builds[0].exe,build:'10819',devices:[],capabilities:[],version:'Fixture version',help:'Fixture help'};
 case '/api/router-load':modelState='loaded';return base;
 case '/api/router-unload':modelState='unloaded';return base;
 default:throw new Error('Unexpected fixture request: '+url);
 }
};
const virtualConsole=new VirtualConsole();
virtualConsole.on('jsdomError',e=>errors.push(e.message));
const dom=new JSDOM(html,{url:'http://visllama.test/',runScripts:'dangerously',pretendToBeVisual:true,virtualConsole,beforeParse(w){
 w.fetch=async(url,opts)=>({status:200,text:async()=>JSON.stringify(api(url,JSON.parse(opts.body)))});
 w.ResizeObserver=class{observe(){}};
 w.scrollTo=()=>{};
 w.HTMLCanvasElement.prototype.getContext=()=>({clearRect(){},beginPath(){},moveTo(){},lineTo(){},stroke(){}});
 // Focus traps depend on layout visibility, which jsdom does not calculate.
 // Simulate only hidden/view/modal visibility, never assert pixel layout here.
 w.Element.prototype.getClientRects=function(){return this.closest('.hidden')||this.closest('.view:not(.active)')?[]:[{width:10,height:10}]};
}});
const w=dom.window,d=w.document,$=id=>d.getElementById(id);
const flush=async()=>{for(let i=0;i<8;i++)await new Promise(r=>setImmediate(r))};
const frame=()=>new Promise(r=>w.requestAnimationFrame(r));
async function main(){try{
 await flush();
 assert.match($('stateText').textContent,/Running/,'Full application initializes');
 assert.equal($('startBtn').disabled,true);assert.equal($('stopBtn').disabled,false);
 assert.match(d.querySelector('.creator-mark').textContent,/Created by\s*Data Sculpting Inc\./);
 assert.equal(d.querySelector('.creator-mark img').getAttribute('src'),'/assets/img/datasculpting-logo-ico.png');
 $('stopBtn').click();await flush();
 assert.equal($('startBtn').disabled,true,'Failed stop blocks replacement start');
 assert.equal($('stopBtn').disabled,false,'Failed stop leaves retry available');
 assert.match($('toast').textContent,/VL-TEST-STOP/,'Stop failure displays safe reference');
 $('stopBtn').focus();w.busyBegin('First request');w.busyBegin('Second request');
 assert.equal(d.querySelector('header').inert,true,'Busy request blocks underlying controls');
 assert.equal(d.activeElement.id,'busyOverlay');
 w.busyEnd();assert.equal($('busyOverlay').classList.contains('hidden'),false,'Nested busy request stays visible');
 w.busyEnd();assert.equal($('busyOverlay').classList.contains('hidden'),true);
 assert.equal(d.activeElement.id,'stopBtn','Focus restored when all busy requests finish');
 assert.equal($('modelLibrary').querySelectorAll('.model-library-row').length,3);
 assert.equal($('modelInspector').querySelector('h2').textContent,aliases[0]);
 w.showView('models');
 const selector=alias=>'[data-lib-select="'+alias+'"]';
 $('modelLibrary').querySelector(selector(aliases[1])).focus();
 $('modelLibrary').querySelector(selector(aliases[1])).click();
 assert.equal($('modelInspector').querySelector('h2').textContent,aliases[1]);
 await w.refreshRouterModels(true);await flush();
 const focused=d.activeElement;
 await w.refreshRouterModels(true);await flush();
 assert.equal(d.activeElement,focused,'Unchanged polling preserves focused row control');
 assert.equal(focused.isConnected,true);
 $('modelLibrary').querySelector('[data-order-down="'+aliases[0]+'"]').click();await flush();
 assert.deepEqual(presets.map(p=>p.alias),[aliases[1],aliases[0],aliases[2]],'Arrow order saved');
 rejectOrder=true;
 $('modelLibrary').querySelector('[data-order-down="'+aliases[1]+'"]').click();await flush();
 assert.deepEqual([...$('modelLibrary').querySelectorAll('.model-library-row')].map(r=>r.dataset.orderAlias),presets.map(p=>p.alias),'Failure restores catalog order');
 rejectOrder=false;
 // Event-level drag test, not a native pointer or mobile touch test.
 const handle=$('modelLibrary').querySelector('[data-order-alias="'+aliases[2]+'"] [data-order-handle]');
 const dataTransfer={data:'',setData(type,data){this.data=data},getData(){return this.data}};
 const dispatch=(node,type)=>{const e=new w.Event(type,{bubbles:true,cancelable:true});Object.defineProperty(e,'dataTransfer',{value:dataTransfer});node.dispatchEvent(e)};
 dispatch(handle,'dragstart');
 await w.refreshRouterModels(true);await flush();
 assert.equal(handle.isConnected,true,'Polling leaves dragged row in place');
 dispatch($('modelLibrary').querySelector('[data-order-alias="'+aliases[1]+'"]'),'drop');await flush();
 assert.equal(presets[0].alias,aliases[2]);
 $('modelLibrary').querySelector('[data-lib-edit="'+aliases[0]+'"]').click();await flush();
 assert.equal($('editorView').classList.contains('active'),true);
 assert.equal($('alias').value,aliases[0]);
 assert.equal($('routerHost').value,'127.0.0.1','Editor preserves Router service binding');
 $('alias').value='Model (test)';$('editorSave').click();await flush();
 assert.equal($('alias').getAttribute('aria-invalid'),'true');
 assert.equal(requests.some(r=>r.url==='/api/router-preset-save'),false,'Invalid alias rejected before backend');
 assert.equal($('editorView').classList.contains('active'),true);
 $('editorClose').click();await flush();
 for(const name of ['dashboard','router','models','modelStats','logs','settings','stats']){
  w.showView(name);await flush();
  assert.equal(d.querySelectorAll('.view.active').length,1,'One active page');
  assert.equal($(name+'View').classList.contains('active'),true);
 }
 assert($('modelStatsDays').querySelector('table'),'History renders');
 w.showView('settings');$('openBuildManager').focus();$('openBuildManager').click();await frame();
 assert.equal(d.activeElement.closest('#buildManagerModal')!==null,true);
 assert.equal(d.querySelector('.app-shell').inert,true);
 $('browseBuildPath').focus();$('browseBuildPath').click();await flush();await frame();
 assert.equal($('buildManagerModal').inert,true);
 assert.equal(d.activeElement.closest('#folderBrowserModal')!==null,true);
 d.dispatchEvent(new w.KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));
 assert.equal($('folderBrowserModal').classList.contains('hidden'),true);
 assert.equal($('buildManagerModal').classList.contains('hidden'),false);
 assert.equal(d.activeElement.id,'browseBuildPath');
 const modalButtons=w.modalFocusables($('buildManagerModal'));
 modalButtons.at(-1).focus();d.dispatchEvent(new w.KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true}));
 assert.equal(d.activeElement,modalButtons[0],'Tab wraps within top dialog');
 d.dispatchEvent(new w.KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));
 assert.equal(d.activeElement.id,'openBuildManager');
 assert.equal(d.querySelector('.app-shell').inert,false);
 $('navToggle').click();
 assert.equal($('navToggle').getAttribute('aria-expanded'),'true');
 $('appNav').querySelector('[data-view="models"]').click();await frame();
 assert.equal($('navToggle').getAttribute('aria-expanded'),'false');
 assert.equal(d.activeElement,$('modelsView').querySelector('.page-title'),'Navigation transfers focus after view is visible');
 $('navToggle').click();d.dispatchEvent(new w.KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));
 assert.equal(d.activeElement.id,'navToggle');
 telemetryAvailable=false;await w.refreshGpuStats();await flush();
 assert.match($('hardwareItems').textContent,/Telemetry unavailable/);
 assert.equal($('dashGpu').textContent,'Unavailable','No stale telemetry after failure');
 assert.deepEqual(errors,[],'No uncaught JS or CSS parse errors');
 console.log('Instrument DOM integration passed (synthetic data; no browser layout or Windows GPU testing)');
}finally{w.close()}}
main().catch(e=>{console.error(e);process.exitCode=1});
