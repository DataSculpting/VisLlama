// VisLlama: editor. Loaded in the order declared in templates/partials/scripts.html.

// Translate mounted form controls into the established UI snapshot and CLI
// arguments. Presentation may hide controls but must never change their stored values.

function selectedModel(){return $('model').value}

// Derive a safe API model alias from the selected model/variant.
function deriveAlias(){const v=$('variant').value||'';const f=$('model').selectedOptions[0]?.textContent||'';return (v||f.replace(/\.gguf$/i,'')).replace(/[^A-Za-z0-9._:-]+/g,'-').replace(/^-+|-+$/g,'')}

// Populate the alias only when the user has not supplied one.
function ensureAlias(){if(!$('alias').value.trim())$('alias').value=deriveAlias();syncEditorIdentity()}

// The edited name is live presentation; the original alias remains save identity.
function syncEditorIdentity(){
 const alias=$('alias').value.trim(),title=$('editorTitle'),mode=title.dataset.mode;
 if(mode)title.textContent=mode+' '+(alias||'model');
 const conflict=!!alias&&alias!==EDITOR_ALIAS&&(ROUTER_PRESETS||[]).some(p=>p.alias===alias);
 const warning=conflict?'Another model preset already uses this name. Saving will require confirmation to overwrite its settings.':'';
 for(const id of ['aliasWarning','editorAliasWarning']){const el=$(id);if(el.textContent!==warning)el.textContent=warning;el.classList.toggle('hidden',!conflict)}
 title.classList.toggle('preset-name-conflict',conflict);$('alias').classList.toggle('preset-name-conflict',conflict);
 return conflict;
}
$('alias').addEventListener('input',syncEditorIdentity);

// Reuse the console modal stack so Escape, focus trapping and Cancel all resolve.
let PRESET_OVERWRITE_RESOLVE=null;
function cancelPresetOverwrite(){const resolve=PRESET_OVERWRITE_RESOLVE;PRESET_OVERWRITE_RESOLVE=null;if(resolve){resolve(false);requestAnimationFrame(()=>{if(APP_VIEW==='editor')$('alias').focus({preventScroll:true})})}}
function confirmPresetOverwrite(alias){
 $('presetOverwriteName').textContent=alias;
 return new Promise(resolve=>{
  PRESET_OVERWRITE_RESOLVE=resolve;
  $('presetOverwriteCancel').onclick=()=>closeModal('presetOverwriteModal');
  $('presetOverwriteProceed').onclick=()=>{const accept=PRESET_OVERWRITE_RESOLVE;PRESET_OVERWRITE_RESOLVE=null;closeModal('presetOverwriteModal');accept?.(true)};
  openModal('presetOverwriteModal');
 });
}

// Explain blocked explicit actions; ordinary typing keeps inline feedback only.
// Focus the offending control first so every modal dismissal restores it.
function validationBlocked(message,field=null){
 const target=typeof field==='string'?$(field):field;
 if(target?.isConnected&&!target.disabled)target.focus({preventScroll:true});
 $('validationDescription').textContent=message;
 $('validationDismiss').onclick=()=>closeModal('validationModal');
 openModal('validationModal');return false;
}

// Validate locally before save; retain the editor and mark the alias inline.
function validateAlias(){const alias=$('alias').value.trim();const error=!alias?'Enter an API model alias.':/^[A-Za-z0-9._:-]+$/.test(alias)?'':"Enter a model alias using letters, numbers, dots, underscores, hyphens, or colons. Spaces and slashes aren't allowed.";$('alias').setAttribute('aria-invalid',error?'true':'false');$('aliasError').textContent=error;$('aliasError').classList.toggle('hidden',!error);return error}

// Keep direct-only controls and Router/editor visibility synchronized.
// Mode changes do not persist the Router service host or port.
function syncMode(){const r=$('serverMode').value==='router';$('directServiceFields').classList.toggle('hidden',r);const editing=$('singlePane').classList.contains('editor-open');$('singlePane').classList.toggle('hidden',r&&!editing);$('routerPane').classList.toggle('hidden',!r||editing);$('singleBuildField').classList.toggle('hidden',typeof modelEditorExternal==='function'||r&&!editing);$('singleAliasField').classList.toggle('hidden',r&&!editing);$('build').disabled=r&&!editing;updateCommand();syncServerButtons()}

// Append only explicitly entered values. Blank controls preserve build defaults.
function add(args,flag,val){if(val===undefined||val===null)return;const sv=String(val).trim();if(sv!=='')args.push(flag,sv)}

// DOM order of checked devices is the user’s requested placement priority.
let DEVICE_SELECTION=[],DEVICE_BUILD='';
function selectedDevices(){const rows=[...document.querySelectorAll('#device input[type=checkbox]')];return rows.length?rows.filter(x=>x.checked).map(x=>x.value):[...DEVICE_SELECTION]}

// Move a selected device one position and regenerate the command preview.
function moveDevice(id,offset){const chosen=selectedDevices(),from=chosen.indexOf(id),to=from+offset;if(from<0||to<0||to>=chosen.length)return;[chosen[from],chosen[to]]=[chosen[to],chosen[from]];renderDevices(chosen);updateCommand()}

