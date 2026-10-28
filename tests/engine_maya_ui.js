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
 await w.init();await w.editPresetInDrawer(preset.alias);assert.equal(run('APP_VIEW'),'editor');
 const expected={'glm-pack':config.args[1],'max-context':'32768','expert-cache':'auto','prefill':'auto','kv-streaming':'on','kv-resident':'8192','parallel-requests':'2','gpu-selection':'0,2','layer-split':'24','ram-headroom':'16','cpu-lane':'12','pcie-share':'0.4','usage-file':config.env.MAYA_GLM_USAGE,'slot-directory':config.env.MAYA_GLM_SLOT_DIR,'native-executable':config.exe,'tokenizer-directory':config.tokenizer};
 for(const [key,value] of Object.entries(expected)){assert(field(key),key+' in shared editor');assert.equal(field(key).value,value,key+' hydrated');assert(!field(key).disabled,key+' editable');}
 assert.equal(Object.keys(w.engineModelPayload().settings).length,0,'Opening imported fields remains passive');
 let p=await preview();assert.deepEqual(p.config.args,config.args);assert.deepEqual(p.config.env,config.env);assert.deepEqual(p.config.vision,config.vision);assert.deepEqual(p.config.sampling,config.sampling);assert.equal(p.config.host,'127.0.0.1');assert.equal(p.config.port,8091);
 for(const input of d.querySelectorAll('[data-engine-field]')){const card=input.closest('.engine-option');assert(card);for(const id of input.getAttribute('aria-describedby').split(' '))assert(card.contains(el(id)));assert.equal(card.querySelectorAll('[data-engine-field]').length,1);}
 // Direct base-JSON editing is meaningful: leaving it refreshes native fields
 // and clears prior named overrides. The source fixture remains unchanged.
 change('gpu-selection','1,3');
 const edited=structuredClone(config);edited.gpu=[3,4];edited.layer_split='auto';
 el('engineNativeConfig').value=JSON.stringify(edited);el('engineNativeConfig').onchange();
 assert.equal(field('gpu-selection').value,'3,4');assert.equal(field('layer-split').value,'auto');assert(!Object.hasOwn(w.engineModelPayload().settings,'gpu-selection'));
 p=await preview();assert.deepEqual(p.config.gpu,[3,4]);assert.equal(p.config.layer_split,'auto');
 el('engineNativeConfig').value=JSON.stringify(config);el('engineNativeConfig').onchange();
 change('max-context','65536');change('parallel-requests','4');change('cpu-lane','8');change('ram-headroom','20');change('pcie-share','0.6');change('gpu-selection','1,3');change('layer-split','22');change('slot-directory','D:/Maya-data/slots-copy');
 p=await preview();assert.equal(arg(p.config,'--max-context'),'65536');assert.equal(arg(p.config,'--parallel'),'4');assert.equal(p.config.env.MAYA_GLM_CPU_LANE,8);assert.equal(p.config.env.FUTURE_SETTING,'keep');assert.equal(p.config.env.MAYA_GLM_SLOT_DIR,'D:/Maya-data/slots-copy');assert.equal(p.config.gpu,'1,3');assert.equal(p.config.layer_split,'22');assert(p.config.args.includes('--opaque-future'));
 change('parallel-requests','9');const before=requests.length;await el('engineModelPreview').onclick();assert.equal(requests.length,before);assert.equal(field('parallel-requests').getAttribute('aria-invalid'),'true');change('parallel-requests','4');
 assert.equal(await w.saveEditorPreset(false),true);assert.equal(saved.build,build.id);assert.equal(saved.settings['parallel-requests'],4);assert.deepEqual(saved.native_config,config);assert(!requests.some(r=>r.url.includes('discover')||r.url.includes('probe')));
 await w.editPresetInDrawer(preset.alias,true);assert.equal(el('alias').value,preset.alias+'-copy');assert.equal(field('cpu-lane').value,'8');assert.equal(field('parallel-requests').value,'4');
 await w.engineOpenBuilds('engine-a');assert.match(el('engineExecutable').closest('.field').textContent,/Maya server Python interpreter/);assert.match(el('engineRuntimeExecutable').closest('.field').textContent,/Maya GLM inference executable/);
 assert.deepEqual(errors,[]);console.log('Maya full-page UI passed: shared editor, JSON hydration, real Perl rendering, named edits, grouped descriptions, validation, passive save and clone');
}finally{w.close()}})().catch(e=>{console.error(e);process.exitCode=1});
