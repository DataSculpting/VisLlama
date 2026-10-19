// GPL-3.0-only. One editor shell, with native and declarative engine adapters.
// Native fields/serialization stay in editor.js. New engine families use engines.js.
let MODEL_EDITOR_KIND='llamacpp',MODEL_EDITOR_FAMILY='llamacpp',MODEL_EDITOR_ORIGINAL_FAMILY=null,MODEL_EDITOR_DRAFTS=new Map(),MODEL_EDITOR_SWITCHING=false,MODEL_EDITOR_SESSION=0;
function modelEditorExternal(){return MODEL_EDITOR_KIND==='extension'}
function modelEditorFamilyChanged(){return !!MODEL_EDITOR_ORIGINAL_FAMILY&&MODEL_EDITOR_ORIGINAL_FAMILY!==MODEL_EDITOR_FAMILY}
function modelEditorReset(){
 ++MODEL_EDITOR_SESSION;if(typeof engineResetImportState==='function')engineResetImportState();
 MODEL_EDITOR_KIND='llamacpp';MODEL_EDITOR_FAMILY='llamacpp';MODEL_EDITOR_ORIGINAL_FAMILY=null;MODEL_EDITOR_DRAFTS.clear();++ENGINE_CAPABILITY_SERIAL;MODEL_EDITOR_SWITCHING=false;
 $('engineEditorMount')?.classList.add('hidden');$('engineModelPanel')?.classList.add('hidden');$('nativeModelEditor')?.classList.remove('hidden');$('modelEngineChangeNote')?.classList.add('hidden');$('alias').removeAttribute('aria-invalid');$('aliasError').textContent='';$('aliasError').classList.add('hidden');
}
function modelEditorMount(){
 const panel=$('engineModelPanel');if(panel&&!$('engineEditorMount').contains(panel))$('engineEditorMount').append(panel);
 // Alias is the same physical control for every engine; legacy native fields remain mounted.
 $('singleBuildField').classList.add('hidden');$('singleBuildField').setAttribute('aria-hidden','true');
 $('modelBuildChoice').onchange=()=>modelEditorChangeBuild().catch(e=>toast(e.message,true));
 $('alias').addEventListener('input',modelEditorSyncIdentity);
 modelEditorRenderChoices();
}
function modelEditorRenderChoices(selected){
 const select=$('modelBuildChoice'),keep=selected||select.value;
 const native=(CFG?.builds||[]).map(b=>({value:'native:'+b.name,label:b.name+' — llama.cpp'}));
 const external=(ENGINE_REGISTRY.builds||[]).map(b=>({value:'extension:'+b.id,label:b.name+' — '+(engineDefinition(b.engine)?.name||b.engine)}));
 const choices=[...native,...external];
 if(keep&&!choices.some(b=>b.value===keep))choices.push({value:keep,label:'Unavailable build: '+keep,missing:true});
 select.innerHTML=choices.map(b=>`<option value="${esc(b.value)}" ${b.missing?'disabled':''}>${esc(b.label)}</option>`).join('');
 if(keep&&choices.some(b=>b.value===keep))select.value=keep;
}
function modelEditorSyncIdentity(){
 if(!modelEditorExternal())return;
 $('engineModelAlias').value=$('alias').value;ENGINE_EDIT_MODEL=EDITOR_ALIAS;
}
function modelEditorSelectNative(){
 MODEL_EDITOR_KIND='llamacpp';MODEL_EDITOR_FAMILY='llamacpp';
 if(MODEL_EDITOR_ORIGINAL_FAMILY===null&&EDITOR_ALIAS)MODEL_EDITOR_ORIGINAL_FAMILY=ROUTER_PRESETS.find(p=>p.alias===EDITOR_ALIAS)?.engine||'llamacpp';
 modelEditorRenderChoices('native:'+$('build').value);modelEditorShow();
}
function modelEditorShow(){
 const ext=modelEditorExternal(),missing=ext&&!engineBuild($('engineModelBuild').value);$('nativeModelEditor').classList.toggle('hidden',ext);$('engineEditorMount').classList.toggle('hidden',!ext);$('engineModelPanel').classList.toggle('hidden',!ext);
 $('singleBuildField').classList.add('hidden');
 $('modelBuildChoiceStatus').textContent=missing?'The saved build is unavailable. Select a registered build or restore its registration in Settings > Manage builds.':ext?'Options come from this engine definition and the selected build’s discovered capabilities.':(!CFG?.model_root?'Set a GGUF model root in Settings to select a llama.cpp model.':'Uses the existing llama.cpp model and GPU controls.');
 const changed=modelEditorFamilyChanged();$('modelEngineChangeNote').classList.toggle('hidden',!changed);
 $('modelEngineChangeNote').textContent='Engine type changed. Review the model path and settings below. Saving replaces this preset’s engine configuration; options from the previous engine are not translated. Stop Router before saving this change.';
 $('editorSubtitle').textContent='Configure the selected engine, save its preset, then load when ready.';
 modelEditorSyncIdentity();syncEditorActions();
}
async function modelEditorNew(){
 modelEditorReset();EDITOR_ALIAS=null;EDITOR_ORIGINAL_BUILD=null;
 if(CFG?.engine_builds)try{await engineRefresh()}catch(e){toast(e.message,true)}
 const native=CFG?.builds?.find(b=>b.available)||CFG?.builds?.[0],external=ENGINE_REGISTRY.builds[0];
 if(!native&&external)return engineEditModel();
 if(!native){await engineOpenBuilds();toast('Register an engine build before adding a model.');return}
 await applyUiPreset(newModelDefaults());$('alias').value='';$('alias').dataset.userEdited='';$('serverMode').value='router';modelEditorSelectNative();openEditor('Add model');modelEditorShow();ensureAlias();$('alias').focus();$('alias').select();
}
async function engineEditModel(p=null,clone=false){
 modelEditorReset();const session=MODEL_EDITOR_SESSION,ok=await enginePrepareModel(p,clone);if(!ok||session!==MODEL_EDITOR_SESSION)return;
 MODEL_EDITOR_KIND='extension';MODEL_EDITOR_FAMILY=engineBuild($('engineModelBuild').value)?.engine||p?.engine||'';
 EDITOR_ALIAS=clone?null:p?.alias||null;EDITOR_ORIGINAL_BUILD=clone?null:p?.build||null;MODEL_EDITOR_ORIGINAL_FAMILY=p&&!clone?p.engine:null;
 $('alias').value=$('engineModelAlias').value;$('alias').dataset.userEdited='1';$('serverMode').value='router';
 modelEditorRenderChoices('extension:'+$('engineModelBuild').value);openEditor((clone?'Clone ':p?'Edit ':'Add ')+(p?.alias||'model'));modelEditorShow();$('alias').focus();if(clone)$('alias').select();
}
function modelEditorCapture(){
 if(modelEditorExternal()){modelEditorSyncIdentity();return {kind:'extension',preset:engineModelPayload()}}
 return {kind:'llamacpp',ui:presetData()};
}
async function modelEditorChangeBuild(){
 if(MODEL_EDITOR_SWITCHING)return;
 const choice=$('modelBuildChoice').value,old=MODEL_EDITOR_FAMILY;
 const ext=choice.startsWith('extension:'),id=choice.slice(choice.indexOf(':')+1),build=ext?engineBuild(id):CFG?.builds.find(b=>b.name===id);
 if(!build){toast('This build is unavailable. Register it in Settings > Manage builds.',true);return}
 const family=ext?build.engine:'llamacpp';let draft;
 try{draft=modelEditorCapture()}catch(e){modelEditorRenderChoices(modelEditorExternal()?'extension:'+$('engineModelBuild').value:'native:'+$('build').value);toast('Correct the current configuration before switching builds: '+e.message,true);return}
 MODEL_EDITOR_DRAFTS.set(old,draft);const alias=$('alias').value;
 const session=MODEL_EDITOR_SESSION;MODEL_EDITOR_SWITCHING=true;$('modelBuildChoice').disabled=true;
 try{
  const saved=MODEL_EDITOR_DRAFTS.get(family);
  if(ext){
   // Only settings from this family are restored. A different family starts clean.
   const source=saved?.kind==='extension'?saved.preset:{model:draft.kind==='extension'?draft.preset.model:draft.ui.model,settings:{},native_config:{},config_mode:'create'};
   const ok=await enginePrepareModel({...source,alias,build:id},false,!saved);if(session!==MODEL_EDITOR_SESSION)return;if(!ok)throw Error('Could not prepare this engine’s controls.');
   MODEL_EDITOR_KIND='extension';MODEL_EDITOR_FAMILY=family;
  }else{
   MODEL_EDITOR_KIND='llamacpp';MODEL_EDITOR_FAMILY='llamacpp';
   const source=saved?.kind==='llamacpp'?saved.ui:{...newModelDefaults(),model:draft.preset?.model||'',alias};
   await applyUiPreset({...source,build:id,alias});if(session!==MODEL_EDITOR_SESSION)return;
  }
  $('alias').value=alias;modelEditorRenderChoices(choice);modelEditorShow();updateCommand();
 }catch(e){
  if(session!==MODEL_EDITOR_SESSION)return;MODEL_EDITOR_FAMILY=old;MODEL_EDITOR_KIND=draft.kind;
  if(draft.kind==='extension')await enginePrepareModel({...draft.preset,alias},false);else await applyUiPreset(draft.ui);
  modelEditorRenderChoices(draft.kind==='extension'?'extension:'+draft.preset.build:'native:'+draft.ui.build);modelEditorShow();throw e;
 }finally{if(session===MODEL_EDITOR_SESSION){MODEL_EDITOR_SWITCHING=false;$('modelBuildChoice').disabled=false;syncEditorActions()}}
}
function modelEditorCanSave(){
 if(modelEditorExternal()&&typeof ENGINE_IMPORT_PENDING!=='undefined'&&ENGINE_IMPORT_PENDING){toast('Wait for the configuration import to finish.',true);return false}
 if(MODEL_EDITOR_SWITCHING){toast('Wait for the selected build’s controls to finish loading.',true);return false}
 if(modelEditorFamilyChanged()&&LAST_STATUS?.running){toast('Stop Router before changing a model engine type.',true);return false}
 if(modelEditorExternal()&&!engineBuild($('engineModelBuild').value)){toast('Select a registered engine build before saving.',true);return false}
 if(!modelEditorExternal()&&!CFG?.model_root){toast('Set the GGUF model root in Settings before saving a llama.cpp model.',true);return false}
 return true;
}
function modelEditorEngineAction(){
 const alias=EDITOR_ALIAS||$('alias').value.trim(),preset=ROUTER_PRESETS.find(p=>p.alias===alias),build=$('engineModelBuild').value;
 const c=routerModelControls(preset||{alias,enabled:true,build,engine:MODEL_EDITOR_FAMILY});
 let reason=typeof ENGINE_IMPORT_PENDING!=='undefined'&&ENGINE_IMPORT_PENDING?'Wait for the configuration import to finish.':EDITOR_SAVE_BUSY?'A preset save is in progress.':MODEL_EDITOR_SWITCHING?'Wait for the selected build’s controls.':SERVER_ACTION_BUSY?'Wait for the Router action to finish.':!LAST_STATUS?'Checking Router status.':!LAST_STATUS.running?'Start the Router before loading this model.':modelEditorFamilyChanged()?'Stop Router before changing a model engine type.':c.engine?.build!==build||alias!==$('alias').value.trim()?'Save the preset, then restart Router to activate this model/build assignment.':'';
 if(!reason)reason=['loaded','sleeping'].includes(c.state)?c.unloadReason:c.loadReason;
 return {state:c.state,label:['loaded','sleeping'].includes(c.state)?'Save and reload':'Save and load',reason};
}
async function modelEditorSaveEngine(reload=false){
 if(EDITOR_SAVE_BUSY||!modelEditorCanSave())return false;
 modelEditorSyncIdentity();if(validateAlias()){return false}if(!engineValidateFields())return false;
 if(reload){const action=editorModelAction();if(action.reason){toast(action.reason,true);return false}}
 const r=engineModelPayload();r.replace_engine=modelEditorFamilyChanged();
 const target=ROUTER_PRESETS.find(p=>p.alias===r.alias);if(target&&r.alias!==EDITOR_ALIAS){if(!await confirmPresetOverwrite(r.alias))return false;r.overwrite=true;r.replace_engine||=(target.engine||'llamacpp')!==MODEL_EDITOR_FAMILY;}
 const ownedBefore=!!(LAST_STATUS?.router_engines||[]).find(e=>e.managed&&e.running&&(e.models||[]).includes(EDITOR_ALIAS||r.alias));
 const runtimeToken=LAST_STATUS?.runtime_token,original=EDITOR_ALIAS||r.alias,wasRunning=!!(LAST_STATUS?.running&&LAST_STATUS.mode==='router');
 let saved=false,live;
 EDITOR_SAVE_BUSY=true;syncEditorActions();
 try{
  if(reload){await post('/api/engine-load-check',{...r,runtime_token:runtimeToken},{label:'Checking engine settings before reload...'});live=await currentRouterModel(original,runtimeToken);if(!live||!['loaded','sleeping','unloaded','failed'].includes(live.status?.value)||MODEL_ACTION_PENDING.has(original))throw Error('Cannot confirm model status. Check Router / Serving before saving and loading.');}
  const j=await post('/api/engine-preset-save',r);saved=true;ROUTER_PRESETS=j.presets;renderModelLibrary();renderRouterPresets();
  if(reload){
   const current=await currentRouterModel(original,runtimeToken);if(!current||!['loaded','sleeping','unloaded','failed'].includes(current.status?.value)||MODEL_ACTION_PENDING.has(original))throw Error('Model state changed after saving. Check Router / Serving before retrying reload.');live=current;
   MODEL_ACTION_PENDING.set(original,'unload');syncEditorActions();
   if(['loaded','sleeping'].includes(live.status?.value)||ownedBefore){
    await post('/api/router-unload',{model:original,runtime_token:runtimeToken},{label:'Unloading current engine model...'});await waitForRouterModel(original,'unloaded',30000,runtimeToken);
   }
  }
  if(wasRunning)await applyRouterConfig(false,true,runtimeToken);
  if(reload){MODEL_ACTION_PENDING.set(original,'load');await post('/api/router-load',{model:r.alias,runtime_token:runtimeToken},{label:'Loading model with saved engine settings...'});await waitForRouterModel(r.alias,'loaded',300000,runtimeToken);await refreshRouterModels(true);}
  closeEditor();toast(reload?'Model loaded with saved settings.':'Preset saved. Loaded models keep their current settings until reloaded.');return true;
 }catch(e){if(saved&&/Restart Router/i.test(e.message)){closeEditor();toast('Preset saved. '+e.message);return true}toast((saved?'Preset saved, but '+(reload?'load/reload':'Router catalog update')+' failed: ':'')+e.message,true);return saved}
 finally{MODEL_ACTION_PENDING.delete(original);EDITOR_SAVE_BUSY=false;syncEditorActions();if(saved)refreshRouterModels(true)}
}
