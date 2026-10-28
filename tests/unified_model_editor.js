// Full rendered page and production handlers. All engine/process replies are fixtures.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),{JSDOM}=require('jsdom'),ui=require('./support/ui.cjs');
const dom=new JSDOM(ui.html(),{runScripts:'outside-only',pretendToBeVisual:true,url:'http://localhost:9090/'}),w=dom.window,d=w.document,ctx=dom.getInternalVMContext(),run=s=>vm.runInContext(s,ctx),el=id=>d.getElementById(id),delay=ms=>new Promise(r=>setTimeout(r,ms));
w.TextDecoder=TextDecoder;w.TextEncoder=TextEncoder;w.AbortController=AbortController;w.structuredClone=structuredClone;w.ResizeObserver=class{observe(){}};w.scrollTo=()=>{};w.confirm=()=>true;w.setInterval=()=>0;
const native={name:'Same name',available:true,exe:'C:/llama/llama-server.exe'},builds=[{id:'engine-a',name:'Same name',engine:'strata',root:'C:/Strata',executable:'C:/Strata/python.exe'},{id:'engine-b',name:'Experimental',engine:'strata',root:'C:/Strata-next',executable:'C:/Strata-next/python.exe'},{id:'engine-c',name:'Third engine',engine:'example',root:'C:/Example',executable:'C:/Example/server.exe'}];
const definitions=[{id:'strata',name:'Strata',definition_version:'1.2.0',driver:'native-json',fields:[{key:'slots',label:'Concurrent slots',group:'Runtime',type:'integer',binding:'config',path:['parallel']},{key:'initial-field',label:'Format',type:'string',enum:['native'],initial:'native',binding:'none'}]}, {id:'example',name:'Example',definition_version:'1.0.0',driver:'native-cli',fields:[{key:'workers',label:'Workers',type:'integer',binding:'flag',flag:'--workers'}]}];
const initialNative={alias:'native-model',build:native.name,enabled:true,load_on_startup:true,model:'C:/models/a.gguf',options:[],ui:{ctx:'1024',temperature:'0.3',model:'C:/models/a.gguf',build:native.name}},initialExternal={alias:'strata-model',engine:'strata',build:'engine-a',enabled:true,load_on_startup:false,config_mode:'import',model:'C:/models/prepared',settings:{slots:4},native_config:{parallel:2,opaque:{keep:true}},ui:{},options:[]};
let presets=[structuredClone(initialNative),structuredClone(initialExternal)],running=false,failSave=false,failCheck=false,failApply=false,failLoad=false,holdCapabilities=null;
let nativeBuilds=[native],root='C:/models';const mapping=new Map(),states=new Map(),owned=new Set(),requests=[],errors=[];
const snapshot=()=>({running,mode:'router',runtime_token:'fixture',router_engines:running?Array.from(mapping,([alias,build])=>({build,models:[alias],managed:build.startsWith('engine-'),engine:build.startsWith('engine-')?'strata':undefined,running:!build.startsWith('engine-')||owned.has(alias)})):[]});
w.fetch=async(url,options)=>{const body=JSON.parse(options?.body||'{}');requests.push({url,body});let out={};switch(url){
 case '/api/config':out={builds:nativeBuilds,engine_builds:builds,models:[{supplier:'Local',variant:'A',file:'a.gguf',path:'C:/models/a.gguf',size:32}],router_presets:presets,model_root:root,platform:'windows',router_service:{}};break;
 case '/api/engine-list':out={builds,definitions,errors:[]};break;
 case '/api/engine-capabilities':if(holdCapabilities)await new Promise(r=>{holdCapabilities=r});out={definition:definitions.find(def=>def.id===builds.find(b=>b.id===body.id).engine)};break;
 case '/api/help':out={raw:'--ctx-size N --temperature N',options:[]};break;
 case '/api/devices':out={devices:[],raw:''};break;
 case '/api/status':out=snapshot();break;
 case '/api/gpu-stats':out={system:{},nvidia:{gpus:[]},amd:{gpus:[]},intel:{gpus:[]}};break;
 case '/api/router-presets':out={presets};break;
 case '/api/router-models':out={result:{data:presets.map(p=>({id:p.alias,status:{value:states.get(p.alias)||'unloaded'}}))}};break;
 case '/api/engine-load-check':if(failCheck)throw Error('Fixture invalid runtime options');break;
 case '/api/model-preflight':out={preflight_id:'fixture-preflight'};break;
 case '/api/engine-preset-save':case '/api/router-preset-save':{
  if(failSave)throw Error('Fixture save failure');const old=presets.find(p=>p.alias===body.original_alias),extension=url.includes('engine-preset');
  const p={...body,engine:extension?builds.find(b=>b.id===body.build).engine:undefined,enabled:old?.enabled??true,load_on_startup:old?.load_on_startup??false,options:[],ui:body.ui||{}};
  let inserted=false;presets=presets.flatMap(item=>item.alias===body.original_alias||item.alias===body.alias?(inserted?[]:(inserted=true,[p])):[item]);if(!inserted)presets.push(p);out={presets};break;
 }
 case '/api/router-apply-config':if(failApply)throw Error('Fixture apply failure');out={applied:true};break;
 case '/api/router-unload':owned.delete(body.model);states.set(body.model,'unloaded');break;
 case '/api/router-load':if(failLoad)throw Error('Fixture load failure');owned.add(body.model);states.set(body.model,'loaded');break;
 default:throw Error('Unexpected route '+url);
 }return new Response(JSON.stringify({ok:true,runtime_token:'fixture',...out}),{status:200})};