// Preserve selected-device order while rebuilding discovered device rows.
// IDs come from this build’s --list-devices output, not nvidia-smi numbering.
function renderDevices(selected=null){const keep=selected===null?selectedDevices():selected;const ids=DEVICES.map(d=>d.id);const chosen=[...new Set(keep)];DEVICE_SELECTION=[...chosen];DEVICE_ORDER=[...chosen,...ids.filter(id=>!chosen.includes(id))];const box=$('device');const byId=new Map(DEVICES.map(d=>[d.id,d]));box.innerHTML=DEVICE_ORDER.map((id,i)=>{const d=byId.get(id)||{id,description:'Saved selection — not currently confirmed by discovery'},missing=!byId.has(id),on=chosen.includes(id),pos=chosen.indexOf(id);return `<div class="device-item" data-device-id="${esc(id)}" draggable="${on}"><span class="device-grip" title="Drag selected device">${on?'&#8942;&#8942;':''}</span><label class="row" style="flex:1;min-width:0"><input type="checkbox" class="gpu-device" name="visllama-device-${esc(id)}" autocomplete="off" value="${esc(id)}" ${on?'checked':''} ${missing?'disabled':''}><span><span class="device-id">${esc(id)}</span><br><span class="device-desc">${esc(d.description)}</span></span></label><div class="device-actions">${missing?`<button type="button" data-device-remove="${esc(id)}" title="Remove this saved, unconfirmed GPU selection">Remove</button>`:''}<button type="button" data-device-up="${esc(id)}" title="Move device earlier" ${!on||pos===0?'disabled':''}>&uarr;</button><button type="button" data-device-down="${esc(id)}" title="Move device later" ${!on||pos===chosen.length-1?'disabled':''}>&darr;</button></div></div>`}).join('')||'<span class="muted">No devices were parsed. Expand the raw output below to inspect llama.cpp output.</span>';box.querySelectorAll('.gpu-device').forEach(x=>x.addEventListener('change',()=>{renderDevices(selectedDevices());updateCommand()}));box.querySelectorAll('[data-device-remove]').forEach(x=>x.onclick=()=>{renderDevices(selectedDevices().filter(id=>id!==x.dataset.deviceRemove));updateCommand()});box.querySelectorAll('[data-device-up]').forEach(x=>x.onclick=()=>moveDevice(x.dataset.deviceUp,-1));box.querySelectorAll('[data-device-down]').forEach(x=>x.onclick=()=>moveDevice(x.dataset.deviceDown,1));box.querySelectorAll('.device-item').forEach(row=>{row.addEventListener('dragstart',e=>{if(!row.draggable){e.preventDefault();return}e.dataTransfer.setData('text/plain',row.dataset.deviceId);e.dataTransfer.effectAllowed='move';row.classList.add('dragging')});row.addEventListener('dragend',()=>row.classList.remove('dragging'));row.addEventListener('dragover',e=>{if(row.draggable){e.preventDefault();row.classList.add('drop-target')}});row.addEventListener('dragleave',()=>row.classList.remove('drop-target'));row.addEventListener('drop',e=>{e.preventDefault();row.classList.remove('drop-target');const from=e.dataTransfer.getData('text/plain'),to=row.dataset.deviceId,order=selectedDevices(),a=order.indexOf(from),b=order.indexOf(to);if(a<0||b<0||a===b)return;order.splice(a,1);order.splice(b,0,from);renderDevices(order);updateCommand()})});updateDeviceSummary()}

// Explain the currently selected device order beside the actual controls.
function updateDeviceSummary(){const ds=selectedDevices();$('deviceSummary').textContent=ds.length?`Order sent to llama.cpp: ${ds.join(' -> ')}${ds.some(id=>!DEVICES.some(d=>d.id===id))?' (saved selection; discovery unconfirmed)':''}`:'No explicit --device selection (llama.cpp default)'}

// Probe the selected executable and restore the requested device selection.
let DEVICE_REQUEST=0;
async function loadDevices(selected=null){const request=++DEVICE_REQUEST,build=$('build').value,keep=selected===null?selectedDevices():[...selected];if(DEVICE_BUILD!==build){DEVICES=[];DEVICE_BUILD=build}renderDevices(keep);try{const j=await post('/api/devices',{build});if(request!==DEVICE_REQUEST||build!==$('build').value)return;DEVICES=j.devices||[];$('deviceRaw').textContent=j.raw||'';$('deviceRawWrap').classList.toggle('hidden',!!DEVICES.length);renderDevices(selectedDevices())}catch(e){if(request!==DEVICE_REQUEST||build!==$('build').value)return;renderDevices(selectedDevices());$('deviceRawWrap').classList.remove('hidden');$('deviceRaw').textContent=e.message;toast(e.message,true)}updateCommand()}

// Check explicit fit values before producing a save or load request.
function validateFitOptions(){const ft=['priority','priority_split'].includes($('gpuPriority').value)?'':$('fitTarget').value.trim();if(ft&&!/^\d+(?:\s*,\s*\d+)*$/.test(ft))return 'Fit target must be one MiB value or a comma-separated list of MiB values.';const fc=$('fitCtx').value.trim();if(fc&&(!/^\d+$/.test(fc)||Number(fc)<1))return 'Fit context minimum must be a positive integer.';return ''}

// Validate placement mode, reserve and manual split length against selected GPUs.
function validateConfig(){const extraProblem=parseExtraArguments($('extra').value).error;if(extraProblem)return extraProblem;const fitProblem=validateFitOptions();if(fitProblem)return fitProblem;const ds=selectedDevices(),mode=$('gpuPriority').value;if(['even','priority','priority_split'].includes(mode)){if(ds.length<(mode==='even'?2:1)||ds.some(id=>!/^CUDA\d+$/.test(id)))return mode==='even'?'Even split requires at least two selected CUDA GPUs.':'Priority order requires one or more selected CUDA GPUs.';if(mode==='priority'||mode==='priority_split'){const reserve=$('gpuReserve').value.trim();if(!/^\d+$/.test(reserve)||Number(reserve)<256||Number(reserve)>32768)return 'Target free VRAM must be between 256 and 32768 MiB.'}return ''}const raw=$('tensorSplit').value.trim();if(raw&&ds.length){const parts=raw.split(',').map(x=>x.trim()).filter(Boolean);if(parts.length!==ds.length)return `Tensor split has ${parts.length} value(s), but ${ds.length} device(s) are selected (${ds.join(', ')}). Provide one split weight per selected device or leave tensor split blank for llama.cpp automatic splitting.`}return ''}

