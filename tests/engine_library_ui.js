// Real page/scripts and real Perl import inspection; fixture transport, no inference.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),{execFileSync}=require('node:child_process'),{JSDOM}=require('jsdom'),ui=require('./support/ui.cjs');
const dom=new JSDOM(ui.html(),{runScripts:'outside-only',pretendToBeVisual:true,url:'http://localhost:9090/'}),w=dom.window,d=w.document,ctx=dom.getInternalVMContext(),run=s=>vm.runInContext(s,ctx),el=id=>d.getElementById(id),wait=()=>new Promise(r=>setTimeout(r,0));
w.TextDecoder=TextDecoder;w.TextEncoder=TextEncoder;w.AbortController=AbortController;w.structuredClone=structuredClone;w.ResizeObserver=class{observe(){}};w.scrollTo=()=>{};w.confirm=()=>true;w.setInterval=()=>0;
const definition=JSON.parse(fs.readFileSync(path.join(ui.root,'engines/strata/engine.json'),'utf8'));definition.digest='fixture';
const config=JSON.parse(fs.readFileSync(path.join(ui.root,'tests/fixtures/engines/strata-iq3_xxs.json'),'utf8')),build={id:'engine-a',name:'Strata prepared',engine:'strata',root:'C:/Strata',executable:'C:/Strata/.venv/Scripts/python.exe'},second={...build,id:'engine-b',name:'Experimental'},other={id:'other',name:'Other',definition_version:'1.0.0',driver:'native-cli',fields:[]};
let presets=[],saved,requests=[],messages=[],inspectionFailure=false,inspectionHold=null,discoverHold=null,folderHold=null;
function inspect(body){return JSON.parse(execFileSync('perl',['-I',path.join(ui.root,'lib'),'-MVisLlama::Engine::Registry','-MVisLlama::Engine::Import','-MJSON::PP','-e',`local $/;my $r=decode_json(<STDIN>);my $d=VisLlama::Engine::Registry::read_json($ARGV[0]);print encode_json(VisLlama::Engine::Import::inspect($d,$r->{build},$r->{config}));`,path.join(ui.root,'engines/strata/engine.json')],{input:JSON.stringify({build,config:body.native_config}),encoding:'utf8'}))}
w.fetch=async(url,options)=>{const body=JSON.parse(options?.body||'{}');requests.push({url,body});let out={};switch(url){
 case '/api/config':out={builds:[],engine_builds:[build,second],models:[],model_root:'',router_presets:presets,router_service:{},platform:'windows'};break;
 case '/api/status':out={running:false,mode:'router',router_engines:[]};break;
 case '/api/gpu-stats':out={system:{},nvidia:{gpus:[]},amd:{gpus:[]},intel:{gpus:[]}};break;
 case '/api/router-models':out={result:{data:presets.map(p=>({id:p.alias,status:{value:'unloaded'}}))}};break;
 case '/api/engine-list':out={builds:[build,second],definitions:[definition,other],errors:[]};break;
 case '/api/engine-capabilities':out={definition};break;
 case '/api/engine-library-folders':if(folderHold)await new Promise(r=>folderHold=r);out={libraries:{folders:[...(body.runtime_library_dirs||[]).map(path=>({path,source:'User-selected',exists:true})),{path:'C:/detected/cublas',source:'Detected',exists:true}],directories:[...(body.runtime_library_dirs||[]),'C:/detected/cublas'],missing:[]}};break;
 case '/api/engine-discover':if(discoverHold)await new Promise(r=>discoverHold=r);out={definition:{...definition,capabilities:{added_fields:0,library_context:{folders:[{path:'C:/detected/cublas',source:'Detected',exists:true}]}}}};break;
 case '/api/engine-build-save':out={builds:[build,second]};break;
 case '/api/fs-list':out={path:body.path||'C:/chosen',folders:[],parent:'C:/'};break;
 case '/api/engine-import-inspect':if(inspectionHold)await new Promise(r=>inspectionHold=r);if(inspectionFailure)throw Error('Fixture inspection failure');out={inspection:inspect(body)};break;
 case '/api/engine-preset-save':saved=body;presets=[{...body,engine:'strata',enabled:true,ui:{},options:[]}];out={presets};break;
 case '/api/router-presets':out={presets};break;
 default:throw Error('Unexpected route '+url);
 }return new Response(JSON.stringify({ok:true,runtime_token:'fixture',...out}),{status:200})};
