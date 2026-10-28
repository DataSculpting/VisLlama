// VisLlama: router. Loaded in the order declared in templates/partials/scripts.html.

// Operational state, load/unload actions and explicit service-setting saves.
// Model snapshots must never overwrite the separately saved public Router binding.

function effectiveRouterHost(){return $('routerHost').value.trim()||CFG?.router_service?.host||'0.0.0.0'}

function effectiveRouterPort(){return $('routerPort').value.trim()||CFG?.router_service?.port||'8080'}

// Look up the latest runtime record for one saved alias.
function liveFor(alias){return LIVE_ROUTER_MODELS.find(m=>m.id===alias)||null}

// Calculate elapsed loading time from the existing per-model tracking record.
function loadSeconds(alias){const x=LOAD_TRACK.get(alias);return x?Math.max(0,Math.round((Date.now()-x.started)/1000)):0}

// Format load durations for progress and historical estimates.
function fmtSecs(n){n=Math.max(0,Math.round(n||0));return `${String(Math.floor(n/60)).padStart(2,'0')}:${String(n%60).padStart(2,'0')}`}

// Read the browser’s load-duration history used for progress estimates.
function historicLoads(){try{return JSON.parse(localStorage.getItem('visllamaLoadHistory')||'{}')}catch(e){return {}}}

function typicalLoad(alias){const h=historicLoads()[alias]||[];if(!h.length)return '';const avg=h.reduce((a,b)=>a+b,0)/h.length;const lo=Math.max(1,Math.round(avg*.85)),hi=Math.round(avg*1.2);return `${fmtSecs(lo)} - ${fmtSecs(hi)}`}

// Append a completed load duration to bounded browser history.
function rememberLoad(alias,seconds){if(!seconds||seconds<1)return;const all=historicLoads();const h=all[alias]||[];h.push(seconds);while(h.length>8)h.shift();all[alias]=h;localStorage.setItem('visllamaLoadHistory',JSON.stringify(all))}

// Infer a best-effort loading phase from logs; it is not engine progress telemetry.
function inferLoadPhase(alias){const t=LAST_STATUS?.log_tail||'';const lines=t.split(/\r?\n/).filter(x=>x.toLowerCase().includes(String(alias).toLowerCase())||/load_model|loading model|allocat|offload|layer \d+\/\d+|metadata|backend|context/i.test(x));const x=(lines.slice(-12).join('\n')).toLowerCase();const layer=[...x.matchAll(/layer\s+(\d+)\/(\d+)/g)].pop();if(layer)return `Loading tensors - layer ${layer[1]}/${layer[2]}`;if(/offload/.test(x))return 'Offloading tensors to GPU';if(/allocat|vram/.test(x))return 'Allocating VRAM';if(/backend|cuda/.test(x))return 'Initializing backend';if(/metadata/.test(x))return 'Reading model metadata';if(/load_model|loading model/.test(x))return 'Reading model';return 'Starting model process'}

function syncServerButtons(j=LAST_STATUS){const running=!!(j&&j.running),router=$('serverMode').value==='router',routerRunning=running&&j.mode==='router';const hasModels=(ROUTER_PRESETS||[]).some(p=>p.enabled);$('startBtn').disabled=SETUP_REQUIRED||SERVER_ACTION_BUSY||running||(router&&!hasModels);$('startBtn').title=router&&!hasModels?'Add or enable a model in Manage Models first.':'';$('stopBtn').disabled=SERVER_ACTION_BUSY||!running;$('startBtn').textContent=SERVER_ACTION_BUSY&&!running?'Starting...':router?'Start Router':'Start direct server';$('stopBtn').textContent=SERVER_ACTION_BUSY&&running?'Stopping...':(running?j.mode==='router':router)?'Stop Router':'Stop direct server';$('dashStopCompute').disabled=!routerRunning||!j?.proxy_running;$('openServer').disabled=false;$('applyRouterConfig').disabled=!routerRunning;syncEditorActions();}

function routerSettingsDirty(){if(!CFG?.router_service)return false;const c=CFG.router_service;return $('routerHost').value.trim()!==String(c.host??'0.0.0.0')||$('routerPort').value.trim()!==String(c.port??8080)||$('routerMax').value.trim()!==String(c.models_max??4)||$('routerThreadsHttp').value.trim()!==String(c.threads_http??'')||$('routerAutoload').checked!==(c.autoload!==false)}

function syncRouterSettingsDirty(){$('routerSettingsUnsaved').classList.toggle('hidden',!routerSettingsDirty())}

