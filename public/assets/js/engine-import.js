// GPL-3.0-only. Explicit JSON import and definition-driven setup guidance.
let ENGINE_IMPORT_SERIAL=0,ENGINE_IMPORT_PENDING=false;
function engineResetImportState(){
 ++ENGINE_IMPORT_SERIAL;ENGINE_IMPORT_PENDING=false;
 if($('engineImportConfig'))$('engineImportConfig').value='';
 for(const id of ['engineImportError','engineImportStatus'])if($(id))$(id).textContent='';
 $('engineImportConfig')?.removeAttribute('aria-invalid');$('engineImportWarnings')?.replaceChildren();$('engineImportWarnings')?.classList.add('hidden');
 if($('engineNativeConfigField'))$('engineNativeConfigField').open=false;
}
function engineBuildLabels(){
 const d=engineDefinition($('engineType').value),python=/\.py$/i.test(d?.argv?.[1]||''),fields=d?.ui?.build_fields||{};
 const defaults={executable:{label:python?'Python interpreter':'Server executable / interpreter',description:python?'Runs the engine’s Python server script. Select the Python executable in the prepared environment.':'Runs the engine’s server entry point. Select its executable, or the prepared interpreter used by its script.',placeholder:python?'Prepared environment Python executable':'Exact server executable or interpreter'},runtime_executable:{label:'Model inference executable',description:'Runs the model, separately from the server entry point. Also used for optional engine-option discovery.',placeholder:'Native executable that runs the model'}};
 for(const [key,id] of [['executable','engineExecutable'],['runtime_executable','engineRuntimeExecutable']]){const entry={...defaults[key],...(fields[key]||{})};document.querySelector(`label[for="${id}"]`).textContent=entry.label;$(id+'Help').textContent=entry.description;$(id).placeholder=entry.placeholder;}
}
function engineRestoreFieldLabel(f){
 if(Object.hasOwn(ENGINE_INHERITED,f.key))return $('engineConfigMode').value==='import'?'Restore imported value':'Restore configuration value';
 if(f.binding==='none')return 'Clear selection';
 if(engineDefaultPresent(f,ENGINE_EFFECTIVE||{},engineBuild($('engineModelBuild').value)))return 'Use registered build value';
 return 'Use engine default';
}
function engineEmptyFieldLabel(f){
 if(f.file_kind)return engineDefaultPresent(f,ENGINE_EFFECTIVE||{},engineBuild($('engineModelBuild').value))?'Use registered build value':f.file_kind==='directory'?(f.required?'Choose a folder':'Choose a folder if needed'):(f.required?'Choose a file':'Choose a file if needed');
 return f.binding==='none'?'No selection':'Use engine default';
}
function engineBlankFieldHelp(f){
 if(f.file_kind)return f.required?'This path must be supplied here or by the selected build/configuration; the engine cannot discover an arbitrary data location.':'Set this path if your model needs the option. Leaving it out does not discover a data folder automatically.';
 return f.binding==='none'?'':engineDefaultPresent(f,ENGINE_EFFECTIVE||{},engineBuild($('engineModelBuild').value))?'Blank uses the registered build value.':'Blank leaves this option out; the engine decides its default behavior.';
}
function engineImportMessages(messages){const list=$('engineImportWarnings');list.replaceChildren();for(const message of messages){const item=document.createElement('li');item.textContent=message;list.append(item)}list.classList.toggle('hidden',!messages.length);}
async function engineImportFile(file){
 if(!file)return false;
 const serial=++ENGINE_IMPORT_SERIAL,build=$('engineModelBuild').value;ENGINE_IMPORT_PENDING=true;$('engineImportError').textContent='';$('engineImportConfig').removeAttribute('aria-invalid');$('engineImportStatus').textContent='Reading configuration JSON…';engineImportMessages([]);syncEditorActions();
 try{
  if(file.size>1048576)throw Error('Configuration JSON exceeds 1 MiB.');
  const value=JSON.parse(await file.text());if(!value||Array.isArray(value)||typeof value!=='object')throw Error('Choose a JSON configuration object.');
  if(serial!==ENGINE_IMPORT_SERIAL||build!==$('engineModelBuild').value)return false;
  const result=await post('/api/engine-import-inspect',{id:build,native_config:value},{busy:false}),inspection=result.inspection;
  if(serial!==ENGINE_IMPORT_SERIAL||build!==$('engineModelBuild').value)return false;
  if(!inspection||typeof inspection.model!=='string'||typeof inspection.alias!=='string')throw Error('Could not inspect this configuration. Keep your current settings and try again.');
  // Commit once parsing/inspection succeeds. Failed imports leave the draft intact.
  $('engineNativeConfig').value=JSON.stringify(value,null,2);$('engineConfigMode').value='import';engineHydrate(value,true);engineRenderFields();
  const warnings=[...(inspection.warnings||[])],current=$('alias').value.trim();
  if(!current&&inspection.alias){$('alias').value=inspection.alias;$('alias').dataset.userEdited='1';}
  else if(current&&inspection.alias&&current!==inspection.alias)warnings.push('Configuration alias: '+inspection.alias+'. Your current API alias was kept.');
  $('engineModelPath').value=inspection.model;$('engineModelPath').removeAttribute('aria-invalid');$('engineModelPathError').textContent='';
  if($('alias').value.trim()&&validateAlias())warnings.push('Correct the imported alias in Model identity above.');
  modelEditorSyncIdentity();syncEditorIdentity();
  $('engineImportStatus').textContent='Imported '+file.name+'. Model paths and mapped settings are filled below. Review and edit them before Save. Nothing has been saved or launched.';
  engineImportMessages(warnings);$('engineModelErrors').textContent='';return true;
 }catch(e){
  if(serial===ENGINE_IMPORT_SERIAL){$('engineImportError').textContent=e instanceof SyntaxError?'This file is not valid JSON. Choose the engine’s configuration JSON file.':e.message;$('engineImportConfig').setAttribute('aria-invalid','true');$('engineImportStatus').textContent='Import failed. Your previous configuration and fields were kept.';}
  return false;
 }finally{if(serial===ENGINE_IMPORT_SERIAL){ENGINE_IMPORT_PENDING=false;syncEditorActions()}}
}
$('engineModelPath').addEventListener('input',()=>{$('engineModelPathError').textContent='';$('engineModelPath').removeAttribute('aria-invalid')});
$('engineImportConfig').onchange=async event=>{try{return await engineImportFile(event.target.files?.[0])}finally{event.target.value=''}};
