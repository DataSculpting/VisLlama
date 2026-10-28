// VisLlama: dashboard. Loaded in the order declared in templates/partials/scripts.html.

// Summarize shared Router and telemetry state without introducing a second
// lifecycle implementation. Load/unload actions delegate to the Router handlers.

// Refresh Dashboard summary cards and recent activity.
function updateDashboard(){if(!$('dashServerState'))return;const j=LAST_STATUS||{};const run=!!j.running;$('dashServerState').textContent=run?(j.mode==='router'?(j.readiness?.phase==='ready'?'Router ready':j.readiness?.phase==='partial'?'Partial startup':j.readiness?.phase==='degraded'?'Router degraded':'Router running'):'Single model running'):(j.crashed?'Crashed':'Stopped');$('dashServerState').className='metric-value '+(run?(j.readiness&&j.readiness.phase!=='ready'?'warning':'running'):(j.crashed?'error':''));$('dashServerNote').textContent=run&&j.started?'Started '+j.started:(j.crashed?'Check Logs / Diagnostics.':'Ready to start Router mode.');$('dashApi').textContent=run&&j.mode==='router'?`http://${j.router_host||effectiveRouterHost()}:${j.router_port||effectiveRouterPort()}/v1`:'Not active';const live=run&&j.mode==='router'?LIVE_ROUTER_MODELS:[];const loaded=live.filter(m=>(m.status?.value||'')==='loaded').length,loading=live.filter(m=>(m.status?.value||'')==='loading').length;$('dashModelCount').textContent=`${ROUTER_PRESETS.length} configured`;$('dashModelNote').textContent=MODEL_STATUS_ERROR?'Model status is temporarily unavailable.':live.length?`${loaded} loaded${loading?`, ${loading} loading`:''}, ${Math.max(0,live.length-loaded-loading)} unloaded`:(run&&j.mode==='router'?(MODEL_STATUS_ERROR?'Model status is temporarily unavailable.':MODEL_STATUS_FETCHED?'No models reported by Router.':'Checking model status...'):'Router is not running.');$('dashLog').textContent=(j.log_tail||'No log yet.').split(/\r?\n/).slice(-28).join('\n');renderDashModels();renderDashLoading()}

// Render quick load/unload controls for configured Router models.
function renderDashModels(){
 const root=$('dashModels');if(!root)return;
 const rows=ROUTER_PRESETS.map(p=>{
  const {state,engine,pending,loadReason,unloadReason}=routerModelControls(p);
  const action=['loaded','loading','sleeping'].includes(state)||(engine?.managed&&engine.running)?'unload':'load';
  const reason=action==='unload'?unloadReason:loadReason,disabled=!!reason;
  const label=pending?(pending==='unload'?'Unloading...':'Loading...'):action==='unload'?'Unload':'Load';
  const family=p.engine&&p.engine!=='llamacpp'?p.engine:'llama.cpp';
  const selection=p.engine&&p.engine!=='llamacpp'?(p.settings?.['gpu-selection']??p.native_config?.gpu):p.ui?.devices;
  const devices=Array.isArray(selection)?(selection.length?selection.join(','):'Engine default'):selection===undefined||selection===null||selection===''?'Engine default':String(selection).replace(/\s*,\s*/g,',');
  return `<tr><td><b>${esc(p.alias)}</b><div class="muted">${esc(p.build||'')}</div></td><td>${esc(family)}</td><td class="dash-gpus">${esc(devices)}</td><td><span class="badge ${esc(state)}">${esc(state)}</span></td><td><button data-dash-model="${esc(p.alias)}" data-dash-action="${action}" ${disabled?'disabled':''} title="${esc(reason)}">${label}</button></td></tr>`
 }).join('');
 const markup=rows?`<table class="router-table"><thead><tr><th>Model / build</th><th>Engine</th><th>Saved GPU selection</th><th>Status</th><th>Action</th></tr></thead><tbody>${rows}</tbody></table>`:'<div class="empty-state">No configured models yet.</div>';
 if(markup!==DASH_MODELS_MARKUP){root.innerHTML=markup;DASH_MODELS_MARKUP=markup}
}

// Render current model-load phase, elapsed time, and local historical timing.
function renderDashLoading(){const loading=(LIVE_ROUTER_MODELS||[]).find(m=>(m.status?.value||'')==='loading');const box=$('dashLoading');if(!box)return;if(!loading){box.classList.add('hidden');box.innerHTML='';return}const sec=loadSeconds(loading.id),typ=typicalLoad(loading.id);box.classList.remove('hidden');box.innerHTML=`<div class="card" style="margin:0 0 10px"><b>Loading ${esc(loading.id)}</b><div class="loading-track"><span></span></div><div class="load-detail"><span class="load-phase">${esc(inferLoadPhase(loading.id))}</span> &nbsp; Elapsed ${fmtSecs(sec)}${typ?` &nbsp; Typical ${typ}`:''}</div></div>`}

