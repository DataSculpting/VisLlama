// VisLlama: models. Loaded in the order declared in templates/partials/scripts.html.

function modelBuildLabel(p){return p.engine&&p.engine!=='llamacpp'?((CFG?.engine_builds||[]).find(b=>b.id===p.build)?.name||p.build||'Unassigned'):(p.build||'Unassigned')}

// Render the one authoritative model catalog and its contextual actions.
// Row order is saved immediately and later controls sequential Router startup.

function renderModelLibrary(){
 const library=$('modelLibrary');if(!library||MODEL_DRAG_ACTIVE)return;
 const presets=ROUTER_PRESETS||[],sortable=presets.length>1;
 if(!presets.some(p=>p.alias===INSPECTED_ALIAS))INSPECTED_ALIAS=presets[0]?.alias||null;
 $('catalogCount').textContent=presets.length+' configuration'+(presets.length===1?'':'s');
 $('modelOrderHint').textContent=sortable?'Drag or use the arrows to set startup order. Changes save automatically for the next Router start.':'Save at least two model presets to change their load order. Add or clone a model here.';
 const rows=presets.map((p,index)=>{
  const live=LAST_STATUS?.running&&LAST_STATUS?.mode==='router'?liveFor(p.alias):null;
  const active=live?.status?.value==='loaded'||live?.status?.value==='loading';
  const locked=active?'disabled title="Unload the model in Router / Serving first"':'';
  return `<tr class="model-library-row${p.alias===INSPECTED_ALIAS?' selected':''}" data-order-alias="${esc(p.alias)}"><td class="model-order-cell"><span class="model-order-number">${String(index+1).padStart(2,'0')}</span><span class="model-order-grip" data-order-handle draggable="${sortable&&!MODEL_ORDER_BUSY}" title="Drag to change load order" aria-hidden="true">&#8942;&#8942;</span><span class="model-order-controls"><button type="button" data-order-up="${esc(p.alias)}" aria-label="Move ${esc(p.alias)} earlier" ${index===0||MODEL_ORDER_BUSY?'disabled':''}>&uarr;</button><button type="button" data-order-down="${esc(p.alias)}" aria-label="Move ${esc(p.alias)} later" ${index===presets.length-1||MODEL_ORDER_BUSY?'disabled':''}>&darr;</button></span></td><td><button type="button" class="model-select" data-lib-select="${esc(p.alias)}" aria-pressed="${p.alias===INSPECTED_ALIAS}" aria-controls="modelInspector" title="Inspect saved configuration">${esc(p.alias)}</button><div class="model-path">${esc(p.model||'')}</div><small class="muted">${!p.enabled?'Disabled':p.load_on_startup?'Load at Router start':'On demand'}</small></td><td>${esc(modelBuildLabel(p))}</td><td>${p.enabled?'<span class="badge loaded">enabled</span>':'<span class="badge unloaded">disabled</span>'}</td><td><div class="model-library-actions"><button data-lib-edit="${esc(p.alias)}">Edit</button><button data-lib-clone="${esc(p.alias)}">Clone</button><button data-lib-toggle="${esc(p.alias)}" ${active&&p.enabled?locked:''}>${p.enabled?'Disable':'Enable'}</button><button class="danger" data-lib-delete="${esc(p.alias)}" ${locked}>Delete</button></div></td></tr>`
 }).join('');
 const markup=rows?`<table class="router-table model-library-table" aria-label="Models in startup order"><thead><tr><th>Order</th><th>Model</th><th>Build</th><th>Catalog</th><th>Actions</th></tr></thead><tbody>${rows}</tbody></table>`:'<div class="empty-state">No model presets yet. Click Add model to create the first one.</div>';
 renderModelInspector();
 if(markup===MODEL_LIBRARY_MARKUP)return;
 const focus=rememberControl(library);MODEL_LIBRARY_MARKUP=markup;library.innerHTML=markup;restoreControl(library,focus);
 library.querySelectorAll('[data-lib-select]').forEach(b=>b.onclick=()=>selectLibraryModel(b.dataset.libSelect));
 library.querySelectorAll('[data-lib-edit]').forEach(b=>b.onclick=()=>editPresetInDrawer(b.dataset.libEdit,false));
 library.querySelectorAll('[data-lib-clone]').forEach(b=>b.onclick=()=>editPresetInDrawer(b.dataset.libClone,true));
 library.querySelectorAll('[data-lib-toggle]').forEach(b=>b.onclick=()=>{const p=ROUTER_PRESETS.find(x=>x.alias===b.dataset.libToggle);if(p)saveRouterRowChange('/api/router-preset-toggle',{alias:p.alias,enabled:!p.enabled},p.enabled?'Model disabled':'Model enabled')});
 library.querySelectorAll('[data-lib-delete]').forEach(b=>b.onclick=()=>{const alias=b.dataset.libDelete;if(confirm(`Delete model preset ${alias}? The GGUF file will remain on disk.`))saveRouterRowChange('/api/router-preset-delete',{alias},'Model deleted')});
 for(const row of library.querySelectorAll('.model-library-row')){
  const handle=row.querySelector('[data-order-handle]');
  handle.addEventListener('dragstart',e=>{if(MODEL_ORDER_BUSY||!sortable){e.preventDefault();return}MODEL_DRAG_ACTIVE=true;e.dataTransfer.setData('text/plain',row.dataset.orderAlias);e.dataTransfer.effectAllowed='move';row.classList.add('dragging')});
  handle.addEventListener('dragend',()=>{MODEL_DRAG_ACTIVE=false;library.querySelectorAll('.dragging,.drop-target').forEach(r=>r.classList.remove('dragging','drop-target'));renderModelLibrary()});
  row.addEventListener('dragover',e=>{if(MODEL_ORDER_BUSY||!sortable)return;e.preventDefault();e.dataTransfer.dropEffect='move';row.classList.add('drop-target')});
  row.addEventListener('dragleave',e=>{if(!row.contains(e.relatedTarget))row.classList.remove('drop-target')});
  row.addEventListener('drop',e=>{e.preventDefault();row.classList.remove('drop-target');MODEL_DRAG_ACTIVE=false;moveModelOrder(e.dataTransfer.getData('text/plain'),row.dataset.orderAlias)});
 }
 library.querySelectorAll('[data-order-up]').forEach(btn=>btn.onclick=()=>moveModelOrder(btn.dataset.orderUp,(ROUTER_PRESETS||[])[ROUTER_PRESETS.findIndex(p=>p.alias===btn.dataset.orderUp)-1]?.alias));
 library.querySelectorAll('[data-order-down]').forEach(btn=>btn.onclick=()=>moveModelOrder(btn.dataset.orderDown,(ROUTER_PRESETS||[])[ROUTER_PRESETS.findIndex(p=>p.alias===btn.dataset.orderDown)+1]?.alias));
}