async function saveRouterSettings(showToast=true){const payload={host:effectiveRouterHost(),port:effectiveRouterPort(),models_max:$('routerMax').value,autoload:$('routerAutoload').checked,threads_http:$('routerThreadsHttp').value};const j=await post('/api/router-settings-save',payload,{label:'Saving Router service settings...'});CFG.router_service=j.router_service||payload;const saved=CFG.router_service;$('routerHost').value=saved.host;$('routerPort').value=saved.port;$('routerMax').value=saved.models_max;$('routerThreadsHttp').value=saved.threads_http||'';$('routerAutoload').checked=saved.autoload!==false;syncRouterSettingsDirty();if(showToast)toast('Router service settings saved');return j}

async function refreshRouterPresets(){try{const j=await post('/api/router-presets');ROUTER_PRESETS=j.presets||[];$('routerPresetPath').textContent='Catalog: '+(j.json_file||'')+'; build-specific Router INIs are kept synchronized; Apply config reloads them into running build engines when possible.';renderRouterPresets();updateCommand()}catch(e){toast(e.message,true)}}

// Prevent polling rerenders from replacing controls during an active interaction.
function routerInteractionActive(){const a=document.activeElement;return !!(a&&$('routerPresets')&&$('routerPresets').contains(a)&&/^(SELECT|INPUT|BUTTON)$/.test(a.tagName))}

// Router status projects only context, parallelism and load-mode arguments from
// the running child. This is not its full command line; use raw launch logs to
// verify GPU placement and other options omitted by the backend privacy filter.
function runningModelArgs(model){return Array.isArray(model?.status?.args)?model.status.args:[]}

// Find a named argument’s value in the running command representation.
function argumentValue(argv,flags){for(let i=0;i<argv.length;i++){const arg=String(argv[i]);for(const flag of flags){if(arg===flag)return i+1<argv.length?String(argv[i+1]):null;if(arg.startsWith(flag+'='))return arg.slice(flag.length+1)}}return null}

// Compare saved options with observable running arguments after a reload.
// A completed HTTP load request alone does not prove the child adopted every setting.
function savedRuntimeMismatch(p,model){const argv=runningModelArgs(model);if(!argv.length||model?.status?.value!=='loaded')return [];const saved=new Map((p.options||[]).filter(kv=>Array.isArray(kv)&&kv.length>=2));const checks=[['ctx-size',['--ctx-size','-c']],['parallel',['--parallel','-np']],['load-mode',['--load-mode','-lm']]];return checks.filter(([key,flags])=>saved.has(key)&&String(saved.get(key))!==argumentValue(argv,flags)).map(([key])=>key)}

// Refresh live state and find the requested alias for lifecycle decisions.
async function currentRouterModel(alias,runtimeToken=LAST_STATUS?.runtime_token){const j=await post('/api/router-models',{}, {busy:false});if(runtimeToken&&j.runtime_token&&runtimeToken!==j.runtime_token)throw new Error('Runtime changed. Refresh status and retry the action.');return (j.result?.data||[]).find(m=>m.id===alias)||null}

// Poll to an explicit target state or fail on timeout; callers use this as
// a load/unload barrier before applying or verifying another operation.
async function waitForRouterModel(alias,expected,timeoutMs,runtimeToken=LAST_STATUS?.runtime_token){const deadline=Date.now()+timeoutMs;while(Date.now()<deadline){const model=await currentRouterModel(alias,runtimeToken),state=model?.status?.value;if(state===expected)return model;if(expected==='loaded'&&(state==='failed'||(state==='unloaded'&&model?.status?.failed)))throw new Error(`${alias} failed to load; check Logs / Diagnostics.`);await new Promise(resolve=>setTimeout(resolve,650))}throw new Error(`${alias} did not reach ${expected} within ${Math.round(timeoutMs/1000)} seconds. Its previous settings may still be running; check Router / Serving.`)}

async function saveRouterRowChange(endpoint,payload,message){
 try{const j=await post(endpoint,payload,{label:message+'...'});ROUTER_PRESETS=j.presets||[];renderRouterPresets();renderModelLibrary();if(LAST_STATUS?.running&&LAST_STATUS?.mode==='router'){try{const applied=await applyRouterConfig(false,false);toast(applied.restart_required?message+'. Restart Router to update running engines.':message+'; Router catalog updated.')}catch(e){toast(message+'. '+e.message,true)}}else toast(message)}catch(e){toast(e.message,true);await refreshRouterPresets()}
}

