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
 // Apply the real declared styles in order; jsdom does not perform pixel layout.
 for(const link of d.querySelectorAll('link[rel="stylesheet"]')){const file=path.join(ui.root,'public',link.getAttribute('href').split('?')[0]);const style=d.createElement('style');style.textContent=fs.readFileSync(file,'utf8');d.head.append(style)}
 await w.init();assert.equal(w.getComputedStyle(d.documentElement).getPropertyValue('--bg').trim(),'#141a1e');assert.equal(w.getComputedStyle(d.querySelector('.modal-dialog')).borderRadius,'12px');
 assert(d.querySelector('#dashboardView .dashboard-main>.dashboard-hardware'));assert(d.querySelector('#dashboardView .dashboard-main>.dashboard-columns'));assert(!d.querySelector('.dashboard-grid .dashboard-hardware'));
 w.renderHardwareStrip({nvidia:{gpus:[{index:0,name:'<img src=x onerror=bad()>',memory_used_mib:0,memory_total_mib:32768,utilization_percent:0,temperature_c:0}]},amd:{gpus:[{index:1,vendor:'AMD',name:'Shared-memory sample',memory_used_mib:null,memory_total_mib:null}]},system:{memory_used_mib:0,memory_total_mib:131072}});
 assert.equal(d.querySelectorAll('#dashHardwareDevices .dashboard-device').length,2);assert(!el('dashHardwareDevices').querySelector('img'));assert.match(el('dashHardwareDevices').textContent,/0.0 \/ 32.0 GiB/);assert.match(el('dashHardwareDevices').textContent,/0% utilization/);assert.match(el('dashHardwareDevices').textContent,/Unavailable/);assert.match(el('dashHostMemory').textContent,/0.0 \/ 128.0 GiB/);assert.equal(d.querySelector('#dashHardwareDevices [role="meter"]').getAttribute('aria-valuenow'),'0');
 w.renderHardwareStrip(null);assert.match(el('dashHardwareDevices').textContent,/unavailable/i);assert(!el('dashHardwareDevices').querySelector('[role="meter"]'));assert.match(el('dashHostMemory').textContent,/unavailable/i);
 const alias=el('alias'),importPanel=el('engineImportPanel');await w.editPresetInDrawer(preset.alias);assert.strictEqual(el('alias'),alias);assert(el('editorImportMount').contains(importPanel));assert(!el('editorImportMount').classList.contains('hidden'));assert(importPanel.compareDocumentPosition(el('editorIdentityCard'))&w.Node.DOCUMENT_POSITION_FOLLOWING);assert.equal(w.getComputedStyle(field('max-context').closest('.engine-option')).padding,'0px');
 for(const input of d.querySelectorAll('[data-engine-field]')){const card=input.closest('.field');for(const id of input.getAttribute('aria-describedby').split(' '))assert(card.contains(el(id)));}
 assert(el('editorSaveReload').classList.contains('primary'));assert(!el('editorSave').classList.contains('primary'));assert(el('engineRoot').closest('.field').querySelector('.engine-control-row').contains(el('engineBrowseRoot')));

 // GPU spacing is display-only. Pending labels stay whole as their length changes.
 run("ROUTER_PRESETS[0].native_config.gpu=[0,2]");w.renderDashModels();assert.equal(d.querySelector('#dashModels .dash-gpus').textContent,'0,2');
 assert.equal(w.getComputedStyle(d.querySelector('[data-dash-model]')).whiteSpace,'nowrap');
 run("ROUTER_PRESETS[0].settings['gpu-selection']='3, 4, 2'");w.renderDashModels();assert.equal(d.querySelector('#dashModels .dash-gpus').textContent,'3,4,2');assert.equal(run("ROUTER_PRESETS[0].settings['gpu-selection']"),'3, 4, 2');
 assert.equal(w.getComputedStyle(el('editorSaveReload')).overflowWrap,'normal');
 const before=JSON.stringify(w.modelEditorCapture()),choice=el('modelBuildChoice').value;
 el('modelManageBuilds').click();assert(!el('buildManagerModal').classList.contains('hidden'));w.closeModal('buildManagerModal');assert.equal(JSON.stringify(w.modelEditorCapture()),before);
 const last=el('modelBuildChoice').options[el('modelBuildChoice').options.length-1];assert.equal(last.textContent,'Add new engine/build');el('modelBuildChoice').value=last.value;await w.modelEditorChangeBuild();assert(!el('buildManagerModal').classList.contains('hidden'));assert.equal(el('modelBuildChoice').value,choice);w.closeModal('buildManagerModal');assert.equal(JSON.stringify(w.modelEditorCapture()),before);
 run("CFG.builds=[{name:'Native added',available:false}]");w.renderBuildSelector();assert([...el('modelBuildChoice').options].some(x=>x.value==='native:Native added'));assert.equal(el('modelBuildChoice').value,choice);
 run("MODEL_STATS_DATA={presets:[{alias:'sample',build:'engine-a',config_id:'current'},{alias:'sample',build:'Native alias',config_id:'native'}],days:[{date:'2026-10-01',alias:'sample',build:'engine-a',config_id:'older',prompt_tokens:4,decode_tokens:2,prompt_seconds:1,decode_seconds:1}]};MODEL_STATS_CONFIG='older'");el('modelStatsRange').value='all';w.renderModelStats();assert.match(el('modelStatsConfig').textContent,/Maya prepared \| older/);assert.match(el('modelStatsConfig').textContent,/Native alias \| native/);assert.equal(el('modelStatsConfig').value,'older');assert.match(el('modelStatsDays').textContent,/Maya prepared/);assert(!el('modelStatsConfig').textContent.includes('engine-a'));
 assert.equal(w.statsBuildLabel('engine-removed'),'Unregistered build: engine-removed');
 const card=d.createElement('div');card.innerHTML=w.gpuStatsCard({index:0,name:'Sample',uuid:'u',memory_used_mib:14029,memory_total_mib:15352,utilization_percent:0,temperature_c:30,fan_percent:null,power_w:38,power_limit_w:140},'align-test');d.body.append(card);assert.equal(card.querySelectorAll('canvas').length,5);assert.equal(w.getComputedStyle(card.querySelector('.gpu-metric')).display,'flex');assert.equal(w.getComputedStyle(card.querySelector('canvas')).height,'32px');card.remove();
 w.showView('logs');assert.equal(el('openServer').textContent,'Open Router / Serving');w.syncServerButtons({running:false});assert(!el('openServer').disabled);el('openServer').click();assert(el('routerView').classList.contains('active'));
 for(const view of ['dashboard','router','models','modelStats','logs','settings','stats','chat']){w.showView(view);assert.equal(d.querySelectorAll('.view.active').length,1);const ids=[...d.querySelectorAll('[id]')].map(x=>x.id);assert.equal(new Set(ids).size,ids.length)}
 assert.deepEqual(errors,[]);console.log('Visual refresh passed: real templates/cascade, truthful telemetry, escaping, import-first mounted controls, connected field help, action hierarchy, paths, dynamic GPU/button presentation, draft-safe build management, friendly history labels, diagnostics navigation and all views. Pixel layout is not tested by jsdom.');
}finally{w.close()}})().catch(e=>{console.error(e);process.exitCode=1});
