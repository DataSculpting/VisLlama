// VisLlama: stats. Loaded in the order declared in templates/partials/scripts.html.

// Live hardware graphs and historical model aggregates use separate data.
// Unavailable samples stay distinguishable from measured zero activity.

function statsInt(n){return Math.round(Number(n)||0).toLocaleString()}

// Calculate throughput from token/time totals; no duration means no measured rate.
function statsRate(tokens,seconds){return seconds>0?(tokens/seconds).toFixed(1):'--'}

// Compute the earliest date included in the chosen history range.
function statsRangeStart(){const days=$('modelStatsRange').value;if(days==='all')return '';const d=new Date();d.setHours(0,0,0,0);d.setDate(d.getDate()-(Number(days)-1));return [d.getFullYear(),String(d.getMonth()+1).padStart(2,'0'),String(d.getDate()).padStart(2,'0')].join('-')}

// Assign a date to the selected historical aggregation period.
function statsBucket(date){const group=$('modelStatsGroup').value;if(group==='year')return date.slice(0,4);if(group==='month')return date.slice(0,7);if(group==='week'){const d=new Date(date+'T12:00:00');d.setDate(d.getDate()-((d.getDay()+6)%7));return [d.getFullYear(),String(d.getMonth()+1).padStart(2,'0'),String(d.getDate()).padStart(2,'0')].join('-')}return date}

// Resolve internal external-engine IDs for presentation only; history/filter IDs stay intact.
function statsBuildLabel(id){
 const build=(CFG?.engine_builds||[]).find(b=>b.id===id);
 return build?.name||(!id?'Build unknown':/^engine-/.test(id)?'Unregistered build: '+id:id);
}