// Serialize friendly controls into the existing command argument contract.
// Hidden or disabled presentation does not discard values; mode rules decide flags.
function friendlyArgs(){let a=[];add(a,'--gpu-layers',$('gpuLayers').value);add(a,'--ctx-size',$('ctx').value);if($('contextShift').value==='shift')a.push('--context-shift');if($('contextShift').value==='stop')a.push('--no-context-shift');add(a,'--keep',$('contextKeep').value);add(a,'--rope-scaling',$('ropeScaling').value);add(a,'--rope-freq-base',$('ropeFreqBase').value);if($('kvUnified').value==='on')a.push('--kv-unified');if($('kvUnified').value==='off')a.push('--no-kv-unified');add(a,'--kv-unified-per-slot',$('kvUnifiedPerSlot').value);add(a,'--batch-size',$('batch').value);add(a,'--ubatch-size',$('ubatch').value);add(a,'--cache-type-k',$('cacheK').value);add(a,'--cache-type-v',$('cacheV').value);const distribution=$('gpuPriority').value;if(distribution==='manual'){add(a,'--tensor-split',$('tensorSplit').value);add(a,'--main-gpu',$('mainGpu').value);add(a,'--split-mode',$('splitMode').value)}else if(distribution==='even'){add(a,'--tensor-split',selectedDevices().map(()=>1).join(','));add(a,'--split-mode','layer')};add(a,'--load-mode',$('loadMode').value);add(a,'--lazy-mode',$('lazyMode').value);add(a,'--chat-template-file',$('chatTemplateFile').value.trim());const ds=selectedDevices();if(ds.length)add(a,'--device',ds.join(','));if($('flash').checked)a.push('--flash-attn','on');if($('fit').value==='on')a.push('--fit');if($('fit').value==='off')a.push('--no-fit');add(a,'--fit-target',$('fitTarget').value.trim());add(a,'--fit-ctx',$('fitCtx').value);if($('cpuMoe').checked)a.push('--cpu-moe');if($('noKvOffload').checked)a.push('--no-kv-offload');if($('swaFull').checked)a.push('--swa-full');if($('noWarmup').checked)a.push('--no-warmup');add(a,'--threads',$('threads').value);add(a,'--threads-batch',$('threadsBatch').value);add(a,'--parallel',$('parallel').value);if($('serverMode').value==='single'){add(a,'--host',$('host').value);add(a,'--port',$('port').value);add(a,'--threads-http',$('threadsHttp').value)}add(a,'--alias',$('alias').value.trim());add(a,'--reasoning',$('reasoning').value);add(a,'--reasoning-effort',$('reasoningEffort').value);add(a,'--reasoning-budget',$('reasoningBudget').value);add(a,'--reasoning-format',$('reasoningFormat').value);if($('reasoningPreserve').value==='on')a.push('--reasoning-preserve');if($('reasoningPreserve').value==='off')a.push('--no-reasoning-preserve');add(a,'--predict',$('predict').value);add(a,'--temperature',$('temperature').value);add(a,'--top-k',$('topK').value);add(a,'--top-p',$('topP').value);add(a,'--min-p',$('minP').value);add(a,'--typical-p',$('typicalP').value);add(a,'--top-nsigma',$('topNSigma').value);add(a,'--repeat-penalty',$('repeatPenalty').value);add(a,'--repeat-last-n',$('repeatLastN').value);add(a,'--presence-penalty',$('presencePenalty').value);add(a,'--frequency-penalty',$('frequencyPenalty').value);add(a,'--xtc-probability',$('xtcProbability').value);add(a,'--xtc-threshold',$('xtcThreshold').value);add(a,'--dynatemp-range',$('dynatempRange').value);add(a,'--dynatemp-exp',$('dynatempExp').value);add(a,'--mirostat',$('mirostat').value);add(a,'--mirostat-lr',$('mirostatLR').value);add(a,'--mirostat-ent',$('mirostatEnt').value);add(a,'--seed',$('seed').value);add(a,'--samplers',$('samplers').value);add(a,'--dry-multiplier',$('dryMultiplier').value);add(a,'--dry-base',$('dryBase').value);add(a,'--dry-allowed-length',$('dryAllowedLength').value);add(a,'--dry-penalty-last-n',$('dryPenaltyLastN').value);if($('ignoreEos').checked)a.push('--ignore-eos');const specTypes=[];if($('specType').value&&$('specType').value!=='none')specTypes.push($('specType').value);if($('ngramType').value&&$('ngramType').value!=='none')specTypes.push($('ngramType').value);if(specTypes.length)add(a,'--spec-type',specTypes.join(','));add(a,draftModelFlag(),$('draft').value);add(a,'--spec-draft-n-max',$('draftTokens').value);add(a,'--spec-draft-n-min',$('draftMinTokens').value);add(a,'--spec-draft-p-min',$('draftPMin').value);add(a,'--spec-draft-p-split',$('draftPSplit').value);add(a,'--spec-draft-ngl',$('draftNgl').value);add(a,'--spec-draft-device',$('draftDevice').value);add(a,'--spec-draft-type-k',$('draftTypeK').value);add(a,'--spec-draft-type-v',$('draftTypeV').value);const nt=$('ngramType').value;if(nt==='ngram-mod'){add(a,'--spec-ngram-mod-n-match',$('ngramModMatch').value);add(a,'--spec-ngram-mod-n-min',$('ngramModMin').value);add(a,'--spec-ngram-mod-n-max',$('ngramModMax').value)}else if(nt==='ngram-simple'){add(a,'--spec-ngram-simple-size-n',$('ngramSimpleN').value);add(a,'--spec-ngram-simple-size-m',$('ngramSimpleM').value);add(a,'--spec-ngram-simple-min-hits',$('ngramSimpleHits').value)}else if(nt==='ngram-map-k'){add(a,'--spec-ngram-map-k-size-n',$('ngramMapKN').value);add(a,'--spec-ngram-map-k-size-m',$('ngramMapKM').value);add(a,'--spec-ngram-map-k-min-hits',$('ngramMapKHits').value)}else if(nt==='ngram-map-k4v'){add(a,'--spec-ngram-map-k4v-size-n',$('ngramMapK4vN').value);add(a,'--spec-ngram-map-k4v-size-m',$('ngramMapK4vM').value);add(a,'--spec-ngram-map-k4v-min-hits',$('ngramMapK4vHits').value)}const rawExtra=parseExtraArguments($('extra').value).tokens;const extra=[];for(let i=0;i<rawExtra.length;i++){const v=rawExtra[i];const blocked=['--tensor-split',...($('ctx').value?['--ctx-size']:[]),...($('parallel').value?['--parallel']:[]),...($('loadMode').value?['--load-mode']:[]),...(ds.length?['--device']:[]),...(distribution!=='manual'?['--split-mode','--main-gpu']:[]),...(['priority','priority_split'].includes(distribution)?['--fit','--no-fit','--fit-target','--gpu-layers']:[])];const flag=blocked.find(f=>v===f||v.startsWith(f+'='));if(flag){if(v===flag&&i+1<rawExtra.length&&!rawExtra[i+1].startsWith('--'))i++;continue}extra.push(v)}return a.concat(extra)}