// Both model-control surfaces use runtime ownership, not native build availability.
function routerModelControls(p){
 const model=liveFor(p.alias),engine=(LAST_STATUS?.router_engines||[]).find(e=>(e.models||[]).includes(p.alias));
 const running=!!(LAST_STATUS?.running&&LAST_STATUS.mode==='router'),pending=MODEL_ACTION_PENDING.get(p.alias);
 const state=!running?'unloaded':MODEL_STATUS_ERROR?'unknown':!MODEL_STATUS_FETCHED?'checking':model?.status?.value||'unloaded';
 let loadReason='',unloadReason='';
 if(!running)loadReason=unloadReason='Start Router first.';
 else if(pending)loadReason=unloadReason='Wait for the current model action to finish.';
 else {
  if(!p.enabled)loadReason='Enable this model in Manage Models first.';
  else if(!engine||engine.build!==p.build)loadReason='Restart Router to apply the saved model/build assignment.';
  else if(!engine.running&&!engine.managed)loadReason='The native Router engine is stopped. Restart Router.';
  else if(['loaded','loading','sleeping','unloading'].includes(state))loadReason='Unload the model before loading it again.';
  else if(['checking','unknown'].includes(state))loadReason='Waiting for confirmed model status. Check Logs / Diagnostics if this persists.';
  else if(engine.managed&&engine.running)loadReason='Unload the existing model process before retrying.';
  if(!engine)unloadReason='This model is not in the running Router.';
  else if(!engine.managed&&!engine.running)unloadReason='The native Router engine is stopped. Restart Router.';
  else if(!(['loaded','loading','sleeping'].includes(state)||(engine.managed&&engine.running)))unloadReason='The model is not loaded.';
 }
 return {state,engine,pending,loadReason,unloadReason};
}

