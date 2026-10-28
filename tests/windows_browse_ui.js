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
 await w.init();const paths=[];const post=w.post;
 w.post=async(route,body,...rest)=>{if(route!=='/api/fs-list')return post(route,body,...rest);paths.push(body.path);assert(!/^[A-Za-z]:$/.test(body.path),'No bare drive reaches backend');return {path:body.path,parent:'',folders:[],files:[]}};
 const windows='C:'+String.fromCharCode(92);
 for(const initial of [windows+'Maya',windows+'maya.exe','C:/Maya','C:','C:/']){
  paths.length=0;await w.browseFileInto('engineExecutable','Interpreter',initial);assert.equal(paths[0],initial==='C:/'?'C:/':windows);w.closeModal('folderBrowserModal');
 }
 paths.length=0;await w.browseFolderInto('engineRoot','Installation','D:');assert.equal(paths[0],'D:'+String.fromCharCode(92));w.closeModal('folderBrowserModal');
 paths.length=0;await w.loadFolderBrowser('E:');assert.equal(paths[0],'E:'+String.fromCharCode(92));
 run("CFG.platform='linux'");paths.length=0;await w.browseFileInto('engineExecutable','Interpreter','/maya/python');assert.equal(paths[0],'/maya');w.closeModal('folderBrowserModal');
 assert.equal(w.browserRootPath('/'),'/', 'Linux roots unchanged');
 console.log('Windows browse roots passed: component fallback, root-level executable, bare drive, folder navigation and Linux paths');
}finally{w.close()}})().catch(e=>{console.error(e);process.exitCode=1});