// Read selected dynamic build options, including rows hidden by text search.
function allArgs(){let a=[];document.querySelectorAll('.opt').forEach(d=>{const on=d.querySelector('.opt-on');if(!on||!on.checked)return;const flag=d.dataset.flag;const inp=d.querySelector('.opt-val');a.push(flag);if(inp&&inp.value!=='')a.push(inp.value)});return a}

// Combine the friendly argument list with the additional checked build options.
function args(){return friendlyArgs().concat(allArgs())}

// Remove placement flags that would conflict with the priority planner’s output.
function priorityArgsWithoutOverrides(a){const out=[];for(let i=0;i<a.length;i++){const v=a[i];if(['--device','--tensor-split','--split-mode','--main-gpu','--fit-target','--gpu-layers'].some(flag=>v===flag||v.startsWith(flag+'='))){if(!v.includes('=')&&i+1<a.length)i++;continue}if(v==='--no-fit'||v==='--fit'||v.startsWith('--fit=')){if(v==='--fit'&&['on','off'].includes(a[i+1]))i++;continue}out.push(v)}return out}

// Request a debounced estimate for display. The final calculated split is
// measured again at load time, so this preview is not an allocation guarantee.
function updatePriorityPreview(key,payload){if(PRIORITY_TIMER)clearTimeout(PRIORITY_TIMER);PRIORITY_TIMER=setTimeout(async()=>{PRIORITY_TIMER=null;try{const j=await post('/api/gpu-priority-preview',payload,{busy:false});if(PRIORITY_PREVIEW_KEY!==key)return;PRIORITY_PREVIEW=j.plan;updateCommand()}catch(e){if(PRIORITY_PREVIEW_KEY!==key)return;PRIORITY_PREVIEW=null;$('gpuPriorityStatus').textContent=e.message;updateCommand()}},300)}