for(const m of ui.html().matchAll(/<script src="([^"]+)"><\/script>/g)){let code=fs.readFileSync(path.join(ui.root,'public',m[1].split('?')[0]),'utf8');if(m[1].includes('/startup.js'))code=code.replace('init().finally(()=>{SPLASH_READY=true;finishStartupSplash()});','');vm.runInContext(code,ctx)}
w.toast=(message,error)=>messages.push({message,error});
const field=key=>d.querySelector(`[data-engine-field="${key}"]`),file=(cfg=config,name='strata-iq3_xxs.json')=>({name,size:JSON.stringify(cfg).length,text:async()=>JSON.stringify(cfg)}),pick=f=>el('engineImportConfig').onchange({target:{files:f?[f]:[],value:'chosen'}}),state=()=>JSON.stringify(w.engineModelPayload());
(async()=>{try{
 await w.init();await w.engineEditModel({alias:'libraries',engine:'strata',build:build.id,model:'D:/model.gguf',native_config:config,settings:{},config_mode:'import'});
 const list=()=>el('engineModelLibraryList'),rows=()=>list().querySelectorAll('[data-engine-library-row]'),field=()=>d.querySelector('[data-engine-field="native-library-directories"]');
 assert.equal(rows().length,2);assert.match(list().textContent,/Imported/);assert(field().hidden);assert.deepEqual(JSON.parse(JSON.stringify(w.engineModelPayload().settings)),{});
 list().querySelector('[data-library-add]').click();let row=rows()[2];row.value='C:/extra';row.onchange();assert.deepEqual(JSON.parse(JSON.stringify(w.engineModelPayload().settings['native-library-directories'])),[...config.lib_dirs,'C:/extra']);
 list().querySelector('[data-library-remove="0"]').click();assert.equal(rows().length,2);assert.match(list().textContent,/User-selected/);
 // Browse commits through the real shared folder picker, not a raw JSON input.
 await list().querySelector('[data-library-browse="1"]').onclick();run("FOLDER_BROWSER_PATH='C:/browse-choice'");await el('folderUseBtn').onclick();assert.equal(rows()[1].value,'C:/browse-choice');assert.equal(w.engineModelPayload().settings['native-library-directories'][1],'C:/browse-choice');
 await el('engineDiscoverModel').onclick();const discovery=requests.findLast(r=>r.url==='/api/engine-discover');assert.equal(discovery.body.id,build.id);assert.equal(discovery.body.model_context.native_config.lib_dirs[0],config.lib_dirs[0]);assert.equal(discovery.body.model_context.settings['native-library-directories'][1],'C:/browse-choice');assert.equal(rows()[0].value,'C:/detected/cublas');assert.match(list().textContent,/Detected/);assert.match(el('engineModelErrors').textContent,/Save to retain/);
 // Detection writes a draft field, never registered defaults or a durable preset.
 await list().querySelector('[data-library-detect]').onclick();assert(requests.some(r=>r.url==='/api/engine-library-folders'&&r.body.model_context));assert(!requests.some(r=>r.url==='/api/engine-build-save'||r.url==='/api/engine-preset-save'));
 assert.equal(await w.saveEditorPreset(false),true);assert.deepEqual(saved.settings['native-library-directories'],['C:/detected/cublas']);assert.deepEqual(saved.native_config,config);
 // A late detection response cannot write into a different build/editor.
 folderHold=true;const pending=list().querySelector('[data-library-detect]').onclick();for(let i=0;i<100&&typeof folderHold!=='function';i++)await wait();assert.equal(typeof folderHold,'function');await w.engineEditModel({alias:'other',engine:'strata',build:second.id,model:'D:/other',native_config:{},settings:{},config_mode:'import'});folderHold();folderHold=null;await pending;assert.equal(rows().length,0);
 discoverHold=true;const discover=w.engineDiscover(second.id,true);for(let i=0;i<100&&typeof discoverHold!=='function';i++)await wait();list().querySelector('[data-library-add]').click();rows()[0].value='C:/newer-edit';rows()[0].onchange();discoverHold();discoverHold=null;await discover;assert.equal(rows()[0].value,'C:/newer-edit','Late discovery never overwrites newer edits');
 await w.engineOpenBuilds(build.id);assert.equal(el('engineRuntimeLibraries').type,'hidden');const buildList=()=>el('engineBuildLibraryList');buildList().querySelector('[data-library-add]').click();let input=buildList().querySelector('[data-engine-library-row]');input.value='C:/manual';input.onchange();assert.deepEqual(JSON.parse(el('engineRuntimeLibraries').value),['C:/manual']);
 await buildList().querySelector('[data-library-detect]').onclick();assert.equal(requests.findLast(r=>r.url==='/api/engine-library-folders').body.executable,build.executable);await w.engineSaveBuild();assert.deepEqual(requests.findLast(r=>r.url==='/api/engine-build-save').body.runtime_library_dirs,['C:/manual','C:/detected/cublas']);
 assert(!requests.some(r=>/engine-probe|engine-load-check|router-load|\/api\/start/.test(r.url)));assert(!messages.some(m=>m.error));console.log('Engine library UI passed: imported folders, add/remove/browse, contextual discovery, detected drafts, save, late-response guards and build list');
}finally{w.close()}})().catch(e=>{console.error(e);process.exitCode=1});
