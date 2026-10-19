// Full production UI with synthetic engine-only API responses; no hardware claim.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {JSDOM}=require('jsdom'),ui=require('./support/ui.cjs');
const dom=new JSDOM(ui.html(),{runScripts:'outside-only',pretendToBeVisual:true,url:'http://localhost:9090/'}),w=dom.window,d=w.document,ctx=dom.getInternalVMContext();
const run=s=>vm.runInContext(s,ctx),el=id=>d.getElementById(id),delay=ms=>new Promise(r=>setTimeout(r,ms));
const until=async f=>{for(let i=0;i<100;i++){if(f())return;await delay(10)}throw Error('Workflow deadline exceeded')};
w.TextDecoder=TextDecoder;w.TextEncoder=TextEncoder;w.AbortController=AbortController;w.structuredClone=structuredClone;w.ResizeObserver=class{observe(){}};w.scrollTo=()=>{};w.confirm=()=>true;w.setInterval=()=>0;
const build={id:'engine-strata',engine:'strata',name:'Strata prepared',root:'C:/Strata',executable:'C:/Strata/.venv/Scripts/python.exe'};
const definition={id:'strata',name:'Strata',definition_version:'1.0.0',driver:'native-json',fields:[],digest:'fixture'};
let preset={alias:'strata-model',build:build.id,engine:'strata',enabled:true,model:'C:/models/prepared',settings:{},native_config:{model:'C:/models/prepared'},ui:{},options:[]};
let running=false,owned=false,state='unloaded',incomplete=false,mapped=true,runtimeBuild=build.id;
const requests=[],errors=[];
const snapshot=()=>({ok:true,running,mode:'router',runtime_token:'fixture-runtime',proxy_running:running,router_engines:running&&mapped?[{build:runtimeBuild,engine:'strata',managed:true,running:owned,models:[preset.alias]}]:[],router_host:'127.0.0.1',router_port:8080,log_tail:''});
w.fetch=async(url,options)=>{const body=JSON.parse(options?.body||'{}');requests.push({url,body});let result;
 switch(url){
 case '/api/config':result={builds:[],engine_builds:[build],models:[],router_presets:[preset],model_root:'',platform:'windows',router_service:{host:'127.0.0.1',port:8080,models_max:4,autoload:true}};break;
 case '/api/status':result=snapshot();break;
 case '/api/gpu-stats':result={system:{},nvidia:{gpus:[]},amd:{gpus:[]},intel:{gpus:[]}};break;
 case '/api/start':assert.equal(body.mode,'router');running=true;result=snapshot();break;
 case '/api/stop':running=false;owned=false;state='unloaded';result=snapshot();break;
 case '/api/router-presets':result={presets:[preset]};break;
 case '/api/router-models':result={result:{data:[{id:preset.alias,status:{value:state}}],incomplete}};break;
 case '/api/router-load':assert(running&&!owned);state='loaded';owned=true;result={};break;
 case '/api/router-unload':assert(running);owned=false;state='unloaded';result={};break;
 case '/api/engine-capabilities':result={definition:{...definition,default_controls_available:definition.fields.length?0:1}};break;
 case '/api/engine-definition-defaults':result={definition:{...definition,fields:[{key:'parallel-requests',label:'Concurrent request slots',type:'integer',binding:'config',path:['parallel']}]}};break;
 case '/api/engine-definition-save':assert(!running,'Definition updated while stopped');definition.fields=body.definition.fields;result={definition};break;
 case '/api/engine-list':result={builds:[build],definitions:[definition],errors:[]};break;
 case '/api/engine-preset-save':preset={...preset,...body};result={presets:[preset]};break;
 case '/api/router-preset-startup':preset.load_on_startup=body.load_on_startup;result={presets:[preset]};break;
 case '/api/router-apply-config':result={applied:true};break;
 case '/api/chat-info':result={available:running,mode:'router',host:'127.0.0.1',port:8080,models:[{id:preset.alias}]};break;
 default:throw Error('Unexpected route '+url);
 }
 return new Response(JSON.stringify({ok:true,runtime_token:'fixture-runtime',...result}),{status:200});
};
for(const m of ui.html().matchAll(/<script src="([^"]+)"><\/script>/g)){
 let s=fs.readFileSync(path.join(ui.root,'public',m[1].split('?')[0]),'utf8');
 if(m[1].includes('/startup.js'))s=s.replace('init().finally(()=>{SPLASH_READY=true;finishStartupSplash()});','');
 vm.runInContext(s,ctx);
}
w.toast=(message,error)=>{if(error)errors.push(message)};
const dash=()=>d.querySelector('[data-dash-model="strata-model"]'),load=()=>d.querySelector('[data-r-load="strata-model"]'),unload=()=>d.querySelector('[data-r-unload="strata-model"]');
const poll=async()=>{await w.status(true);await w.refreshRouterModels(true);el('routerSearch').focus();w.renderRouterPresets();w.renderDashModels()};
(async()=>{try{
 await w.init();assert.deepEqual(errors,[]);assert.equal(run('SETUP_REQUIRED'),false);assert(!el('startBtn').disabled);
 el('openBuildManager').click();assert.match(el('engineBuildSummary').textContent,/Strata prepared/);w.closeModal('buildManagerModal');
 await el('startBtn').onclick();await poll();assert(!dash().disabled,'Dashboard Load enabled without a child');assert(!load().disabled,'Router Load enabled without a child');assert(unload().disabled);
 dash().click();await until(()=>owned&&!run('MODEL_ACTION_PENDING.size'));await poll();assert.equal(dash().dataset.dashAction,'unload');assert(!dash().disabled);assert(load().disabled);assert(!unload().disabled);
 await w.VisLlamaChat.open();await until(()=>!el('chatSend').disabled);assert.equal(el('chatModel').value,preset.alias);assert.equal(el('chatTemperatureMode').value,'model');assert.equal(el('chatOutputLimit').value,'available');
 await unload().onclick();await poll();await delay(60);assert(el('chatSend').disabled,'Unload removes model from Chat');assert(!dash().disabled);assert(!load().disabled);
 await load().onclick();await poll();dash().click();await until(()=>!owned&&!run('MODEL_ACTION_PENDING.size'));await poll();
 d.querySelector('[data-lib-edit="strata-model"]').click();await until(()=>!el('engineModelPanel').classList.contains('hidden'));assert.equal(el('engineModelBuild').value,build.id);assert(el('singlePane').classList.contains('editor-open'));await el('engineModelSave').onclick();
 d.querySelector('[data-r-clone="strata-model"]').click();await until(()=>!el('engineModelPanel').classList.contains('hidden'));assert.equal(el('engineModelAlias').value,'strata-model-copy');w.closeEditor();
 assert.match(el('modelInspector').textContent,/Native JSON controls/);
 const startup=d.querySelector('[data-r-startup="strata-model"]');startup.value='startup';await startup.onchange();assert(preset.load_on_startup);
 incomplete=true;await poll();assert(dash().disabled&&load().disabled);assert.match(load().title,/confirmed model status/);
 owned=true;state='loading';incomplete=false;await poll();assert.equal(dash().dataset.dashAction,'unload');assert(!dash().disabled&&!unload().disabled);assert(load().disabled);
 state='failed';await poll();assert(!dash().disabled&&!unload().disabled,'Owned failure can unload');assert(load().disabled);
 await unload().onclick();await poll();state='failed';await poll();assert(!dash().disabled&&!load().disabled,'Exited failure can retry');
 state='unloaded';runtimeBuild='different-build';await poll();assert(dash().disabled&&load().disabled);assert.match(dash().title,/Restart Router/);
 runtimeBuild=build.id;mapped=false;await poll();assert(dash().disabled&&load().disabled);mapped=true;
 preset.enabled=false;run('ROUTER_PRESETS[0].enabled=false');await poll();assert(dash().disabled&&load().disabled);preset.enabled=true;
 await el('stopBtn').onclick();await poll();assert(dash().disabled&&load().disabled);assert(el('stopBtn').disabled);run('ROUTER_PRESETS[0].enabled=true');w.syncServerButtons();assert(!el('startBtn').disabled);
 // Retained-definition update uses real nested modals and refreshes the model form.
 await w.engineEditModel(preset);assert(!el('engineUpdateDefaultControls').classList.contains('hidden'));await el('engineUpdateDefaultControls').onclick();assert(!el('engineDefinitionModal').classList.contains('hidden'));assert(JSON.parse(el('engineDefinitionJSON').value).fields.some(f=>f.key==='parallel-requests'));await el('engineDefinitionSave').onclick();assert(d.querySelector('[data-engine-field="parallel-requests"]'),'Reviewed default controls appear without reopening the model editor');assert(el('engineUpdateDefaultControls').classList.contains('hidden'));w.closeModal('engineDefinitionModal');w.closeModal('enginesModal');w.closeEditor();
 // The same helper preserves native engine liveness and mixed-catalog isolation.
 run("LAST_STATUS={running:true,mode:'router',router_engines:[{build:'native',running:false,models:['native-model']},{build:'engine-strata',managed:true,running:false,models:['strata-model']}]};MODEL_STATUS_FETCHED=true;MODEL_STATUS_ERROR=false;LIVE_ROUTER_MODELS=[];");
 assert.match(w.routerModelControls({alias:'native-model',build:'native',enabled:true}).loadReason,/native Router engine is stopped/);
 assert.equal(w.routerModelControls({alias:'strata-model',build:'engine-strata',engine:'strata',enabled:true}).loadReason,'');
 run('LAST_STATUS.router_engines[0].running=true');assert.equal(w.routerModelControls({alias:'native-model',build:'native',enabled:true}).loadReason,'');
 assert(!requests.some(r=>['/api/help','/api/devices','/api/build-details','/api/model-preflight'].includes(r.url)),'No native discovery/preflight called');assert.deepEqual(errors,[]);
 console.log('Engine-only UI workflow passed: init, builds, start/stop, both load/unload controls, Chat, edit/clone/save, startup setting, polling and recovery');
}finally{w.close()}})().catch(e=>{console.error(e);process.exitCode=1});