// Update the displayed command and disable fields controlled by the GPU mode.
// Disabling communicates ownership; it does not erase the underlying form value.
function updateCommand(){syncEditorActions();if(typeof modelEditorExternal==='function'&&modelEditorExternal())return;const extraProblem=parseExtraArguments($('extra').value).error;$('extra').setCustomValidity(extraProblem);$('extraError').textContent=extraProblem;$('extra').setAttribute('aria-invalid',extraProblem?'true':'false');if(extraProblem){$('command').textContent=extraProblem;return}const b=CFG?.builds.find(x=>x.name===$('build').value);const exe=b?.type==='docker'?'llama-server':b?.exe||CFG?.server_executable||'llama-server.exe';const runtimeNote=b?.type==='docker'?`Docker image: ${b.image} (container and mounts managed by VisLlama)\n`:'';if($('serverMode').value==='router'&&!$('singlePane').classList.contains('editor-open')){const enabled=(ROUTER_PRESETS||[]).filter(p=>p.enabled);const groups={};for(const p of enabled){const k=p.build||'(unassigned)';(groups[k]??=[]).push(p.alias)}const lines=[`Public OpenAI endpoint: http://${effectiveRouterHost()}:${effectiveRouterPort()}`,'Saved models by build (GPU selections may create multiple engines):'];for(const [build,models] of Object.entries(groups))lines.push(`  ${build} -> ${models.join(', ')}`);if(!enabled.length)lines.push('  (no enabled Router Presets)');$('routerCommand').textContent=lines.join('\n');$('routerEnginePlan').textContent='Internal loopback engines are grouped by build and ordered GPU visibility selection. This saved-catalog summary is not a live engine count.';return}
 const mode=$('gpuPriority').value,priority=['priority','priority_split'].includes(mode),m=selectedModel()||'<model.gguf>',controls=['tensorSplit','splitMode','mainGpu'];for(const id of controls)$(id).disabled=mode!=='manual';$('gpuReserve').disabled=!priority;for(const id of ['fit','fitTarget','gpuLayers'])$(id).disabled=priority;
 if(!priority){PRIORITY_PREVIEW_KEY='';PRIORITY_PREVIEW=null;if(PRIORITY_TIMER){clearTimeout(PRIORITY_TIMER);PRIORITY_TIMER=null}const ds=selectedDevices();$('gpuPriorityStatus').textContent=mode==='even'?`Even split: ${ds.length>=2?ds.join(' = '):'select at least two CUDA GPUs below'}. Equal layer proportions; actual memory use may differ.`:'Manual values or the selected llama.cpp build determine GPU placement.';$('command').textContent=runtimeNote+[q(exe),'-m',q(m),...args().map(q)].join(' ');return}
 if(mode==='priority_split'&&EDITOR_ALIAS&&['loaded','loading','sleeping'].includes(liveFor(EDITOR_ALIAS)?.status?.value)){
  PRIORITY_PREVIEW_KEY='';PRIORITY_PREVIEW=null;if(PRIORITY_TIMER){clearTimeout(PRIORITY_TIMER);PRIORITY_TIMER=null}
  $('gpuPriorityStatus').textContent='This model occupies VRAM. Save and reload will unload it, calculate the layer split from free VRAM, and reload it.';
  $('command').textContent=runtimeNote+[q(exe),'-m',q(m),...priorityArgsWithoutOverrides(args()).map(q)].join(' ')+'\n--device and --tensor-split calculated after unload';
  return
 }
 const ds=selectedDevices(),payload={build:$('build').value,model:selectedModel(),devices:ds,reserve:$('gpuReserve').value,mode,settings:presetData(),args:args()};const key=JSON.stringify(payload);
 if(key!==PRIORITY_PREVIEW_KEY){PRIORITY_PREVIEW_KEY=key;PRIORITY_PREVIEW=null;if(PRIORITY_TIMER)clearTimeout(PRIORITY_TIMER);if(payload.model&&ds.length&&payload.build)updatePriorityPreview(key,payload)}
 const computed=PRIORITY_PREVIEW?.args||[];const previewArgs=[...priorityArgsWithoutOverrides(args()),...computed];$('command').textContent=runtimeNote+[q(exe),'-m',q(m),...previewArgs.map(q)].join(' ')+(computed.length?'':'\nGPU priority split will be calculated before load.');
 if(computed.length){const p=PRIORITY_PREVIEW;$('gpuPriorityStatus').textContent=p.weights_mib?`${p.planning_quality==='layer_estimate'?'Layer estimate':p.planning_quality==='reserve_only'?'Weight-only estimate':'Approximate estimate'}: ${p.devices.map((id,i)=>id+' '+(p.layer_counts?p.layer_counts[i]+' layers, ':'')+p.weights_mib[i]+' MiB weights; '+(p.effective_reserves_mib?.[i]??p.reserve_mib)+' MiB allowance').join(', ')}. ${p.note}`:`Preferred order: ${p.devices.join(' -> ')}. Target: ${p.reserve_mib} MiB free on each GPU. ${p.note}`}
 else if(!payload.model||!ds.length)$('gpuPriorityStatus').textContent='Choose a model and one or more CUDA GPUs to preview priority allocation.';
 else if(PRIORITY_TIMER)$('gpuPriorityStatus').textContent='Checking the selected llama.cpp build and GPUs...';
}

// Ignore late help responses after a build switch; the visible capability notes
// and options must describe the executable currently selected in this editor.
let EDITOR_HELP_REQUEST=0;
async function loadHelp(){
 const request=++EDITOR_HELP_REQUEST,build=$('build').value;
 editorHelpState('loading',build);
 try{
  const j=await post('/api/help',{build});
  if(request!==EDITOR_HELP_REQUEST||build!==$('build').value)return;
  HELP=j.options;$('rawHelp').textContent=j.raw;renderOptions();
  editorHelpState(HELP.length?'ready':'unknown',build);
 }catch(e){if(request===EDITOR_HELP_REQUEST&&build===$('build').value){editorHelpState('error',build);toast(e.message,true)}}
}

// Render only build-help options not already owned by friendly controls.
// Search is applied afterwards to keep checked rows mounted during filtering.
function renderOptions(){const reserved=new Set(['--model','--gpu-layers','--ctx-size','--context-shift','--no-context-shift','--keep','--rope-scaling','--rope-freq-base','--kv-unified','--no-kv-unified','--kv-unified-per-slot','--batch-size','--ubatch-size','--cache-type-k','--cache-type-v','--tensor-split','--main-gpu','--split-mode','--load-mode','--lazy-mode','--device','--flash-attn','--fit','--no-fit','--fit-target','--fit-ctx','--cpu-moe','--no-kv-offload','--swa-full','--no-warmup','--threads','--threads-batch','--parallel','--host','--port','--threads-http','--alias','--reasoning','--reasoning-effort','--reasoning-budget','--reasoning-format','--reasoning-preserve','--no-reasoning-preserve','--predict','--temperature','--temp','--top-k','--top-p','--min-p','--typical-p','--typical','--top-nsigma','--top-n-sigma','--repeat-penalty','--repeat-last-n','--presence-penalty','--frequency-penalty','--xtc-probability','--xtc-threshold','--dynatemp-range','--dynatemp-exp','--mirostat','--mirostat-lr','--mirostat-ent','--seed','--samplers','--dry-multiplier','--dry-base','--dry-allowed-length','--dry-penalty-last-n','--ignore-eos','--models-dir','--models-preset','--models-max','--models-autoload','--no-models-autoload','--spec-type','--spec-draft-model','--model-draft','--draft','--spec-draft-n-max','--spec-draft-n-min','--spec-draft-p-min','--spec-draft-p-split','--spec-draft-ngl','--spec-draft-device','--spec-draft-type-k','--spec-draft-type-v','--spec-ngram-mod-n-match','--spec-ngram-mod-n-min','--spec-ngram-mod-n-max','--spec-ngram-simple-size-n','--spec-ngram-simple-size-m','--spec-ngram-simple-min-hits','--spec-ngram-map-k-size-n','--spec-ngram-map-k-size-m','--spec-ngram-map-k-min-hits','--spec-ngram-map-k4v-size-n','--spec-ngram-map-k4v-size-m','--spec-ngram-map-k4v-min-hits']);
 $('options').innerHTML=HELP.filter(o=>!reserved.has(o.flag)).map((o,i)=>`<div class="opt" data-flag="${esc(o.flag)}"><div class="sig">${esc(o.signature)} <span class="info" tabindex="0" data-tip="${esc(o.description)}">i</span></div><p>${esc(o.description)}</p><div class="opt-controls"><input class="opt-on" type="checkbox" name="visllama-option-${esc(o.flag)}-enabled" autocomplete="off" id="oo${i}"><label for="oo${i}">use</label>${o.takes_value?`<input class="opt-val" name="visllama-option-${esc(o.flag)}-value" autocomplete="off" aria-label="Value for ${esc(o.flag)}" placeholder="${esc(o.value_hint||'value')}">`:''}</div></div>`).join('');
 document.querySelectorAll('.opt input').forEach(x=>x.addEventListener('input',updateCommand)); filterBuildOptions(); updateCommand()}

