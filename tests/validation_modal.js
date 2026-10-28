// Real page/scripts + real Perl plan rendering. No engine process or hardware.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),{execFileSync}=require('node:child_process'),{JSDOM}=require('jsdom'),ui=require('./support/ui.cjs');
const dom=new JSDOM(ui.html(),{runScripts:'outside-only',pretendToBeVisual:true,url:'http://localhost:9090/'}),w=dom.window,d=w.document,ctx=dom.getInternalVMContext(),run=s=>vm.runInContext(s,ctx),el=id=>d.getElementById(id);
w.TextDecoder=TextDecoder;w.TextEncoder=TextEncoder;w.AbortController=AbortController;w.structuredClone=structuredClone;w.ResizeObserver=class{observe(){}};w.scrollTo=()=>{};w.confirm=()=>true;w.setInterval=()=>0;
const definition=JSON.parse(fs.readFileSync(path.join(ui.root,'engines/maya/engine.json'),'utf8'));definition.digest='fixture';
const config=JSON.parse(fs.readFileSync(path.join(ui.root,'tests/fixtures/engines/maya-glm.json'),'utf8')),build={id:'engine-a',name:'Maya prepared',engine:'maya',root:'C:/Maya',executable:'C:/Maya/.venv/Scripts/python.exe'},preset={alias:config.model_name,build:build.id,engine:'maya',model:config.args[1],config_mode:'import',native_config:config,settings:{},enabled:true,ui:{},options:[]};
let presets=[preset],saved,requests=[],errors=[];
function plan(body){return JSON.parse(execFileSync('perl',['-I',path.join(ui.root,'lib'),'-MVisLlama::Engine::Registry','-MVisLlama::Engine::Plan','-MJSON::PP','-e',`local $/;my $r=decode_json(<STDIN>);my $d=VisLlama::Engine::Registry::read_json($ARGV[0]);print encode_json(VisLlama::Engine::Plan::render($d,$r->{build},$r->{preset},'private-instance',8091));`,path.join(ui.root,'engines/maya/engine.json')],{input:JSON.stringify({build,preset:body}),encoding:'utf8'}))}
w.fetch=async(url,options)=>{const body=JSON.parse(options?.body||'{}');requests.push({url,body});let out={};switch(url){
 case '/api/config':out={builds:[],engine_builds:[build],models:[],model_root:'',router_presets:presets,router_service:{},platform:'windows'};break;
 case '/api/status':out={running:false,mode:'router',router_engines:[]};break;
 case '/api/gpu-stats':out={system:{},nvidia:{gpus:[]},amd:{gpus:[]},intel:{gpus:[]}};break;
 case '/api/router-models':out={result:{data:presets.map(p=>({id:p.alias,status:{value:'unloaded'}}))}};break;
 case '/api/engine-list':out={builds:[build],definitions:[definition],errors:[]};break;
 case '/api/engine-capabilities':out={definition:{...definition,fields:definition.fields.map(f=>({...f,...(f.support?{available:true,support_notice:'Known definition option; support not checked.'}:{})})),capabilities:{status:'not-run'}}};break;
 case '/api/engine-definition-defaults':out={definition};break;
 case '/api/engine-preview':out={plan:plan(body)};break;
 case '/api/engine-preset-save':saved=body;presets=[{...preset,...body}];out={presets};break;
 case '/api/router-presets':out={presets};break;
 default:throw Error('Unexpected route '+url);
 }return new Response(JSON.stringify({ok:true,runtime_token:'fixture',...out}),{status:200})};
for(const m of ui.html().matchAll(/<script src="([^"]+)"><\/script>/g)){let code=fs.readFileSync(path.join(ui.root,'public',m[1].split('?')[0]),'utf8');if(m[1].includes('/startup.js'))code=code.replace('init().finally(()=>{SPLASH_READY=true;finishStartupSplash()});','');vm.runInContext(code,ctx)}
w.toast=(message,error)=>{if(error)errors.push(message)};
const field=key=>d.querySelector(`[data-engine-field="${key}"]`),change=(key,value)=>{const f=field(key);if(f.type==='checkbox')f.checked=value;else f.value=value;f.onchange()},preview=async()=>{await el('engineModelPreview').onclick();return JSON.parse(el('engineLaunchPreview').textContent)},arg=(cfg,flag)=>{const i=cfg.args.indexOf(flag);return i<0?undefined:cfg.args[i+1]};
(async()=>{try{
 await w.init();await w.editPresetInDrawer(preset.alias);
 const visible=()=>!el('validationModal').classList.contains('hidden');
 async function dismiss(target){el('validationDismiss').click();assert(!visible());assert.equal(d.activeElement,target);}
 // All explicit save paths stop before network mutations, preserve drafts and explain why.
 for(const reload of [false,true]){
  el('alias').value='Model with spaces';let before=requests.length;
  assert.equal(await w.saveEditorPreset(reload),false);assert(visible());assert.match(el('validationDescription').textContent,/Spaces and slashes/);assert.equal(requests.length,before);assert.equal(el('alias').getAttribute('aria-invalid'),'true');assert.equal(el('alias').value,'Model with spaces');await dismiss(el('alias'));
 }
 el('alias').value=preset.alias;change('parallel-requests','9');let before=requests.length;
 assert.equal(await w.saveEditorPreset(false),false);assert(visible());assert.match(el('validationDescription').textContent,/8 or less/);assert.equal(requests.length,before);await dismiss(field('parallel-requests'));
 await el('engineModelPreview').onclick();assert(visible());assert.match(el('validationDescription').textContent,/8 or less/);assert.equal(requests.length,before);await dismiss(field('parallel-requests'));
 change('parallel-requests','4');assert(!visible(),'Typing creates no popup');
 el('engineModelPath').value='';assert.equal(await w.saveEditorPreset(false),false);assert(visible());assert.match(el('validationDescription').textContent,/catalog model/);await dismiss(el('engineModelPath'));el('engineModelPath').value=config.args[1];
 // Content is text, never executable markup. Shared stack restores the parent dialog.
 await w.engineOpenBuilds('engine-a');el('engineBuildName').value='';before=requests.length;await el('engineSaveBuild').onclick();assert(visible());assert.match(el('validationDescription').textContent,/build name/);assert.equal(requests.length,before);assert.equal(el('enginesModal').inert,true);await dismiss(el('engineBuildName'));assert.equal(el('enginesModal').inert,false);w.closeModal('enginesModal');
 w.validationBlocked('<img src=x onerror=bad()>','alias');assert.equal(el('validationDescription').children.length,0);await dismiss(el('alias'));
 // Native llama.cpp Save takes the same explanatory path without a save request.
 run("MODEL_EDITOR_KIND='llamacpp';MODEL_EDITOR_FAMILY='llamacpp';MODEL_EDITOR_ORIGINAL_FAMILY=null;CFG.model_root='/models';");el('alias').value='native with spaces';before=requests.length;assert.equal(await w.saveEditorPreset(false),false);assert(visible());assert.match(el('validationDescription').textContent,/Spaces and slashes/);assert.equal(requests.length,before);await dismiss(el('alias'));
 assert.deepEqual(errors,[]);console.log('Validation modal passed: native/external save, load/reload, preview, build registration, no requests, draft retention, nested modal/focus and safe message text');
}finally{w.close()}})().catch(e=>{console.error(e);process.exitCode=1});