function renderRouterPresets(){
 if(!$('routerPresets'))return;
 const known=new Set((CFG?.builds||[]).map(b=>b.name)),needle=($('routerSearch')?.value||'').toLowerCase();
 const filtered=ROUTER_PRESETS.filter(p=>!needle||(p.alias+' '+(p.model||'')+' '+(p.build||'')).toLowerCase().includes(needle));
 const rows=filtered.map(p=>{
  const m=liveFor(p.alias),st=m?.status?.value||'unloaded',failed=!!m?.status?.failed;
  const sec=st==='loading'?loadSeconds(p.alias):0,typ=st==='loading'?typicalLoad(p.alias):'';
  const mismatched=savedRuntimeMismatch(p,m),activeArgs=runningModelArgs(m);
  const runtimeNote=mismatched.length?`<div class="error">Running settings differ from saved preset: ${esc(mismatched.join(', '))}</div>`:'';
  const status=(st==='loading'?`<span class="badge loading">loading</span><div class="loading-track"><span></span></div><div class="load-detail"><span class="load-phase">${esc(inferLoadPhase(p.alias))}</span><br>Elapsed ${fmtSecs(sec)}${typ?` - typical ${typ}`:''}</div>`:`<span class="badge ${failed?'failed':esc(st)}">${failed?'failed':esc(st)}</span>`)+runtimeNote;
  const build=p.engine&&p.engine!=='llamacpp'?esc((CFG?.engine_builds||[]).find(b=>b.id===p.build)?.name||p.build):`<select data-r-build="${esc(p.alias)}" class="router-build-select" aria-label="Build for ${esc(p.alias)}">${(CFG?.builds||[]).map(x=>`<option value="${esc(x.name)}" ${x.name===p.build?'selected':''}>${esc(x.name)}</option>`).join('')}</select>${p.build&&known.has(p.build)?'':'<div class="error">Build missing</div>'}`;
  const startup=`<select data-r-startup="${esc(p.alias)}" aria-label="Load ${esc(p.alias)} at startup"><option value="manual" ${!p.load_on_startup?'selected':''}>Manual</option><option value="startup" ${p.load_on_startup?'selected':''}>Load at Router start</option></select>`;
  const main=`<tr><td><b>${esc(p.alias)}</b><div class="muted">${esc(p.model||'')}</div></td><td data-label="Build">${build}</td><td class="status-cell" data-label="Status">${status}</td><td data-label="Startup">${startup}</td></tr>`;
  const running=LAST_STATUS?.running&&LAST_STATUS?.mode==='router';
  const pending=MODEL_ACTION_PENDING.get(p.alias),controls=routerModelControls(p);
  const locked=running&&(st==='loaded'||st==='loading')?'disabled title="Unload the model first"':'';
  const actions=`<tr class="router-action-row"><td colspan="4"><div class="router-action-bar"><button data-r-load="${esc(p.alias)}" ${controls.loadReason?'disabled':''} title="${esc(controls.loadReason)}">Load</button><button class="danger" data-r-unload="${esc(p.alias)}" ${controls.unloadReason?'disabled':''} title="${esc(controls.unloadReason)}">${pending==='unload'?'Unloading...':'Unload'}</button><button data-r-edit="${esc(p.alias)}">Edit</button><button data-r-clone="${esc(p.alias)}">Clone</button><button data-r-args="${esc(p.alias)}" ${activeArgs.length?'':'disabled'}>Copy running arguments</button><button data-r-toggle="${esc(p.alias)}" ${p.enabled?locked:''}>${p.enabled?'Disable':'Enable'}</button><button class="danger" data-r-delete="${esc(p.alias)}" ${locked}>Delete</button></div></td></tr>`;
  return main+actions
 }).join('');
 $('routerPresets').innerHTML=rows?`<table class="router-table"><thead><tr><th>Model</th><th>Engine build</th><th>Status</th><th>Startup</th></tr></thead><tbody>${rows}</tbody></table>`:'<div class="empty-state">No matching model presets. Open Manage Models to add one.</div>';
 updateCommand();
 $('routerPresets').querySelectorAll('[data-r-build]').forEach(sel=>sel.onchange=()=>saveRouterRowChange('/api/router-preset-build',{alias:sel.dataset.rBuild,build:sel.value},'Build assignment saved'));
 $('routerPresets').querySelectorAll('[data-r-startup]').forEach(sel=>sel.onchange=()=>saveRouterRowChange('/api/router-preset-startup',{alias:sel.dataset.rStartup,load_on_startup:sel.value==='startup'},'Startup choice saved'));
 $('routerPresets').querySelectorAll('[data-r-edit]').forEach(btn=>btn.onclick=()=>editPresetInDrawer(btn.dataset.rEdit,false));
 $('routerPresets').querySelectorAll('[data-r-clone]').forEach(btn=>btn.onclick=()=>editPresetInDrawer(btn.dataset.rClone,true));
 $('routerPresets').querySelectorAll('[data-r-args]').forEach(btn=>btn.onclick=async()=>{try{const model=await currentRouterModel(btn.dataset.rArgs),argv=runningModelArgs(model);if(!argv.length)throw new Error('Running child arguments are not available yet');await navigator.clipboard.writeText(argv.join(' '));toast('Running llama.cpp arguments copied')}catch(e){toast(e.message,true)}});
 $('routerPresets').querySelectorAll('[data-r-load]').forEach(btn=>btn.onclick=()=>routerAction('load',btn.dataset.rLoad));
 $('routerPresets').querySelectorAll('[data-r-unload]').forEach(btn=>btn.onclick=()=>routerAction('unload',btn.dataset.rUnload));
 $('routerPresets').querySelectorAll('[data-r-toggle]').forEach(btn=>btn.onclick=()=>{const p=ROUTER_PRESETS.find(x=>x.alias===btn.dataset.rToggle);if(p)saveRouterRowChange('/api/router-preset-toggle',{alias:p.alias,enabled:!p.enabled},p.enabled?'Model disabled':'Model enabled')});
 $('routerPresets').querySelectorAll('[data-r-delete]').forEach(btn=>btn.onclick=()=>{const alias=btn.dataset.rDelete;if(confirm(`Delete model preset ${alias}? The GGUF file will remain on disk.`))saveRouterRowChange('/api/router-preset-delete',{alias},'Model deleted')});
 syncServerButtons();updateDashboard()
}