// Use the selected build's advertised spelling; model-draft remains the
// compatible fallback for older/custom builds and existing saved options.
function draftModelFlag(){const option=HELP.find(option=>[option.flag,...(option.aliases||[])].includes('--spec-draft-model'));return option?'--spec-draft-model':'--model-draft'}
// Update MTP guidance and the dependent N-gram controls before previewing flags.
function syncSpecUi(){const mtp=$('specType').value==='draft-mtp';$('mtpHint').classList.toggle('hidden',!mtp);$('mtpHint').textContent=$('draft').selectedOptions[0]?.dataset.fileUnavailable==='true'?'The selected external draft/MTP file is unavailable. Choose an existing file; it has not been replaced with embedded MTP.':$('draft').value?'MTP will use the selected external head GGUF. The build and head file must support this target architecture.':'MTP will use heads embedded in the target GGUF. Select an external head GGUF above if the target does not contain MTP layers.';syncNgramUi(false);updateCommand()}

// Show only the parameter family for the chosen N-gram mode; preserve the
// other families’ values so switching methods does not destroy entered settings.
function syncNgramUi(update=true){const t=$('ngramType').value;$('ngramModOptions').classList.toggle('hidden',t!=='ngram-mod');$('ngramSimpleOptions').classList.toggle('hidden',t!=='ngram-simple');$('ngramMapKOptions').classList.toggle('hidden',t!=='ngram-map-k');$('ngramMapK4vOptions').classList.toggle('hidden',t!=='ngram-map-k4v');if(update)updateCommand()}

// Capture all friendly controls using their stable IDs. The default-reading
// path uses template attributes, never browser-restored values or placeholders.
function presetData(defaults=false){const ids=['serverMode','alias','build','supplier','variant','model','gpuLayers','ctx','contextShift','contextKeep','ropeScaling','ropeFreqBase','kvUnified','kvUnifiedPerSlot','batch','ubatch','cacheK','cacheV','tensorSplit','mainGpu','splitMode','gpuPriority','gpuReserve','loadMode','lazyMode','chatTemplateFile','flash','fit','fitTarget','fitCtx','cpuMoe','noKvOffload','swaFull','noWarmup','threads','threadsBatch','parallel','host','port','threadsHttp','reasoning','reasoningEffort','reasoningBudget','reasoningFormat','reasoningPreserve','predict','temperature','topK','topP','minP','typicalP','topNSigma','repeatPenalty','repeatLastN','presencePenalty','frequencyPenalty','xtcProbability','xtcThreshold','dynatempRange','dynatempExp','mirostat','mirostatLR','mirostatEnt','seed','samplers','dryMultiplier','dryBase','dryAllowedLength','dryPenaltyLastN','ignoreEos','specType','ngramType','ngramModMatch','ngramModMin','ngramModMax','ngramSimpleN','ngramSimpleM','ngramSimpleHits','ngramMapKN','ngramMapKM','ngramMapKHits','ngramMapK4vN','ngramMapK4vM','ngramMapK4vHits','draft','draftTokens','draftMinTokens','draftPMin','draftPSplit','draftNgl','draftDevice','draftTypeK','draftTypeV','extra'];let x={devices:defaults?[]:selectedDevices()};for(const id of ids){const e=$(id);x[id]=defaults?(e.type==='checkbox'?e.defaultChecked:e.tagName==='SELECT'?([...e.options].find(o=>o.defaultSelected)||e.options[0])?.value||'':e.defaultValue):(e.type==='checkbox'?e.checked:e.value)}return x}

// New models use declared control defaults and the current file/build catalog.
// Never snapshot live controls: browser restoration can put unrelated old values
// into them before initialization, and a previous edit is not a default preset.
function newModelDefaults(){
 const defaults=presetData(true),model=MODELS[0];
 const build=CFG?.builds.find(b=>b.available)||CFG?.builds[0];
 return {...defaults,build:build?.name||'',supplier:model?.supplier||'',variant:model?.variant||'',model:model?.path||'',alias:'',draft:'',devices:[]};
}