function renderModelStats(){
 if(!MODEL_STATS_DATA)return;
 const data=MODEL_STATS_DATA,cutoff=statsRangeStart(),period=(data.days||[]).filter(r=>!cutoff||r.date>=cutoff);
 const aliases=[...new Set([...(data.presets||[]).map(p=>p.alias),...(data.days||[]).map(d=>d.alias)])].filter(Boolean).sort((a,b)=>a.localeCompare(b));
 const list=[{alias:'*',label:'All models'},...aliases.map(alias=>({alias,label:alias}))];
 $('modelStatsList').innerHTML=list.map(x=>{const total=period.filter(d=>x.alias==='*'||x.alias===d.alias).reduce((n,d)=>n+(d.prompt_tokens||0)+(d.decode_tokens||0),0);return `<button type="button" data-stats-model="${esc(x.alias)}" class="${MODEL_STATS_SELECTION===x.alias?'active':''}">${esc(x.label)}<small>${statsInt(total)} tokens in range</small></button>`}).join('')||'<span class="muted">No saved models yet.</span>';
 $('modelStatsList').querySelectorAll('button').forEach(b=>b.onclick=()=>{MODEL_STATS_SELECTION=b.dataset.statsModel;MODEL_STATS_CONFIG='all';renderModelStats()});
 const configs=new Map();for(const p of [...(data.presets||[]),...(data.days||[])])if(MODEL_STATS_SELECTION==='*'||p.alias===MODEL_STATS_SELECTION)configs.set(p.config_id,`${statsBuildLabel(p.build)} | ${p.config_id}`);
 const configSelect=$('modelStatsConfig');configSelect.innerHTML='<option value="all">All configurations</option>'+[...configs].sort((a,b)=>a[1].localeCompare(b[1])).map(([id,label])=>`<option value="${esc(id)}">${esc(label)}</option>`).join('');if(!configs.has(MODEL_STATS_CONFIG))MODEL_STATS_CONFIG='all';configSelect.value=MODEL_STATS_CONFIG;
 const rows=period.filter(d=>(MODEL_STATS_SELECTION==='*'||d.alias===MODEL_STATS_SELECTION)&&(MODEL_STATS_CONFIG==='all'||d.config_id===MODEL_STATS_CONFIG));
 const sums=rows.reduce((a,d)=>{a.p+=d.prompt_tokens||0;a.g+=d.decode_tokens||0;a.ps+=d.prompt_seconds||0;a.gs+=d.decode_seconds||0;return a},{p:0,g:0,ps:0,gs:0});
 $('modelStatsSummary').innerHTML=[['Prompt tokens',statsInt(sums.p)],['Generated tokens',statsInt(sums.g)],['Prefill speed',statsRate(sums.p,sums.ps)+' tok/s'],['Decode speed',statsRate(sums.g,sums.gs)+' tok/s']].map(([label,value])=>`<div class="metric-card"><div class="metric-label">${esc(label)}</div><div class="metric-value">${esc(value)}</div></div>`).join('');
 const bucket=new Map();
 for(const r of rows){const label=statsBucket(r.date);const b=bucket.get(label)||{p:0,g:0,ps:0,gs:0};b.p+=r.prompt_tokens||0;b.g+=r.decode_tokens||0;b.ps+=r.prompt_seconds||0;b.gs+=r.decode_seconds||0;bucket.set(label,b)}
 const metric=$('modelStatsMetric').value,points=[...bucket].sort((a,b)=>a[0].localeCompare(b[0])).map(([label,b])=>({label,value:metric==='tokens'?b.p+b.g:metric==='prefill'?(b.ps?b.p/b.ps:0):(b.gs?b.g/b.gs:0)}));
 const highest=Math.max(1,...points.map(p=>p.value));$('modelStatsChart').innerHTML=points.length?points.map(p=>`<div class="model-stats-bar" style="height:${Math.max(2,Math.round(p.value/highest*135))}px" title="${esc(p.label)}: ${metric==='tokens'?statsInt(p.value):p.value.toFixed(1)} ${metric==='tokens'?'tokens':'tok/s'}" role="img" aria-label="${esc(p.label)}: ${metric==='tokens'?statsInt(p.value):p.value.toFixed(1)}"></div>`).join(''):'<span class="muted">No model activity recorded in this range.</span>';
 const grouped=new Map();for(const r of rows){const label=statsBucket(r.date),key=[label,r.alias,r.config_id].join('\u001e');const v=grouped.get(key)||{date:label,alias:r.alias,build:r.build,config_id:r.config_id,prompt_tokens:0,decode_tokens:0,prompt_seconds:0,decode_seconds:0};for(const k of ['prompt_tokens','decode_tokens','prompt_seconds','decode_seconds'])v[k]+=r[k]||0;grouped.set(key,v)}const ordered=[...grouped.values()].sort((a,b)=>b.date.localeCompare(a.date));$('modelStatsDays').innerHTML=ordered.length?`<table><thead><tr><th>Period</th><th>Model</th><th>Prompt</th><th>Generated</th><th>Prefill tok/s</th><th>Decode tok/s</th></tr></thead><tbody>${ordered.slice(0,90).map(r=>`<tr><td>${esc(r.date)}</td><td>${esc(r.alias)}<br><small class="muted">${esc(statsBuildLabel(r.build))} | ${esc(r.config_id)}</small></td><td>${statsInt(r.prompt_tokens)}</td><td>${statsInt(r.decode_tokens)}</td><td>${statsRate(r.prompt_tokens,r.prompt_seconds)}</td><td>${statsRate(r.decode_tokens,r.decode_seconds)}</td></tr>`).join('')}</tbody></table>`:'<p class="muted">No samples yet. Start a model and send a request to begin its history.</p>';
 $('modelStatsNote').textContent=`History: ${data.path||'logs/model-stats.jsonl'}. Speeds are token counts divided by active processing time. The table shows up to 90 most recent period rows.${data.warning?' '+data.warning:''}`;
}

async function refreshModelStats(){if(MODEL_STATS_BUSY)return;MODEL_STATS_BUSY=true;try{MODEL_STATS_DATA=await post('/api/model-stats',{}, {busy:false});renderModelStats()}catch(e){if(e.pollPaused||e.controlTransportFailure||e.httpStatus===409)return;$('modelStatsNote').textContent='Unable to load model history: '+e.message}finally{MODEL_STATS_BUSY=false}}

// Format an available telemetry value while retaining the unavailable fallback.
function gpuVal(v,suffix=''){return v===null||v===undefined?'N/A':`${Number(v).toFixed(Number(v)%1?1:0)}${suffix}`}

// Resolve a GPU metric’s local sample history by its stable telemetry key.
function historyFor(uuid){if(!GPU_HISTORY.has(uuid))GPU_HISTORY.set(uuid,{memory:[],temperature:[],fan:[],utilization:[],power:[]});return GPU_HISTORY.get(uuid)}