// Poll live model status from the merged internal Router engines.
async function refreshRouterModels(force=false){
 if(MODEL_STATUS_BUSY){if(force)MODEL_STATUS_PENDING=true;return}
 if(!LAST_STATUS?.running||LAST_STATUS?.mode!=='router'){
  MODEL_STATUS_FETCHED=false;MODEL_STATUS_ERROR=false;LIVE_ROUTER_MODELS=[];LOAD_TRACK.clear();globalThis.VisLlamaChat?.syncLoadedModels?.();
  $('routerModels').innerHTML='<span class="muted">Router is not running.</span>';renderRouterPresets();renderModelLibrary();updateDashboard();return
 }
 MODEL_STATUS_BUSY=true;
 try{
  const j=await post('/api/router-models',{}, {busy:false});
  if(!LAST_STATUS?.running||LAST_STATUS.mode!=='router')return;
  if(j.runtime_token&&LAST_STATUS.runtime_token&&j.runtime_token!==LAST_STATUS.runtime_token)return;
  const data=j.result?.data||[],now=Date.now();
  for(const m of data){const st=m.status?.value||'unknown',prev=LOAD_TRACK.get(m.id);if(st==='loading'&&!prev)LOAD_TRACK.set(m.id,{started:now,state:'loading'});if(st==='loaded'&&prev){rememberLoad(m.id,(now-prev.started)/1000);LOAD_TRACK.delete(m.id)}if(st!=='loading'&&st!=='loaded'&&prev)LOAD_TRACK.delete(m.id)}
  LIVE_ROUTER_MODELS=data;MODEL_STATUS_FETCHED=true;MODEL_STATUS_ERROR=!!j.result?.incomplete;globalThis.VisLlamaChat?.syncLoadedModels?.(j.runtime_token,data);
  $('routerModels').innerHTML='<span class="muted">Live status is integrated into the Configured models table above.</span>';
  if(!routerInteractionActive())renderRouterPresets();renderModelLibrary();updateDashboard()
 }catch(e){if(e.pollPaused||e.controlTransportFailure)return;MODEL_STATUS_ERROR=true;globalThis.VisLlamaChat?.syncLoadedModels?.(false);renderModelLibrary();$('routerModels').innerHTML=`<span class="error">${esc(e.message)}</span>`;updateDashboard()}
 finally{MODEL_STATUS_BUSY=false;syncEditorActions();if(MODEL_STATUS_PENDING){MODEL_STATUS_PENDING=false;refreshRouterModels()}}
}

// Push saved Router config into already-running build engines when possible.
async function applyRouterConfig(forceUnload=false,busy=true,runtimeToken=LAST_STATUS?.runtime_token){const j=await post('/api/router-apply-config',{force_unload_moved:forceUnload,runtime_token:runtimeToken},{label:busy?'Applying Router configuration...':undefined,busy});if(j.applied){await status(true);await refreshRouterModels();return j}if(j.restart_required)throw new Error((j.reason||'Router restart required')+' Restart Router mode to create the required build engine.');throw new Error(j.reason||'Router configuration could not be applied live.')}

// Load or unload one model through its assigned internal build engine.
async function routerAction(kind,model){
 if(MODEL_ACTION_PENDING.has(model))return;
 const runtimeToken=LAST_STATUS?.runtime_token;
 MODEL_ACTION_PENDING.set(model,kind);renderDashModels();renderRouterPresets();
 try{
  if(kind==='load'&&LAST_STATUS?.running&&LAST_STATUS?.mode==='router'){
   const preset=ROUTER_PRESETS.find(p=>p.alias===model),engine=(LAST_STATUS.router_engines||[]).find(e=>(e.models||[]).includes(model));
   if(!engine)throw new Error(`Model ${model} is not present in the running Router configuration. Restart Router mode to apply the saved model/build assignment.`);
   if(preset?.build&&engine.build!==preset.build)throw new Error(`Saved build for ${model} is ${preset.build}, but the running Router still maps it to ${engine.build}. Restart Router mode before loading this model.`)
  }
  toast(`${kind==='load'?'Loading':'Unloading'} ${model}...`);
  const result=await post(kind==='load'?'/api/router-load':'/api/router-unload',{model,runtime_token:runtimeToken});
  if(result.gpu_priority_plan){const plan=result.gpu_priority_plan;toast(plan.weights_mib?`${model}: requested layer split ${plan.devices.map((id,i)=>id+' '+plan.weights_mib[i]).join(', ')}`:`${model}: ${plan.devices.join(' -> ')} preferred; ${plan.reserve_mib} MiB free VRAM target per GPU`)}
  const confirmed=await waitForRouterModel(model,kind==='load'?'loaded':'unloaded',kind==='load'?300000:30000,runtimeToken);
  const index=LIVE_ROUTER_MODELS.findIndex(m=>m.id===model);
  if(index>=0)LIVE_ROUTER_MODELS[index]=confirmed;else LIVE_ROUTER_MODELS.push(confirmed);
  MODEL_STATUS_FETCHED=true;MODEL_STATUS_ERROR=false;
  toast(`${model} ${kind==='load'?'loaded':'unloaded'}`);
 }catch(e){toast(e.message,true)}
 finally{MODEL_ACTION_PENDING.delete(model);await status(true);renderDashModels();renderRouterPresets();refreshRouterModels(true)}
}