async function moveModelOrder(from,to){
 if(MODEL_ORDER_BUSY||!from||!to||from===to)return;
 const previous=ROUTER_PRESETS,order=[...previous],a=order.findIndex(p=>p.alias===from),b=order.findIndex(p=>p.alias===to);
 if(a<0||b<0)return;
 order.splice(b,0,order.splice(a,1)[0]);MODEL_ORDER_BUSY=true;ROUTER_PRESETS=order;renderModelLibrary();renderRouterPresets();
 try{const j=await post('/api/router-preset-order',{aliases:order.map(p=>p.alias)},{label:'Saving model load order...'});ROUTER_PRESETS=j.presets||order;toast('Model load order saved for the next Router start')}
 catch(e){ROUTER_PRESETS=previous;toast(e.message,true)}
 finally{MODEL_ORDER_BUSY=false;renderModelLibrary();renderRouterPresets()}
}

// Load one saved Router preset into the model editor; clone mode creates a new alias.
async function editPresetInDrawer(alias,clone=false){if(typeof modelEditorReset==='function'){modelEditorReset();if(CFG?.engine_builds)try{await engineRefresh()}catch(e){toast(e.message,true)}}const p=ROUTER_PRESETS.find(x=>x.alias===alias);if(p?.engine&&p.engine!=='llamacpp')return engineEditModel(p,clone);if(!p?.ui)return toast('This preset has no editable UI snapshot',true);EDITOR_ALIAS=clone?null:p.alias;EDITOR_ORIGINAL_BUILD=clone?null:(p.build||p.ui.build||null);const editable={...p.ui,build:p.build||p.ui.build,model:p.model||p.ui.model,alias:p.alias};await applyUiPreset(editable);$('alias').value=clone?p.alias+'-copy':p.alias;$('alias').dataset.userEdited='1';$('serverMode').value='router';if(typeof modelEditorSelectNative==='function')modelEditorSelectNative();openEditor(clone?'Clone '+p.alias:'Edit '+p.alias);if(clone)setTimeout(()=>{$('alias').focus();$('alias').select()},0)}