// Keep a bounded in-memory telemetry series for sparklines, not saved history.
function pushHist(a,v){if(v!==null&&v!==undefined&&Number.isFinite(Number(v)))a.push(Number(v));else a.push(null);while(a.length>GPU_HISTORY_MAX)a.shift()}

// Draw the compact hardware trend into its existing canvas.
function drawSpark(canvas,values,maxHint){if(!canvas)return;const dpr=window.devicePixelRatio||1;const rect=canvas.getBoundingClientRect();const w=Math.max(40,Math.floor(rect.width*dpr)),h=Math.max(24,Math.floor(rect.height*dpr));if(canvas.width!==w)canvas.width=w;if(canvas.height!==h)canvas.height=h;const c=canvas.getContext('2d');c.clearRect(0,0,w,h);c.strokeStyle='#384248';c.lineWidth=1*dpr;c.beginPath();c.moveTo(0,h-1);c.lineTo(w,h-1);c.stroke();const good=values.filter(v=>v!==null&&Number.isFinite(v));if(good.length<2)return;let max=maxHint||Math.max(...good);let min=0;if(!maxHint){min=Math.min(...good);if(max===min){max=min+1}else{const pad=(max-min)*.12;min-=pad;max+=pad}}c.strokeStyle='#69db93';c.lineWidth=1.5*dpr;c.beginPath();let started=false;values.forEach((v,i)=>{if(v===null||!Number.isFinite(v)){started=false;return}const x=values.length<=1?0:i/(GPU_HISTORY_MAX-1)*w;const y=h-2-((v-min)/(max-min||1))*(h-5);if(!started){c.moveTo(x,y);started=true}else c.lineTo(x,y)});c.stroke()}