for(const m of ui.html().matchAll(/<script src="([^"]+)"><\/script>/g)){let code=fs.readFileSync(path.join(ui.root,'public',m[1].split('?')[0]),'utf8');if(m[1].includes('/startup.js'))code=code.replace('init().finally(()=>{SPLASH_READY=true;finishStartupSplash()});','');vm.runInContext(code,ctx)}
w.toast=(msg,error)=>{if(error)errors.push(msg)};
const field=key=>d.querySelector(`[data-engine-field="${key}"]`),visible=id=>!el(id).closest('.hidden'),change=async value=>{el('modelBuildChoice').value=value;await el('modelBuildChoice').onchange()},poll=async()=>{await w.status(true);await w.refreshRouterModels(true)},open=async(alias,clone=false)=>{await w.editPresetInDrawer(alias,clone);assert.equal(run('APP_VIEW'),'editor');assert(visible('alias'));assert(visible('modelBuildChoice'));assert(!visible('build'));assert.equal(d.getElementById('engineModelModal'),null)};
const mutations=from=>requests.slice(from).filter(r=>['/api/engine-preset-save','/api/router-preset-save','/api/router-unload','/api/router-load','/api/engine-load-check','/api/router-apply-config'].includes(r.url)).map(r=>r.url);
(async()=>{try{
 await w.init();assert.deepEqual(errors,[]);assert.equal(d.querySelectorAll('#alias').length,1);assert.equal(el('newEngineModel'),null);
 await open('native-model');assert.equal(el('modelBuildChoice').value,'native:Same name');assert(visible('friendly'));assert(!visible('engineModelPanel'));assert.equal(el('ctx').value,'1024');assert.equal(el('modelBuildChoice').options.length,5);
 el('ctx').value='2048';await change('extension:engine-a');assert(!visible('friendly'));assert(visible('engineModelPanel'));assert.equal(el('alias').value,'native-model');assert.equal(field('initial-field').value,'native','New engine family applies declared initial values');assert.equal(field('slots').value,'');assert(visible('modelEngineChangeNote'));field('slots').value='6';field('slots').onchange();el('engineModelPath').value='C:/models/prepared';
 await change('native:Same name');assert.equal(el('ctx').value,'2048','Native draft restored');assert.equal(el('temperature').value,'0.3');assert(!visible('modelEngineChangeNote'));
 await change('extension:engine-a');assert.equal(field('slots').value,'6','External draft restored');assert.equal(el('engineModelPath').value,'C:/models/prepared');
 await change('extension:engine-b');assert.equal(field('slots').value,'6','Same engine family shares compatible model settings');assert.equal(el('engineModelBuild').value,'engine-b');
 await change('extension:engine-c');assert.equal(field('slots'),null);assert(field('workers'));assert(!visible('engineNativeConfigField'),'CLI driver hides native JSON');field('workers').value='3';field('workers').onchange();
 await change('extension:engine-a');assert.equal(field('slots').value,'6');assert.equal(field('workers'),null,'Other engine settings never leak');
 // Saving an explicit family change replaces the same catalog entry through its adapter.
 let before=requests.length;assert.equal(await w.saveEditorPreset(false),true);assert.deepEqual(mutations(before),['/api/engine-preset-save']);let saved=presets.find(p=>p.alias==='native-model');assert.equal(saved.engine,'strata');assert(saved.load_on_startup);assert.equal(saved.settings.slots,6);assert.equal(presets[0].alias,'native-model');assert.equal(Object.hasOwn(saved.settings,'temperature'),false);
 await open('native-model');await change('native:Same name');el('model').value='C:/models/a.gguf';before=requests.length;assert.equal(await w.saveEditorPreset(false),true);assert.deepEqual(mutations(before),['/api/router-preset-save']);assert.equal(presets[0].engine,undefined);assert.equal(presets[0].load_on_startup,true);
 await open('strata-model',true);assert.equal(el('alias').value,'strata-model-copy');assert.equal(field('slots').value,'4');assert.equal(JSON.parse(el('engineNativeConfig').value).opaque.keep,true);w.closeEditor();
 // Engine-only Add uses the main screen without demanding a GGUF root.
 run('CFG.builds=[];CFG.model_root=""');await el('newModelEditor').onclick();assert.equal(run('APP_VIEW'),'editor');assert(visible('engineModelPanel'));assert.equal(el('modelBuildChoice').value,'extension:engine-a');assert.equal(el('engineConfigMode').value,'create');assert.equal(el('alias').value,'');w.closeEditor();run(`CFG.builds=${JSON.stringify([native])};CFG.model_root='C:/models'`);
 // A native build also opens without imposing the GGUF root on another engine.
 run('CFG.model_root=""');await el('newModelEditor').onclick();assert.equal(run('APP_VIEW'),'editor');assert(visible('friendly'));assert.match(el('modelBuildChoiceStatus').textContent,/GGUF model root/);await change('extension:engine-a');assert(visible('engineModelPanel'));w.closeEditor();run("CFG.model_root='C:/models'");
 // Load availability depends on an existing managed assignment, not a llama.cpp child.
 running=true;mapping.set('strata-model','engine-a');states.set('strata-model','unloaded');await poll();await open('strata-model');assert(!el('editorSaveReload').disabled);assert.equal(el('editorSaveReload').textContent,'Save and load');
 before=requests.length;assert.equal(await w.saveEditorPreset(true),true);assert.deepEqual(mutations(before),['/api/engine-load-check','/api/engine-preset-save','/api/router-apply-config','/api/router-load']);assert(owned.has('strata-model'));
 await poll();await open('strata-model');assert.equal(el('editorSaveReload').textContent,'Save and reload');assert(!el('editorSaveReload').disabled);
 field('slots').value='8';before=requests.length;assert.equal(await w.saveEditorPreset(true),true);assert.deepEqual(mutations(before),['/api/engine-load-check','/api/engine-preset-save','/api/router-unload','/api/router-apply-config','/api/router-load']);assert.equal(presets.find(p=>p.alias==='strata-model').settings.slots,8);
 // Validation/save errors cannot unload the existing process. Ordinary Save never probes/unloads.
 await poll();await open('strata-model');failCheck=true;before=requests.length;assert.equal(await w.saveEditorPreset(true),false);assert.deepEqual(mutations(before),['/api/engine-load-check']);assert(owned.has('strata-model'));failCheck=false;
 failSave=true;before=requests.length;assert.equal(await w.saveEditorPreset(true),false);assert.deepEqual(mutations(before),['/api/engine-load-check','/api/engine-preset-save']);assert(owned.has('strata-model'));failSave=false;
 before=requests.length;assert.equal(await w.saveEditorPreset(false),true);assert.deepEqual(mutations(before),['/api/engine-preset-save','/api/router-apply-config']);assert(owned.has('strata-model'));
 await poll();await open('strata-model');failApply=true;assert.equal(await w.saveEditorPreset(false),true);assert(owned.has('strata-model'));assert(errors.some(e=>/Preset saved, but Router catalog update failed/.test(e)));failApply=false;
 await open('strata-model');failLoad=true;assert.equal(await w.saveEditorPreset(true),true);assert(!owned.has('strata-model'));assert(errors.some(e=>/Preset saved, but load\/reload failed/.test(e)));assert.equal(run('MODEL_ACTION_PENDING.size'),0);failLoad=false;
 await poll();await open('strata-model');await change('extension:engine-b');assert(el('editorSaveReload').disabled);assert.match(el('editorSaveNote').textContent,/restart Router/i);
 await change('native:Same name');before=requests.length;assert.equal(await w.saveEditorPreset(false),false);assert.deepEqual(mutations(before),[],'Engine family change blocked while Router is running');assert(el('editorSaveReload').disabled);w.closeEditor();
 running=false;await poll();await open('strata-model');el('alias').value='bad alias';before=requests.length;assert.equal(await w.saveEditorPreset(false),false);assert.deepEqual(mutations(before),[]);assert(visible('aliasError'));assert.match(el('aliasError').textContent,/Spaces and slashes/);
 // A capability request cannot be saved through while its selected build is still switching.
 el('alias').value='strata-model';holdCapabilities=true;el('modelBuildChoice').value='extension:engine-b';const pending=el('modelBuildChoice').onchange();for(let i=0;i<100&&typeof holdCapabilities!=='function';i++)await delay(5);assert.equal(typeof holdCapabilities,'function');assert(el('modelBuildChoice').disabled);before=requests.length;assert.equal(await w.saveEditorPreset(false),false);assert.deepEqual(mutations(before),[]);holdCapabilities();holdCapabilities=null;await pending;assert(!el('modelBuildChoice').disabled);
 // Missing saved build identities remain explicit; they never become another build by default.
 w.closeEditor();await w.engineEditModel({...initialExternal,build:'engine-missing'});assert.equal(el('modelBuildChoice').value,'extension:engine-missing');assert.match(el('modelBuildChoiceStatus').textContent,/unavailable/);before=requests.length;assert.equal(await w.saveEditorPreset(false),false);assert.deepEqual(mutations(before),[]);
 assert(!errors.some(e=>/Unexpected route/.test(e)));console.log('Unified model editor passed: real page, named builds, native/external/third-family controls, isolated drafts, conversion, clone, engine-only Add, passive save, managed load/reload, validation/save/apply/load failures and switching barriers');
}finally{w.close()}})().catch(e=>{console.error(e);process.exitCode=1});