// Open the editor using new-model defaults and focus the editable alias.
async function newModelInDrawer(){return modelEditorNew()}

// Refresh choices without silently changing a configured target or external
// draft. Missing selected files remain visible and are rejected by preflight.
function modelFileOptions(select,rows,value='',keepMissing=false){
 const missing=!!value&&!rows.some(row=>row.value===value);
 if(missing&&keepMissing)rows=[...rows,{value,label:'Unavailable file: '+value,disabled:true}];
 const markup=rows.map(row=>`<option value="${esc(row.value)}"${row.disabled?' disabled data-file-unavailable="true"':''}>${esc(row.label)}</option>`).join('');
 if(select.innerHTML!==markup)select.innerHTML=markup;
 if(rows.some(row=>row.value===value))select.value=value;
 select.dataset.fileUnavailable=missing&&keepMissing?'true':'';
}
function rebuildHierarchy(saved=null){
 const previous=saved||{supplier:$('supplier').value,variant:$('variant').value,model:$('model').value,draft:$('draft').value};
 const target=MODELS.find(m=>m.path===previous.model);
 const supplier=target?.supplier||previous.supplier||'',variant=target?.variant||previous.variant||'';
 modelFileOptions($('supplier'),[...new Set(MODELS.map(m=>m.supplier))].map(value=>({value,label:value})),supplier,!!previous.model);
 const variants=[...new Set(MODELS.filter(m=>m.supplier===$('supplier').value).map(m=>m.variant))];
 modelFileOptions($('variant'),variants.map(value=>({value,label:value})),variant,!!previous.model);
 const files=MODELS.filter(m=>m.supplier===$('supplier').value&&m.variant===$('variant').value);
 modelFileOptions($('model'),files.map(m=>({value:m.path,label:m.file+' - '+(m.size/1073741824).toFixed(2)+' GiB'})),previous.model||'',true);
 modelFileOptions($('draft'),[{value:'',label:'None / use target model'},...MODELS.map(m=>({value:m.path,label:m.supplier+' / '+m.variant+' / '+m.file}))],previous.draft||'',true);
 $('modelCount').textContent=`${MODELS.length} GGUF file(s)`;
 updateCommand();
}
function rebuildVariants(){const variants=[...new Set(MODELS.filter(m=>m.supplier===$('supplier').value).map(m=>m.variant))];modelFileOptions($('variant'),variants.map(value=>({value,label:value})),$('variant').value);rebuildFiles()}
function rebuildFiles(){const files=MODELS.filter(m=>m.supplier===$('supplier').value&&m.variant===$('variant').value);modelFileOptions($('model'),files.map(m=>({value:m.path,label:m.file+' - '+(m.size/1073741824).toFixed(2)+' GiB'})),$('model').value);updateCommand()}