// Read the existing Router snapshot and pending actions; the editor owns no
// separate polling loop. Renames track the original alias until save completes.
let EDITOR_SAVE_BUSY=false;
function editorModelAction(){
 if(typeof modelEditorExternal==='function'&&modelEditorExternal())return modelEditorEngineAction();
 const alias=EDITOR_ALIAS||$('alias').value.trim(),preset=ROUTER_PRESETS.find(p=>p.alias===alias);
 const running=!!(LAST_STATUS?.running&&LAST_STATUS.mode==='router');
 const model=liveFor(alias),pending=MODEL_ACTION_PENDING.get(alias);
 const mapped=(LAST_STATUS?.router_engines||[]).some(e=>(e.models||[]).includes(alias));
 let state=!LAST_STATUS?'checking':!running?'unloaded':pending==='unload'?'unloading':pending?'loading':MODEL_STATUS_ERROR?'unknown':!MODEL_STATUS_FETCHED?'checking':model?.status?.failed?'failed':model?.status?.value||(preset&&mapped?'unknown':'unloaded');
 if(!['loaded','unloaded','loading','unloading','sleeping','failed','checking','unknown'].includes(state))state='unknown';
 const label=['loaded','sleeping'].includes(state)?'Save and reload':'Save and load';
 let reason='';
 if(EDITOR_SAVE_BUSY)reason='A preset save is in progress.';
 else if(typeof modelEditorFamilyChanged==='function'&&modelEditorFamilyChanged()&&LAST_STATUS?.running)reason='Stop Router before changing a model engine type.';
 else if(SERVER_ACTION_BUSY)reason='Wait for the Router action to finish.';
 else if(!LAST_STATUS)reason='Checking Router status.';
 else if(!running)reason='Start the Router before loading this model.';
 else if(['loading','unloading'].includes(state))reason=`Wait until the model finishes ${state}.`;
 else if(state==='checking'||state==='unknown')reason='Waiting for confirmed model status. Check Router / Serving if this persists.';
 else if(preset&&!preset.enabled)reason='Enable this preset in Manage Models before loading it.';
 else if(!(LAST_STATUS.router_engines||[]).some(e=>e.running&&e.build===$('build').value))reason='Save the preset, then restart the Router to use the selected build.';
 return {state,label,reason};
}

// Text accompanies color, and the reason remains visible for keyboard/touch
// users who cannot hover a disabled button to inspect its title.
function syncEditorActions(){
 syncEditorIdentity();
 if(!$('singlePane')?.classList.contains('editor-open'))return;
 const {state,label,reason}=editorModelAction(),badge=$('editorModelState'),button=$('editorSaveReload');
 badge.textContent=state==='unknown'?'Status unavailable':state[0].toUpperCase()+state.slice(1);
 badge.className='badge '+state;
 button.textContent=label;button.disabled=!!reason;button.title=reason;
 if($('modelBuildChoice'))$('modelBuildChoice').disabled=EDITOR_SAVE_BUSY||(typeof MODEL_EDITOR_SWITCHING!=='undefined'&&MODEL_EDITOR_SWITCHING);
 $('editorSave').disabled=EDITOR_SAVE_BUSY;$('saveRouterPreset').disabled=EDITOR_SAVE_BUSY;$('editorClose').disabled=EDITOR_SAVE_BUSY;
 $('editorSaveNote').textContent='Save stores this preset and updates the running Router catalog. Loaded models keep their settings until Save and reload. '+(reason||(label==='Save and reload'?'Save and reload unloads the current model and loads the saved settings.':'Save and load also loads this model with the saved settings.'));
}