function renderHardwareStrip(j){
 const root=$('hardwareItems');if(!root)return;
 const n=j?.nvidia?.gpus||[],extra=[...(j?.amd?.gpus||[]),...(j?.intel?.gpus||[])],g=[...n,...extra],s=j?.system||{};
 const meter=(label,detail,pct,system=false)=>`<div class="hardware-item${system?' system':''}"><div class="hardware-label">${esc(label)}</div><div class="hardware-value">${esc(detail)}</div>${Number.isFinite(pct)?`<div class="hardware-meter" role="meter" aria-label="${esc(label)} usage" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${Math.round(Math.max(0,Math.min(100,pct)))}"><span style="width:${Math.max(0,Math.min(100,pct)).toFixed(1)}%"></span></div>`:''}</div>`;
 const valid=n=>typeof n==='number'&&Number.isFinite(n);
 root.innerHTML=g.map(x=>meter(`${x.vendor&&x.vendor!=='NVIDIA'?x.vendor+' ':''}GPU ${x.index} / ${x.name}`,valid(x.memory_used_mib)&&x.memory_total_mib>0?`${(x.memory_used_mib/1024).toFixed(1)} / ${(x.memory_total_mib/1024).toFixed(1)} GiB`:x.vendor&&x.vendor!=='NVIDIA'?'Memory unavailable':'VRAM unavailable',valid(x.memory_used_mib)&&x.memory_total_mib>0?100*x.memory_used_mib/x.memory_total_mib:null)).join('')+(!g.length?meter('GPU','Telemetry unavailable',null):'')+meter('CPU',valid(s.cpu_percent)?s.cpu_percent.toFixed(0)+'% host load':'Unavailable',valid(s.cpu_percent)?s.cpu_percent:null,true)+meter('RAM',valid(s.memory_used_mib)&&s.memory_total_mib>0?`${(s.memory_used_mib/1024).toFixed(1)} / ${(s.memory_total_mib/1024).toFixed(1)} GiB`:'Unavailable',valid(s.memory_used_mib)&&s.memory_total_mib>0?100*s.memory_used_mib/s.memory_total_mib:null,true);
 const used=g.reduce((n,x)=>n+(Number(x.memory_used_mib)||0),0),total=g.reduce((n,x)=>n+(Number(x.memory_total_mib)||0),0);
 $('dashGpu').textContent=extra.length?`${g.length} GPU${g.length===1?'':'s'}`:total?`${(used/1024).toFixed(1)} / ${(total/1024).toFixed(1)} GiB`:'Unavailable';
 $('dashGpuNote').textContent=extra.length?'Per-device memory shown below; memory pools are not combined.':total?`${g.length} NVIDIA GPU${g.length===1?'':'s'} / host-wide usage`:'No GPU telemetry available.';
 renderDashHardware(j);
}

// Present the existing sample without changing placement or combining pools.
function renderDashHardware(j){
 const root=$('dashHardwareDevices');if(!root)return;
 const valid=n=>typeof n==='number'&&Number.isFinite(n),g=[...(j?.nvidia?.gpus||[]),...(j?.amd?.gpus||[]),...(j?.intel?.gpus||[])];
 root.innerHTML=g.map(x=>{
  const memory=valid(x.memory_used_mib)&&valid(x.memory_total_mib)&&x.memory_total_mib>0;
  const pct=memory?Math.max(0,Math.min(100,x.memory_used_mib/x.memory_total_mib*100)):null;
  return `<div class="dashboard-device"><div class="dashboard-device-head"><span class="dashboard-device-name">${esc(x.vendor&&x.vendor!=='NVIDIA'?x.vendor+' ':'')}GPU ${esc(x.index??'?')} · ${esc(x.name||'Name unavailable')}</span><span class="dashboard-device-value">${memory?`${(x.memory_used_mib/1024).toFixed(1)} / ${(x.memory_total_mib/1024).toFixed(1)} GiB`:'Unavailable'}</span></div>${memory?`<div class="hardware-meter" role="meter" aria-label="${esc('GPU '+(x.index??'?')+' memory usage')}" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${Math.round(pct)}"><span style="width:${pct.toFixed(1)}%"></span></div>`:''}<div class="dashboard-device-meta"><span>${valid(x.utilization_percent)?Math.round(x.utilization_percent)+'% utilization':'Utilization unavailable'}</span><span>${valid(x.temperature_c)?Math.round(x.temperature_c)+'°C':'Temperature unavailable'}</span></div></div>`;
 }).join('')||'<span class="muted">GPU telemetry unavailable.</span>';
 const s=j?.system||{},ram=valid(s.memory_used_mib)&&valid(s.memory_total_mib)&&s.memory_total_mib>0;
 $('dashHostMemory').textContent=ram?`Host RAM: ${(s.memory_used_mib/1024).toFixed(1)} / ${(s.memory_total_mib/1024).toFixed(1)} GiB`:'Host RAM unavailable.';
}