// A focus/pointer/keyboard gesture rescans the shared GGUF root. Overlapping
// gestures share one request; the reply preserves choices made while it ran.
// A changed root invalidates old replies instead of restoring an old inventory.
let MODEL_FILE_SCAN=null;
function refreshModelFileChoices(){
 const root=CFG?.model_root||'';
 if(MODEL_FILE_SCAN?.root===root)return MODEL_FILE_SCAN.promise;
 const scan={root};
 for(const id of ['supplier','variant','model','draft'])$(id).setAttribute('aria-busy','true');
 MODEL_FILE_SCAN=scan;
 scan.promise=(async()=>{
  try{
   const reply=await post('/api/refresh-models',{}, {busy:false});
   if(CFG?.model_root!==root||(reply.model_root!==undefined&&reply.model_root!==root)||MODEL_FILE_SCAN!==scan)return false;
   MODELS=reply.models||[];rebuildHierarchy();syncSpecUi();return true;
  }finally{
   if(MODEL_FILE_SCAN===scan){MODEL_FILE_SCAN=null;for(const id of ['supplier','variant','model','draft'])$(id).removeAttribute('aria-busy')}
  }
 })();return scan.promise;
}
function bindModelFileRefresh(){
 let observed=null;
 const refresh=()=>{const pending=refreshModelFileChoices();if(pending!==observed){observed=pending;pending.catch(error=>toast(error.message,true))}};
 for(const id of ['supplier','variant','model','draft']){
  const select=$(id);select.addEventListener('focus',refresh);select.addEventListener('pointerdown',refresh);
  select.addEventListener('keydown',event=>{if(['ArrowDown','ArrowUp',' ','Enter','F4'].includes(event.key))refresh()});
 }
}

function selectLibraryModel(alias){
 INSPECTED_ALIAS=alias;
 for(const row of $('modelLibrary').querySelectorAll('.model-library-row')){
  const selected=row.dataset.orderAlias===alias;row.classList.toggle('selected',selected);
  row.querySelector('[data-lib-select]')?.setAttribute('aria-pressed',String(selected));
 }
 renderModelInspector();
}

function renderModelInspector(){
 const root=$('modelInspector');if(!root)return;
 const p=ROUTER_PRESETS.find(p=>p.alias===INSPECTED_ALIAS)||ROUTER_PRESETS[0];
 if(!p){INSPECTED_ALIAS=null;root.innerHTML='<div class="section-index">Selected model</div><p class="muted">Select a model to inspect its saved configuration.</p>';return}
 INSPECTED_ALIAS=p.alias;
 const ui=p.ui||{},m=liveFor(p.alias),running=LAST_STATUS?.running&&LAST_STATUS.mode==='router';
 const state=!p.enabled?'disabled':!running?'unloaded':MODEL_STATUS_ERROR?'unknown':!MODEL_STATUS_FETCHED?'checking':m?.status?.value||'unloaded';
 const value=v=>v===undefined||v===null||v===''?'Build default':String(v);
 const modes={manual:'Manual',even:'Even split',priority:'Adaptive auto-fit',priority_split:'Calculated priority'};
 const pairs=p.engine&&p.engine!=='llamacpp'?[['Engine',p.engine],...Object.entries(p.settings||{}).map(([k,v])=>[k,String(v)])]:[['Context',value(ui.ctx)],['Parallel slots',value(ui.parallel)],['Cache K / V',value(ui.cacheK)+' / '+value(ui.cacheV)],['GPU distribution',modes[ui.gpuPriority]||'Manual'],...(['priority','priority_split'].includes(ui.gpuPriority)?[['Minimum reserve',value(ui.gpuReserve)+' MiB']]:[]),['Device order',Array.isArray(ui.devices)&&ui.devices.length?ui.devices.join(' -> '):'Build default']];
 const markup=`<div class="inspector-heading"><div class="section-index">Selected model</div><h2>${esc(p.alias)}</h2><span class="badge ${esc(state)}">${esc(state)}</span><p class="model-path">${esc(p.model||'No GGUF path saved')}</p><h3>Build / startup</h3><div class="config-path">${esc(modelBuildLabel(p))}</div><p class="muted">${p.load_on_startup?'Load at Router start':'On demand'}</p></div><div class="inspector-settings"><h3>Saved configuration</h3><dl>${pairs.map(([k,v])=>`<div><dt>${esc(k)}</dt><dd>${esc(v)}</dd></div>`).join('')}</dl><p class="inspector-note">${p.engine&&p.engine!=='llamacpp'?'Saved settings take effect after Unload and Load in Router / Serving. Native JSON controls model paths and placement.':'Saved values are shown here. Automatic fitting and calculated placement are resolved when the model loads.'}</p></div><button type="button" class="inspector-edit" data-inspector-edit="${esc(p.alias)}">Edit configuration</button>`;
 if(root.innerHTML!==markup){const focus=rememberControl(root);root.innerHTML=markup;restoreControl(root,focus)}
}