// Save/rename a Router preset and optionally apply + load/reload it live.
// A successful save and a successful reload are separate outcomes. Once saved,
// a later load failure leaves the durable edit intact and reports that boundary.
async function saveEditorPreset(reload=false){
 if(typeof modelEditorExternal==='function'&&modelEditorExternal())return modelEditorSaveEngine(reload);
 if(typeof modelEditorCanSave==='function'&&!modelEditorCanSave())return false;
 if(EDITOR_SAVE_BUSY)return false;
 if(reload){const action=editorModelAction();if(action.reason){syncEditorActions();return validationBlocked(action.reason)}}
 ensureAlias();const alias=$('alias').value.trim();const aliasProblem=validateAlias();if(aliasProblem){return validationBlocked(aliasProblem,'alias')}
 const problem=validateConfig();if(problem){return validationBlocked(problem)}
 let unloadedBeforeSave=false,presetSaved=false,recoveryAlias='';
 const runtimeToken=LAST_STATUS?.runtime_token;
 let preflightId,restartRequired=false;
 const pendingAliases=[];
 EDITOR_SAVE_BUSY=true;syncEditorActions();
 try{
  const existing=ROUTER_PRESETS.some(p=>p.alias===alias);
  if(existing&&alias!==EDITOR_ALIAS&&!await confirmPresetOverwrite(alias))return false;
  const originalAlias=EDITOR_ALIAS||'',originalBuild=EDITOR_ORIGINAL_BUILD,selectedBuild=$('build').value;
  const buildChanged=!!(originalAlias&&originalBuild&&selectedBuild!==originalBuild),reloadAlias=originalAlias||alias;
  recoveryAlias=reloadAlias;
  const routerRunning=!!(LAST_STATUS?.running&&LAST_STATUS?.mode==='router');
  const calculated=$('gpuPriority').value==='priority_split';
  const liveBefore=(reload||calculated)&&routerRunning?await currentRouterModel(reloadAlias):null;
  const mapped=(LAST_STATUS?.router_engines||[]).some(e=>(e.models||[]).includes(reloadAlias));
  if((reload||calculated)&&routerRunning&&originalAlias&&mapped&&!liveBefore)throw new Error(`Cannot confirm whether ${reloadAlias} is running. Check Router status before reloading.`);
  // A poll may have changed since the button was drawn. Recheck before saving
  // or unloading so an externally initiated load is never interrupted here.
  if((reload||calculated)&&routerRunning){
   if(MODEL_ACTION_PENDING.has(reloadAlias)||MODEL_ACTION_PENDING.has(alias)||['loading','unloading'].includes(liveBefore?.status?.value))throw new Error('A model action is already in progress. Wait for it to finish before saving and loading.');
   if(liveBefore&&!['loaded','unloaded','sleeping','failed'].includes(liveBefore.status?.value))throw new Error('Model status is unavailable. Check Router / Serving before saving and loading.');
  }
  const wasLoaded=['loaded','sleeping'].includes(liveBefore?.status?.value);
  const savePayload={alias,original_alias:originalAlias,build:selectedBuild,model:selectedModel(),args:args(),ui:presetData(),replace_engine:typeof modelEditorFamilyChanged==='function'&&(modelEditorFamilyChanged()||ROUTER_PRESETS.some(p=>p.alias===alias&&p.engine&&p.engine!=='llamacpp')),load_on_startup:false,stop_timeout:10};
  if(reload&&routerRunning){
   const checked=await post('/api/model-preflight',{...savePayload,live:true,runtime_token:runtimeToken},{label:'Validating replacement model before unloading...'});
   preflightId=checked.preflight_id;restartRequired=!!checked.restart_required;
  }
  if(reload&&routerRunning&&!restartRequired){for(const name of new Set([reloadAlias,alias])){MODEL_ACTION_PENDING.set(name,wasLoaded?'unload':'load');pendingAliases.push(name)}syncEditorActions()}
  if(calculated&&wasLoaded&&!restartRequired){
   if(!reload)throw new Error('Use Save and reload to calculate a layer split after unloading this model.');
   await post('/api/router-unload',{model:reloadAlias,preflight_id:preflightId,runtime_token:runtimeToken},{label:'Unloading current model before calculating GPU split...'});
   await waitForRouterModel(reloadAlias,'unloaded',30000,runtimeToken);
   unloadedBeforeSave=true;
  }
  const j=await post('/api/router-preset-save',{...savePayload,preflight_id:preflightId});
  presetSaved=true;
  ROUTER_PRESETS=j.presets||[];renderRouterPresets();renderModelLibrary();
  toast(originalAlias&&originalAlias!==alias?'Router preset renamed':(existing?'Router preset updated':'Router preset saved'));
  closeEditor();
  if(restartRequired){toast('Preset saved. Restart Router to activate the changed build or GPU visibility group. The current model was kept running.');showView('router');return true}
  if(!reload){
   if(routerRunning){
    // Save activates the catalog without interrupting resident models. Report
    // an apply failure separately: the durable preset has already been saved.
    try{
     await applyRouterConfig(false,true,runtimeToken);
     toast('Preset saved and Router catalog updated. Loaded models keep their current settings until Save and reload.');
    }catch(applyErr){
     toast(`Preset saved, but Router catalog was not updated: ${applyErr.message}`,true);
     showView('router');
    }
   }
   return true;
  }
  if(!routerRunning){toast('Preset saved. Start Router mode before loading it.');return true}
  try{
   if(wasLoaded&&!unloadedBeforeSave){
    await post('/api/router-unload',{model:reloadAlias,preflight_id:preflightId,runtime_token:runtimeToken},{label:'Unloading current model before applying updated configuration...'});
    await waitForRouterModel(reloadAlias,'unloaded',30000,runtimeToken);
   }
   await applyRouterConfig(true,true,runtimeToken);
   for(const name of pendingAliases)MODEL_ACTION_PENDING.set(name,'load');
   syncEditorActions();
   await post('/api/router-load',{model:alias,runtime_token:runtimeToken},{label:'Loading model with updated configuration...'});
   const loaded=await waitForRouterModel(alias,'loaded',300000,runtimeToken);
   const saved=ROUTER_PRESETS.find(p=>p.alias===alias),mismatch=saved?savedRuntimeMismatch(saved,loaded):[];
   await refreshRouterModels(true);
   if(mismatch.length)throw new Error(`The running child ignored saved ${mismatch.join(', ')}. Copy its running arguments in Router / Serving and check Logs / Diagnostics.`);
   toast(buildChanged?`Model loaded on ${selectedBuild} with updated settings`:'Model loaded with updated settings');
   showView('router');return true
  }catch(applyErr){toast(`Preset saved, but ${wasLoaded?'reload':'load'} could not be verified: ${applyErr.message}`,true);showView('router');return true}
 }catch(e){
  if(unloadedBeforeSave&&!presetSaved){
   try{await post('/api/router-load',{model:recoveryAlias,runtime_token:runtimeToken},{label:'Restoring the previous model after the save failed...'});await waitForRouterModel(recoveryAlias,'loaded',300000,runtimeToken)}
   catch(recoveryError){toast(`Could not restore ${recoveryAlias}: ${recoveryError.message}`,true)}
  }
  toast(e.message,true);return false
 }finally{
  for(const name of pendingAliases)MODEL_ACTION_PENDING.delete(name);
  EDITOR_SAVE_BUSY=false;syncEditorActions();
  if(pendingAliases.length){renderRouterPresets();refreshRouterModels(true)}
 }
}

// Restore a saved UI snapshot into the editor and refresh dependent controls.
async function applyUiPreset(p){
 if(!p)return;
 p={...newModelDefaults(),...p,gpuPriority:p.gpuPriority||'manual',gpuReserve:p.gpuReserve||'2048'};
 if(/^ngram-/.test(p.specType||'')&&(!p.ngramType||p.ngramType==='none')){p.ngramType=p.specType;p.specType='none'}
 // A different preset must not inherit checked additional options, including
 // when its build's help request fails and cannot render a fresh option list.
 HELP=[];$('options').replaceChildren();$('rawHelp').textContent='';
 if(p.build)$('build').value=p.build;
 rebuildHierarchy(p);
 for(const [id,v] of Object.entries(p)){
  const e=$(id);
  if(!e||['supplier','variant','model','draft','build','devices','routerHost','routerPort','routerMax','routerThreadsHttp','routerAutoload'].includes(id))continue;
  if(id==='fit'&&typeof v==='boolean'){e.value=v?'on':'';continue}
  if(e.type==='checkbox')e.checked=!!v;else e.value=v;
 }
 await Promise.all([loadHelp(),loadDevices(Array.isArray(p.devices)?p.devices:[])]);
 syncSpecUi();syncBuildStatus();syncMode();updateCommand();
}