function renderSystemStats(s){const node=$('systemDashboard');const cpu=s?.cpu_percent,used=s?.memory_used_mib,total=s?.memory_total_mib;const reason=s?.error?`<div class="muted system-stats-error">${esc(s.error)}</div>`:'';const cpuValue=cpu===null||cpu===undefined?'Unavailable':gpuVal(cpu,'%');const memoryValue=total>0?`${gpuVal(used/1024,' GiB')} / ${gpuVal(total/1024,' GiB')}`:'Unavailable';const pct=total>0?Math.min(100,Math.max(0,100*used/total)):0;node.innerHTML=`<div class="gpu-metric"><div class="gpu-metric-label">CPU load</div><div class="gpu-metric-value">${cpuValue}</div><div class="gpu-meta">Windows reported average across processors</div></div><div class="gpu-metric"><div class="gpu-metric-label">Physical RAM</div><div class="gpu-metric-value">${memoryValue}</div>${total>0?`<div class="system-meter" role="meter" aria-label="RAM used" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${pct.toFixed(0)}"><span style="width:${pct.toFixed(1)}%"></span></div><div class="gpu-meta">${pct.toFixed(0)}% used</div>`:''}</div>${reason}`}


// Combine the current sample only. Each average uses its own available readings
// (a stopped fan at 0% counts; N/A does not). An incomplete VRAM sum is unknown,
// not a smaller number presented as the capacity/usage of all GPUs. Power
// also requires every reading: a partial sum would understate total GPU draw.
function aggregateGpuStats(gpus){
 const values=field=>gpus.map(g=>g[field]).filter(v=>typeof v==='number'&&Number.isFinite(v));
 const average=field=>{const v=values(field);return v.length?v.reduce((a,b)=>a+b,0)/v.length:null};
 const total=field=>{const v=values(field);return v.length&&v.length===gpus.length?v.reduce((a,b)=>a+b,0):null};
 return {memory_used_mib:total('memory_used_mib'),memory_total_mib:total('memory_total_mib'),
  utilization_percent:average('utilization_percent'),temperature_c:average('temperature_c'),
  fan_percent:average('fan_percent'),power_w:total('power_w')};
}

// Summary and individual rows share the same five-column renderer and sparks.
function gpuStatsCard(x,mid,summaryCount=0,alternate=false){
 const title=alternate?`${esc(x.vendor)} / ${esc(x.provider)} GPU ${esc(x.index??'?')} - ${esc(x.name)}`:summaryCount?'All GPUs':`NVIDIA-SMI GPU ${esc(x.index)} - ${esc(x.name)}`;
 const note=summaryCount?`${summaryCount} GPU${summaryCount===1?'':'s'} reporting. VRAM: used / total capacity. Averages exclude unavailable readings.`:
  `${esc(x.uuid||'UUID unavailable')} | Physical nvidia-smi index; do not assume this equals llama.cpp CUDA numbering.`;
 const metrics=[
  ['memory',alternate?'Memory':summaryCount?'Total VRAM':'VRAM',`${gpuVal(x.memory_used_mib,' MiB')} / ${gpuVal(x.memory_total_mib,' MiB')}`],
  ['utilization',summaryCount?'Average compute':'Compute',gpuVal(x.utilization_percent,'%')],
  ['temperature',summaryCount?'Average temperature':'Temperature',gpuVal(x.temperature_c,' C')],
  ['fan',summaryCount?'Average fan':'Fan',gpuVal(x.fan_percent,'%')],
  ['power',summaryCount?'Total power on GPUs':'Power',gpuVal(x.power_w,' W')+(x.power_limit_w!==null&&x.power_limit_w!==undefined?' / '+gpuVal(x.power_limit_w,' W'):'')]
 ];
 const identity=alternate?`${esc(x.uuid||x.pci_bus_id||'Physical identity unavailable')} | Provider index; inference IDs come from llama.cpp. Verified physical isolation unavailable.`:note;
 const semantics=alternate?`<div class="gpu-meta">${esc(Object.entries(x.semantics||{}).map(([k,v])=>`${k.replaceAll('_',' ')}: ${v}`).join(' · '))}</div>`:'';
 return `<div class="gpu-card${summaryCount?' gpu-summary':''}"><div class="gpu-head"><div><div class="gpu-name">${title}</div><div class="gpu-meta">${identity}</div>${semantics}</div></div><div class="gpu-metrics">${metrics.map(([key,label,value])=>`<div class="gpu-metric"><div class="gpu-metric-label">${label}</div><div class="gpu-metric-value">${value}</div><canvas id="${mid}-${key}"></canvas></div>`).join('')}</div></div>`;
}

function renderNvidiaStats(j){
 const n=j.nvidia||{},g=n.gpus||[],summaryKey='visllama:all-gpus';
 $('gpuSampleTime').textContent=n.sampled_at?`Sampled ${n.sampled_at}`:'';
 if(!g.length){GPU_HISTORY.delete(summaryKey);$('gpuDashboard').innerHTML='<span class="muted">NVIDIA telemetry unavailable.</span>';return}
 const rows=[{x:aggregateGpuStats(g),key:summaryKey,mid:'gpu-all',count:g.length},
  ...g.map(x=>({x,key:x.uuid||`nvidia-${x.index}`,mid:`gpu-${String(x.index).replace(/[^0-9]/g,'')}`,count:0}))];
 for(const {x,key} of rows){
  const h=historyFor(key);
  const memPct=x.memory_total_mib&&x.memory_used_mib!==null?100*x.memory_used_mib/x.memory_total_mib:null;
  pushHist(h.memory,memPct);pushHist(h.temperature,x.temperature_c);pushHist(h.fan,x.fan_percent);
  pushHist(h.utilization,x.utilization_percent);pushHist(h.power,x.power_w);
 }
 $('gpuDashboard').innerHTML=rows.map(({x,mid,count})=>gpuStatsCard(x,mid,count)).join('');
 for(const {x,key,mid} of rows){
  const h=historyFor(key);
  drawSpark($(mid+'-memory'),h.memory,100);drawSpark($(mid+'-utilization'),h.utilization,100);
  drawSpark($(mid+'-temperature'),h.temperature,110);drawSpark($(mid+'-fan'),h.fan,100);
  drawSpark($(mid+'-power'),h.power,x.power_limit_w||undefined);
 }
}

// Additional vendors remain individual cards: shared memory, partitions and
// socket sensors cannot safely be added into a cross-vendor capacity total.
function renderGpuStats(j){
 renderNvidiaStats(j);
 const node=$('gpuDashboard'),extra=[...(j.amd?.gpus||[]),...(j.intel?.gpus||[])];
 if(extra.length&&node.querySelector('.gpu-summary .gpu-name'))node.querySelector('.gpu-summary .gpu-name').textContent='NVIDIA GPUs';
 if(extra.length&&!(j.nvidia?.gpus||[]).length)node.innerHTML='';
 const active=new Set();
 extra.forEach((x,i)=>{
  const key=`alternate:${JSON.stringify([x.vendor,x.provider,x.uuid,x.pci_bus_id,x.index])}`,mid=`gpu-extra-${i}`;
  active.add(key);const h=historyFor(key);
  pushHist(h.memory,x.memory_total_mib>0&&x.memory_used_mib!==null?100*x.memory_used_mib/x.memory_total_mib:null);
  pushHist(h.temperature,x.temperature_c);pushHist(h.fan,x.fan_percent);pushHist(h.utilization,x.utilization_percent);pushHist(h.power,x.power_w);
  node.insertAdjacentHTML('beforeend',gpuStatsCard(x,mid,0,true));
  drawSpark($(mid+'-memory'),h.memory,100);drawSpark($(mid+'-utilization'),h.utilization,100);
  drawSpark($(mid+'-temperature'),h.temperature,110);drawSpark($(mid+'-fan'),h.fan,100);drawSpark($(mid+'-power'),h.power,x.power_limit_w||undefined);
 });
 for(const key of GPU_HISTORY.keys())if(key.startsWith('alternate:')&&!active.has(key))GPU_HISTORY.delete(key);
 if(!j.nvidia?.sampled_at){const stamp=j.amd?.sampled_at||j.intel?.sampled_at;$('gpuSampleTime').textContent=stamp?`Sampled ${stamp}`:'';}
 const providers=[...(j.gpu_providers?.nvidia?[j.gpu_providers.nvidia]:[]),...(j.amd?.providers||[]),...(j.intel?.providers||[])];
 if(providers.length)node.insertAdjacentHTML('beforeend',`<details class="card"><summary>GPU monitoring providers</summary><p class="muted">Monitoring availability does not verify inference placement. Refresh status to check installed tools again.</p>${providers.map(p=>`<p><b>${esc(p.id)}</b>: ${esc(p.message||p.status)}${p.version?` (${esc(p.version)})`:''}${p.reference?` Reference: ${esc(p.reference)}`:''}</p>`).join('')}</details>`);
}

// Manual/action refreshes can request one follow-up after an older poll.
let GPU_REFRESH=null,STATUS_REFRESH=null;
function refreshGpuStats(fresh=false){
 if(fresh&&GPU_REFRESH)return GPU_REFRESH.then(()=>refreshGpuStats());
 if(!GPU_REFRESH)GPU_REFRESH=readGpuStats(fresh).finally(()=>{GPU_REFRESH=null});
 return GPU_REFRESH;
}
function status(fresh=false){
 if(fresh&&STATUS_REFRESH)return STATUS_REFRESH.then(()=>status());
 if(!STATUS_REFRESH)STATUS_REFRESH=readStatus().finally(()=>{STATUS_REFRESH=null});
 return STATUS_REFRESH;
}

// Slow control operations must not accumulate identical timer requests.
async function readGpuStats(fresh=false){try{const j=await post('/api/gpu-stats',fresh?{refresh_providers:true}:{}, {busy:false});renderGpuStats(j);renderSystemStats(j.system);renderHardwareStrip(j)}catch(e){if(e.pollPaused||e.controlTransportFailure||e.httpStatus===409)return;renderHardwareStrip(null);$('gpuDashboard').innerHTML=`<span class="error">GPU telemetry error: ${esc(e.message)}</span>`}}

async function readStatus(){try{const j=await post('/api/status',{}, {busy:false});const previous=LAST_STATUS;LAST_STATUS=j;globalThis.VisLlamaChat?.syncLoadedModels?.();if(previous?.running!==j.running||previous?.mode!==j.mode){MODEL_STATUS_FETCHED=false;MODEL_STATUS_ERROR=false;refreshRouterModels(true)}syncServerButtons(j);const canStopCompute=!!(j.running&&j.mode==='router'&&j.proxy_running);$('stopComputeBtn').disabled=!canStopCompute;$('stopComputeNote').textContent=canStopCompute?'Stops active Router/proxy inference connections and immediately restarts the proxy; loaded models stay resident.':'Available only while Router mode compatibility proxy is running.';const engineCount=(j.router_engines||[]).filter(e=>e.running).length;$('stateText').textContent=j.running?(j.mode==='router'?`Running - ${engineCount} Router engine${engineCount===1?'':'s'}`:`Running - PID ${j.pid}`):(j.crashed?'Crashed':'Stopped');if(j.running&&j.readiness)$('stateText').textContent+=' — '+({ready:'Ready',partial:'Partial startup',degraded:'Degraded',checking:'Checking readiness',starting:'Starting'}[j.readiness.phase]||j.readiness.phase);$('stateText').className='status '+(j.running?(j.readiness&&j.readiness.phase!=='ready'?'warning':'running'):(j.crashed?'error':'stopped'));let details=[];if(j.readiness){details.push(`<div><b>Readiness:</b> ${esc(j.readiness.phase)}; public endpoint ${esc(j.readiness.endpoint)}; ${j.readiness.startup_failed||0} startup model(s) failed.</div>`);if(j.readiness.catalog_apply_incomplete)details.push('<div class="warning">Live catalog apply is incomplete. Retry Apply config or restart Router.</div>');for(const engine of j.readiness.engines||[])details.push(`<div><b>${esc(engine.group||engine.build)} readiness:</b> ${esc(engine.state)}</div>`);for(const item of j.readiness.startup_models||[]){if(item.state==='failed')details.push(`<div class="error">${esc(item.alias)}: ${esc(item.error||'Startup failed')}</div>`)}}details.push(`<div><b>Mode:</b> ${esc(j.mode||'single')}</div>`);if(j.build&&j.mode!=='router')details.push(`<div><b>Build:</b> ${esc(j.build)}</div>`);if(j.model)details.push(`<div><b>Model:</b> ${esc(j.model)}</div>`);if(j.mode==='router'&&j.router_host){details.push(`<div><b>Public OpenAI API:</b> http://${esc(j.router_host)}:${esc(j.router_port||8080)} - models: /v1/models</div>`);for(const e of (j.router_engines||[])){details.push(`<div class="muted"><b>${esc(e.build)}:</b> ${e.running?'running':'stopped'}${e.pid?' - PID '+esc(e.pid):''}${e.internal_port?' - 127.0.0.1:'+esc(e.internal_port):''}${(e.models||[]).length?' - '+(e.models||[]).map(esc).join(', '):''}</div>`)}details.push(`<div class="muted"><b>Compatibility proxy:</b> ${j.proxy_running?'running':'stopped'}${j.proxy_pid?' - PID '+esc(j.proxy_pid):''}</div>`)};if(j.started)details.push(`<div><b>Started:</b> ${esc(j.started)}</div>`);if(j.log_file)details.push(`<div><b>Log:</b> ${esc(j.log_file)}</div>`);if(!j.running&&j.last_exit_code!==null&&j.last_exit_code!==undefined){const x=[esc(j.last_exit_code),j.last_exit_hex?esc(j.last_exit_hex):'',j.last_exit_name?esc(j.last_exit_name):''].filter(Boolean).join(' / ');details.push(`<div><b>llama-server exit:</b> ${x}${j.last_exit_time?' at '+esc(j.last_exit_time):''}</div>`);if(j.wrapper_exit_code!==null&&j.wrapper_exit_code!==undefined)details.push(`<div class=\"muted\"><b>Launcher exit:</b> ${esc(j.wrapper_exit_code)} (diagnostic only)</div>`)};$('statusDetails').innerHTML=details.join('')||'Not running.';const box=$('crashDetails');if(j.crashed||(!j.running&&j.last_exit_code&&j.last_exit_code!==0)){box.classList.remove('hidden');box.innerHTML=`<b>llama-server terminated unexpectedly: ${esc(j.last_exit_code)}${j.last_exit_hex?' / '+esc(j.last_exit_hex):''}${j.last_exit_name?' / '+esc(j.last_exit_name):''}.</b>${j.last_error?`<pre>${esc(j.last_error)}</pre>`:'<div>No textual llama.cpp error was emitted before termination. The Windows exception/status above may be the primary clue.</div>'}`}else{box.classList.add('hidden');box.innerHTML=''}$('log').textContent=j.log_tail||'No log yet.';updateDashboard()}catch(e){if(e.pollPaused||e.controlTransportFailure)return;toast(e.message,true)}}

// Select the available operational error for display with diagnostic context.
function diagnosticsError(j){if(j.last_error)return j.last_error;if(j.mode==='router'){const lines=(j.log_tail||'').split(/\r?\n/).filter(line=>/\b(?:failed|failure|out of memory|cudaMalloc|exiting due to model loading error)\b/i.test(line));if(lines.length)return lines.slice(-8).join('\n')}return '(none detected)'}
