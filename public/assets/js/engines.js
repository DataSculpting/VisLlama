// GPL-3.0-only. One form renderer for reusable engine definitions and installed builds.
let ENGINE_REGISTRY={definitions:[],builds:[]},ENGINE_EDIT_BUILD=null,ENGINE_EDIT_MODEL=null,ENGINE_SETTINGS={},ENGINE_INHERITED={},ENGINE_EFFECTIVE=null,ENGINE_CAPABILITY_SERIAL=0,ENGINE_CAPABILITY_KEYS=[],ENGINE_DEFINITION_EDIT=null;
async function engineRefresh(){ENGINE_REGISTRY=await post('/api/engine-list',{});if(CFG)CFG.engine_builds=ENGINE_REGISTRY.builds;if(typeof renderEngineBuildSummary==='function')renderEngineBuildSummary();if(typeof modelEditorRenderChoices==='function')modelEditorRenderChoices();return ENGINE_REGISTRY}
function engineDefinition(id){return ENGINE_REGISTRY.definitions.find(d=>d.id===id)}
function engineBuild(id){return ENGINE_REGISTRY.builds.find(b=>b.id===id)}
function engineClearBuild(){engineClearBuildErrors();engineBuildLabels();ENGINE_EDIT_BUILD=null;for(const id of ['engineBuildName','engineRoot','engineExecutable','engineRuntimeExecutable'])$(id).value='';$('engineRuntimeLibraries').value='[]';$('engineConcurrency').checked=false;if(typeof engineBuildLibraries==='function')engineBuildLibraries();$('engineType').disabled=false}
function engineBuildForm(b){ENGINE_EDIT_BUILD=b.id;$('engineType').value=b.engine;$('engineType').disabled=true;$('engineBuildName').value=b.name;$('engineRoot').value=b.root;$('engineExecutable').value=b.executable;$('engineRuntimeExecutable').value=b.runtime_executable||'';$('engineRuntimeLibraries').value=JSON.stringify(b.runtime_library_dirs||[]);$('engineConcurrency').checked=!!b.allow_concurrent;engineTypeChanged();if(typeof engineBuildLibraries==='function')engineBuildLibraries()}
function engineTypeChanged(){engineBuildLabels();$('engineDefinitionNote').textContent=engineDefinition($('engineType').value)?.description||'No valid engine definitions installed.'}
async function engineOpenBuilds(id=null){try{await engineRefresh();engineClearBuild();$('engineType').innerHTML=ENGINE_REGISTRY.definitions.map(d=>`<option value="${esc(d.id)}">${esc(d.name)} (${esc(d.definition_version)})</option>`).join('');engineTypeChanged();engineRenderBuilds();if(typeof id==='string'&&engineBuild(id))engineBuildForm(engineBuild(id));openModal('enginesModal')}catch(e){toast(e.message,true)}}
function engineRenderBuilds(){
 $('engineRegistryErrors').textContent=ENGINE_REGISTRY.errors.map(e=>`${e.id}: invalid or duplicate definition; review engine.json`).join('\n');
 $('engineBuildRows').innerHTML=ENGINE_REGISTRY.builds.map(b=>`<p><b>${esc(b.name)}</b> — ${esc(b.engine)} <button data-engine-edit="${esc(b.id)}">Edit</button> <button data-engine-probe="${esc(b.id)}">Check compatibility</button> <button data-engine-discover="${esc(b.id)}">Discover options</button> <button data-engine-delete="${esc(b.id)}">Remove</button></p>`).join('');
 $('engineBuildRows').querySelectorAll('[data-engine-edit]').forEach(x=>x.onclick=()=>engineBuildForm(engineBuild(x.dataset.engineEdit)));
 $('engineBuildRows').querySelectorAll('[data-engine-probe]').forEach(x=>x.onclick=async()=>{try{const r=await post('/api/engine-probe',{id:x.dataset.engineProbe},{label:'Checking registered engine build...'});toast(r.compatible?'Required startup flags found. Hardware compatibility remains unverified.':`Build probe failed${r.reference?' — '+r.reference:''}`,!r.compatible)}catch(e){toast(e.message,true)}});
 $('engineBuildRows').querySelectorAll('[data-engine-discover]').forEach(x=>x.onclick=()=>engineDiscover(x.dataset.engineDiscover,false));
 $('engineBuildRows').querySelectorAll('[data-engine-delete]').forEach(x=>x.onclick=async()=>{if(!confirm('Remove this build registration? Installation files stay unchanged.'))return;try{await post('/api/engine-build-delete',{id:x.dataset.engineDelete});await engineRefresh();engineRenderBuilds();updateSetup()}catch(e){toast(e.message,true)}});
}
function engineClearBuildErrors(){if($('engineBuildErrors'))$('engineBuildErrors').textContent='';for(const id of ['engineBuildName','engineRoot','engineExecutable','engineRuntimeExecutable','engineRuntimeLibraries']){$(id)?.removeAttribute('aria-invalid');if($(id+'Error'))$(id+'Error').textContent='';}}
function engineBuildFieldError(id,message){if($(id+'Error'))$(id+'Error').textContent=message;$(id).setAttribute('aria-invalid','true');if(id==='engineRuntimeLibraries')$('engineBuildLibraryList')?.querySelector('button')?.focus();else $(id).focus();if($('engineBuildErrors'))$('engineBuildErrors').textContent=message;return validationBlocked(message);}
async function engineSaveBuild(){engineClearBuildErrors();for(const [id,label] of [['engineBuildName','a build name'],['engineRoot','the installation directory'],['engineExecutable','the executable or interpreter']])if(!$(id).value.trim())return engineBuildFieldError(id,'Enter '+label+'.');
 let directories;try{directories=JSON.parse($('engineRuntimeLibraries').value||'[]');if(!Array.isArray(directories)||directories.some(x=>typeof x!=='string'))throw Error();}catch(e){return engineBuildFieldError('engineRuntimeLibraries','Review the library folder list and remove invalid entries.');}
 try{
 const d=engineDefinition($('engineType').value);if(!d)throw Error('Choose an engine type before registering the build.');
 await post('/api/engine-build-save',{id:ENGINE_EDIT_BUILD,allow_concurrent:$('engineConcurrency').checked,engine:d.id,definition_digest:d.digest,name:$('engineBuildName').value.trim(),root:$('engineRoot').value.trim(),executable:$('engineExecutable').value.trim(),runtime_executable:$('engineRuntimeExecutable').value.trim(),runtime_library_dirs:directories});
 await engineRefresh();engineRenderBuilds();engineClearBuild();updateSetup();toast('Build registered. Compatibility will be checked automatically when loading.');
}catch(e){toast(e.message,true)}}
function engineParseArray(value,key){try{return JSON.parse(value)}catch(e){const message='Use a JSON array of argument strings.';engineFieldError(key,message);throw Error(message)}}
function engineReadFields(){
 const fields=new Map((ENGINE_EFFECTIVE?.fields||[]).map(f=>[f.key,f]));
 for(const el of $('engineModelFields').querySelectorAll('[data-engine-field]')){
  if(el.disabled)continue;const key=el.dataset.engineField,f=fields.get(key)||{},value=el.dataset.type==='boolean'?(el.dataset.unset==='true'?'':String(el.checked)):el.value;
  if(!Object.hasOwn(ENGINE_SETTINGS,key)&&el.dataset.inherited==='true'&&value===el.dataset.inheritedValue)continue;
  if(value===''){
   if(['config','config-flag'].includes(f.binding)&&(Object.hasOwn(ENGINE_INHERITED,key)||ENGINE_SETTINGS[key]===null))ENGINE_SETTINGS[key]=null;
   else delete ENGINE_SETTINGS[key];
  }else ENGINE_SETTINGS[key]=el.dataset.type==='json-array'?engineParseArray(value,key):el.dataset.type==='boolean'?value==='true':['integer','number'].includes(el.dataset.type)?Number(value):value;
 }
 return {...ENGINE_SETTINGS};
}
function engineRenderFields(){
 const b=engineBuild($('engineModelBuild').value),d=ENGINE_EFFECTIVE||engineDefinition(b?.engine),groups=new Map();
 $('engineNativeConfigField').classList.toggle('hidden',d?.driver!=='native-json');$('engineImportPanel').classList.toggle('hidden',d?.driver!=='native-json');
 for(const f of d?.fields||[]){const group=f.group||'Engine settings';if(!groups.has(group))groups.set(group,[]);groups.get(group).push(f)}
 function render(f){
  const legacy=(f.legacy_keys||[]).find(key=>Object.hasOwn(ENGINE_SETTINGS,key)),own=Object.hasOwn(ENGINE_SETTINGS,f.key),inherited=!own&&(legacy!==undefined||Object.hasOwn(ENGINE_INHERITED,f.key)),v=own?ENGINE_SETTINGS[f.key]:legacy!==undefined?ENGINE_SETTINGS[legacy]:ENGINE_INHERITED[f.key],omitted=own&&v===null;
  const display=v===undefined||v===null?'':f.type==='json-array'?JSON.stringify(v):String(v),inactive=f.available===false||(f.when&&String(Object.hasOwn(ENGINE_SETTINGS,f.when.key)?ENGINE_SETTINGS[f.when.key]:ENGINE_INHERITED[f.when.key])!==String(f.when.equals));
  const id='engineField-'+f.key,description=id+'-description',error=id+'-error',attributes=`id="${esc(id)}" data-engine-field="${esc(f.key)}" data-type="${esc(f.type)}" data-inherited="${inherited}" data-inherited-value="${esc(display)}" aria-describedby="${esc(description)} ${esc(error)}" ${inactive?'disabled':''}`;
  const options=f.enum;let control;
  if(f.type==='boolean')control=`<div class="engine-toggle"><input type="checkbox" ${attributes} data-unset="${display===''}" ${display==='true'?'checked':''}><span>${omitted?'Omitted from generated configuration':display===''?'Use engine default (not set)':display==='true'?'Enabled':'Disabled'}</span></div>`;
  else if(options)control=`<select ${attributes}><option value="">${esc(f.binding==='none'?'No selection':'Use engine default (omit option)')}</option>${display!==''&&!options.map(String).includes(display)?`<option selected value="${esc(display)}">Saved value: ${esc(display)}</option>`:''}${options.map(x=>`<option value="${esc(String(x))}" ${display===String(x)?'selected':''}>${esc(String(x))}</option>`).join('')}</select>`;
  else control=`<input ${f.type==='json-array'&&d.runtime_libraries&&JSON.stringify(f.path)===JSON.stringify(d.runtime_libraries.config_path)?'hidden':''} ${attributes} value="${esc(display)}" placeholder="${esc(engineEmptyFieldLabel(f))}" type="${['integer','number'].includes(f.type)?'number':'text'}" ${f.type==='number'?'step="any"':''} ${f.minimum!==undefined?`min="${esc(String(f.minimum))}"`:''} ${f.maximum!==undefined?`max="${esc(String(f.maximum))}"`:''}>`;
  const explanation=inactive?(f.unavailable_reason||'Available when its dependent setting is selected.'):[omitted?'Omitted from the generated configuration; the engine decides its default behavior. Use the restore button to undo.':inherited?(legacy!==undefined?'Saved value; kept unless edited.':$('engineConfigMode').value==='import'?'Imported value; kept unless edited.':'Configuration value; kept unless edited.'):engineBlankFieldHelp(f),f.description||f.source||'',f.support_notice||''].filter(Boolean).join(' ');
  const buttons=(own||legacy!==undefined?`<button type="button" data-engine-clear="${esc(f.key)}">${esc(engineRestoreFieldLabel(f))}</button>`:'')+(!f.required&&['config','config-flag'].includes(f.binding)&&(display!==''||inherited)?`<button type="button" data-engine-omit="${esc(f.key)}">Omit option</button>`:'');
  return `<div class="field engine-option ${f.file_kind||f.type==='json-array'?'engine-option-wide':''}"><label for="${esc(id)}">${esc(f.label)}${f.flag?` <span class="engine-flag">${esc(f.flag)}</span>`:''}</label><div class="engine-control-row">${control}${f.file_kind?`<button type="button" data-engine-browse="${esc(f.key)}" ${inactive?'disabled':''}>Browse ${f.file_kind==='directory'?'folders':'files'}</button>`:''}</div><small id="${esc(description)}" class="engine-field-help">${esc(explanation)}</small><small id="${esc(error)}" class="alias-error engine-field-error" data-engine-error="${esc(f.key)}" role="alert"></small>${buttons?`<div class="engine-field-actions">${buttons}</div>`:''}</div>`;
 }
 $('engineModelFields').innerHTML=[...groups].map(([group,fields])=>`<fieldset class="engine-form-group"><legend>${esc(group)}</legend><div class="engine-field-grid">${fields.map(render).join('')}</div></fieldset>`).join('');
 const known=new Set((d?.fields||[]).flatMap(f=>[f.key,...(f.legacy_keys||[])])),unknown=Object.keys(ENGINE_SETTINGS).filter(key=>!known.has(key));if(unknown.length)$('engineModelFields').insertAdjacentHTML('beforeend','<fieldset class="engine-form-group"><legend>Preserved inactive settings</legend><p>These saved options are not currently mapped.</p>'+unknown.map(key=>`<div class="engine-option">${esc(key)} <button type="button" data-engine-clear="${esc(key)}">Remove saved option</button></div>`).join('')+'</fieldset>');
 $('engineModelFields').querySelectorAll('[data-engine-browse]').forEach(button=>button.onclick=()=>{const f=d.fields.find(f=>f.key===button.dataset.engineBrowse),id='engineField-'+f.key;(f.file_kind==='directory'?browseFolderInto:browseFileInto)(id,f.label,$(id).value||b?.root||'')});
 if(typeof engineModelLibraries==='function')engineModelLibraries();
 $('engineModelFields').querySelectorAll('[data-engine-clear]').forEach(button=>button.onclick=()=>{const key=button.dataset.engineClear;delete ENGINE_SETTINGS[key];const f=d.fields.find(f=>f.key===key);for(const alias of f?.legacy_keys||[])delete ENGINE_SETTINGS[alias];engineRenderFields()});
 $('engineModelFields').querySelectorAll('[data-engine-omit]').forEach(button=>button.onclick=()=>{ENGINE_SETTINGS[button.dataset.engineOmit]=null;engineRenderFields()});
 $('engineModelFields').querySelectorAll('[data-engine-field]').forEach(el=>{if(el.type==='checkbox')el.indeterminate=el.dataset.unset==='true';el.onchange=()=>{if(el.type==='checkbox')el.dataset.unset='false';try{engineReadFields();engineRenderFields();$('engineModelErrors').textContent=''}catch(e){engineFieldError(el.dataset.engineField,'Use a JSON array of argument strings.')}}});
}
function engineFieldError(key,message){
 const input=$('engineField-'+key),error=$('engineField-'+key+'-error');if(error)error.textContent=message;if(input){input.setAttribute('aria-invalid','true');input.focus()}$('engineModelErrors').textContent=message;return false;
}

async function enginePrepareModel(p=null,clone=false,initialize=false){engineResetImportState();try{
 await engineRefresh();if(!ENGINE_REGISTRY.builds.length){await engineOpenBuilds();toast('Register an engine build first.');return}
 ENGINE_EDIT_MODEL=clone?null:p?.alias||null;ENGINE_SETTINGS={...(p?.settings||{})};ENGINE_INHERITED={};ENGINE_CAPABILITY_KEYS=[...(p?.capability_keys||[])];ENGINE_EFFECTIVE=null;$('engineConfigMode').value=p?(p.config_mode||'import'):'create';$('engineModelErrors').textContent='';$('engineModelPathError').textContent='';$('engineModelPath').removeAttribute('aria-invalid');$('engineModelAlias').value=p?(clone?p.alias+'-copy':p.alias):'';
 $('engineModelBuild').innerHTML=ENGINE_REGISTRY.builds.map(b=>`<option value="${esc(b.id)}">${esc(b.name)} — ${esc(b.engine)}</option>`).join('');if(p){if(p.build&&!engineBuild(p.build))$('engineModelBuild').insertAdjacentHTML('beforeend',`<option value="${esc(p.build)}" disabled>Unavailable build: ${esc(p.build)}</option>`);$('engineModelBuild').value=p.build;}
 $('engineModelAliasError').textContent='';$('engineModelAlias').removeAttribute('aria-invalid');$('engineModelPath').value=p?.model||'';$('engineNativeConfig').value=JSON.stringify(p?.native_config||{},null,2);$('engineLaunchPreview').textContent='';await engineLoadCapabilities(!p||initialize);const savedSettings={...ENGINE_SETTINGS};engineHydrate(JSON.parse($('engineNativeConfig').value));ENGINE_SETTINGS={...ENGINE_SETTINGS,...savedSettings};engineRenderFields();if(p?.config_mode==='import'||p&&p.config_mode===undefined)$('engineImportStatus').textContent='Configuration loaded into the editor. Review and edit the fields below, or import another JSON file. Save stores it in the catalog.';return true;
}catch(e){toast(e.message,true)}}
function engineModelPayload(){return {capability_keys:ENGINE_CAPABILITY_KEYS,config_mode:$('engineConfigMode').value,alias:$('engineModelAlias').value.trim(),original_alias:ENGINE_EDIT_MODEL||'',build:$('engineModelBuild').value,model:$('engineModelPath').value.trim(),settings:engineReadFields(),native_config:JSON.parse($('engineNativeConfig').value)}}
async function engineSaveModel(){return saveEditorPreset(false)}
async function enginePreview(){
 if(typeof modelEditorSyncIdentity==='function')modelEditorSyncIdentity();
 const shared=typeof modelEditorExternal==='function'&&modelEditorExternal();
 const aliasProblem=shared?validateAlias():engineValidateAlias()?'':ENGINE_ALIAS_MESSAGE;
 if(aliasProblem)return validationBlocked(aliasProblem,shared?'alias':'engineModelAlias');
 if(!engineValidateFields())return validationBlocked($('engineModelErrors').textContent||'Review the highlighted engine settings.');
 try{const j=await post('/api/engine-preview',engineModelPayload());$('engineLaunchPreview').textContent=JSON.stringify(j.plan,null,2)}catch(e){toast(e.message,true)}
}
$('engineBuildManager').onclick=engineOpenBuilds;$('engineType').onchange=engineTypeChanged;$('engineClearBuild').onclick=engineClearBuild;$('engineSaveBuild').onclick=engineSaveBuild;
$('engineModelBuild').onchange=async()=>{engineReadFields();ENGINE_EFFECTIVE=null;await engineLoadCapabilities(false);engineRenderFields()};$('engineModelSave').onclick=engineSaveModel;$('engineModelPreview').onclick=enginePreview;


const ENGINE_ALIAS_MESSAGE="Enter a model alias using letters, numbers, dots, underscores, hyphens, or colons. Spaces and slashes aren't allowed.";
function engineValidateAlias(){const input=$('engineModelAlias'),valid=/^[A-Za-z0-9._:-]+$/.test(input.value.trim());$('engineModelAliasError').textContent=valid?'':ENGINE_ALIAS_MESSAGE;input.setAttribute('aria-invalid',String(!valid));if(!valid)input.focus();return valid}
$('engineModelAlias').oninput=()=>{if($('engineModelAlias').getAttribute('aria-invalid')==='true')engineValidateAlias()};

async function engineLoadCapabilities(initialize=false){
 const serial=++ENGINE_CAPABILITY_SERIAL,b=engineBuild($('engineModelBuild').value);if(!b)return;
 const j=await post('/api/engine-capabilities',{id:b.id},{busy:false});if(serial!==ENGINE_CAPABILITY_SERIAL)return;
 ENGINE_EFFECTIVE=j.definition||engineDefinition(b.engine);
 if(initialize)for(const f of ENGINE_EFFECTIVE?.fields||[])if(f.initial!==undefined&&ENGINE_SETTINGS[f.key]===undefined)ENGINE_SETTINGS[f.key]=f.initial;
 const c=ENGINE_EFFECTIVE?.capabilities;$('engineCapabilityStatus').textContent=c?`Build options: ${c.status}. Known definition controls can be configured now; discovery adds options and checks advertised support. It does not load a model.`:'';
 $('engineDiscoverModel').disabled=!(ENGINE_EFFECTIVE?.discovery||[]).length;engineHydrate(JSON.parse($('engineNativeConfig').value||'{}'));$('engineUpdateDefaultControls').classList.toggle('hidden',!(ENGINE_EFFECTIVE?.default_controls_available>0));
}
function engineGetPath(value,path){for(const key of path||[]){if(!value||typeof value!=='object')return undefined;value=value[key]}return value}
function engineHydrate(config,resetOverrides=false){
 ENGINE_INHERITED={};for(const f of (ENGINE_EFFECTIVE||{}).fields||[]){if(resetOverrides&&['config','config-flag'].includes(f.binding)){delete ENGINE_SETTINGS[f.key];for(const key of f.legacy_keys||[])delete ENGINE_SETTINGS[key]}
  if(f.binding==='config'){let value=engineGetPath(config,f.path);for(const flag of f.clear_flags||[]){if(!flag.takes_value)continue;const args=engineGetPath(config,flag.path||['args'])||[],i=args.indexOf(flag.flag);if(i>=0)value=args[i+1]}if(value!==undefined)ENGINE_INHERITED[f.key]=value}
  else if(f.binding==='config-flag'){const args=engineGetPath(config,f.path)||[];for(let i=0;i<args.length;i++){if(args[i]===f.flag)ENGINE_INHERITED[f.key]=f.type==='boolean'?true:args[i+1];else if(typeof args[i]==='string'&&args[i].startsWith(f.flag+'='))ENGINE_INHERITED[f.key]=args[i].slice(f.flag.length+1)}}
 }
}

function engineValidateFields(){
 $('engineModelPath').removeAttribute('aria-invalid');$('engineModelPathError').textContent='';if(!$('engineModelPath').value.trim()){const message='Choose the catalog model file or directory.';$('engineModelPathError').textContent=message;$('engineModelPath').setAttribute('aria-invalid','true');$('engineModelPath').focus();$('engineModelErrors').textContent=message;return false}
 try{
  $('engineModelFields').querySelectorAll('[data-engine-error]').forEach(el=>el.textContent='');$('engineModelFields').querySelectorAll('[data-engine-field]').forEach(el=>el.removeAttribute('aria-invalid'));
  engineReadFields();const config=JSON.parse($('engineNativeConfig').value),d=ENGINE_EFFECTIVE||{},build=engineBuild($('engineModelBuild').value),creating=$('engineConfigMode').value==='create';
  if(!config||Array.isArray(config)||typeof config!=='object')throw Error('Native JSON must be an object.');
  for(const f of d.fields||[]){
   if(f.available===false||f.when&&String(Object.hasOwn(ENGINE_SETTINGS,f.when.key)?ENGINE_SETTINGS[f.when.key]:ENGINE_INHERITED[f.when.key])!==String(f.when.equals))continue;
   const own=Object.hasOwn(ENGINE_SETTINGS,f.key),v=own?ENGINE_SETTINGS[f.key]:ENGINE_INHERITED[f.key];
   if(creating&&f.required&&(v===null||v===undefined||v==='')&&(!(!own&&engineDefaultPresent(f,d,build))))return engineFieldError(f.key,'Enter '+f.label+'.');
   if(!own||v===null||v===undefined)continue;
   if(f.type==='json-array'&&(!Array.isArray(v)||v.some(x=>typeof x!=='string')))return engineFieldError(f.key,f.label+': use a JSON array of argument strings.');
   if(['integer','number'].includes(f.type)){
    if(!Number.isFinite(v)||f.type==='integer'&&!Number.isInteger(v))return engineFieldError(f.key,f.label+': enter '+(f.type==='integer'?'a whole number.':'a number.'));
    if(f.minimum!==undefined&&v<f.minimum)return engineFieldError(f.key,f.label+': enter '+f.minimum+' or greater.');
    if(f.maximum!==undefined&&v>f.maximum)return engineFieldError(f.key,f.label+': enter '+f.maximum+' or less.');
   }
   if(f.enum&&!f.enum.map(String).includes(String(v)))return engineFieldError(f.key,f.label+': choose one of the listed values.');
   if(f.format){const text=String(v);if(!(f.format==='auto-or-integer-csv'&&text==='auto')&&!/^\d+(?:\s*,\s*\d+)*$/.test(text))return engineFieldError(f.key,f.label+': use comma-separated whole numbers'+(f.format==='auto-or-integer-csv'?' or auto.':'.'));}
  }
  $('engineModelErrors').textContent='';return true;
 }catch(e){$('engineModelErrors').textContent=e.message;return false}
}

async function engineDiscover(id,fromModel=true){try{
 const session=typeof MODEL_EDITOR_SESSION==='undefined'?0:MODEL_EDITOR_SESSION;
 const payload={id};if(fromModel){payload.model_context=engineLibraryModelContext();}
 const snapshot=fromModel?JSON.stringify(payload.model_context):null;
 const j=await post('/api/engine-discover',payload,{label:'Discovering installed engine options...'});
 toast(`Discovery saved: ${j.definition?.capabilities?.added_fields||0} additional controls. Unmapped options remain available through advanced configuration.`);
 if(fromModel&&$('engineModelBuild').value===id&&session===(typeof MODEL_EDITOR_SESSION==='undefined'?0:MODEL_EDITOR_SESSION)&&JSON.stringify(engineLibraryModelContext())===snapshot){engineReadFields();await engineLoadCapabilities(false);engineRenderFields();const folders=j.definition?.capabilities?.library_context?.folders;if(folders)engineShowDiscoveryFolders(folders)}
}catch(e){if(fromModel)$('engineModelErrors').textContent=e.message;toast(e.message,true)}}
$('engineDiscoverModel').onclick=()=>engineDiscover($('engineModelBuild').value,true);

$('engineNativeConfig').onchange=()=>{try{engineHydrate(JSON.parse($('engineNativeConfig').value),true);engineRenderFields()}catch(e){$('engineModelErrors').textContent='Native JSON is invalid.'}};
$('engineEditDefinition').onclick=()=>{const d=engineDefinition($('engineType').value);if(!d)return;ENGINE_DEFINITION_EDIT=d;const raw={...d};delete raw.digest;delete raw.definition_file;delete raw.default_controls_available;delete raw.bundled_definition_version;$('engineDefinitionJSON').value=JSON.stringify(raw,null,2);$('engineDefinitionPath').textContent=d.definition_file||'A local copy will be created under presets/engines/.';openModal('engineDefinitionModal')};
$('engineDefinitionSave').onclick=async()=>{try{await post('/api/engine-definition-save',{id:ENGINE_DEFINITION_EDIT.id,expected_digest:ENGINE_DEFINITION_EDIT.digest,definition:JSON.parse($('engineDefinitionJSON').value)});await engineRefresh();if(!$('engineModelPanel').classList.contains('hidden')){await engineLoadCapabilities(false);engineRenderFields()}closeModal('engineDefinitionModal');toast('Local definition saved. Review and update build registrations if its contract changed.')}catch(e){toast(e.message,true)}};

$('engineBrowseRoot').onclick=()=>browseFolderInto('engineRoot','Engine installation directory',$('engineRoot').value);
$('engineBrowseInterpreter').onclick=()=>browseFileInto('engineExecutable',document.querySelector('label[for="engineExecutable"]').textContent,$('engineExecutable').value||$('engineRoot').value);
$('engineBrowseRuntime').onclick=()=>browseFileInto('engineRuntimeExecutable',document.querySelector('label[for="engineRuntimeExecutable"]').textContent,$('engineRuntimeExecutable').value||$('engineRoot').value);
$('engineBrowseModel').onclick=()=>{const binding=(ENGINE_EFFECTIVE?.model_bindings||[]).find(m=>String(ENGINE_SETTINGS[m.key])===String(m.equals)),directory=binding?.kind==='directory';(directory?browseFolderInto:browseFileInto)('engineModelPath',directory?'Prepared model directory':'Prepared model file',$('engineModelPath').value||CFG?.model_root||'')};

function engineDefaultPresent(field,definition,build){if(field.binding!=='config')return false;let value=engineGetPath(definition.new_config,field.path);if(typeof value==='string'&&/^\$\{[a-z_]+\}$/.test(value)){const key=value.slice(2,-1);value=key==='executable'?build?.executable:key==='root'?build?.root:build?.[key]}return value!==undefined&&value!==null&&value!==''}

async function engineMergeDefaults(){try{
 const j=await post('/api/engine-definition-defaults',{id:ENGINE_DEFINITION_EDIT.id},{busy:false});let raw=JSON.parse($('engineDefinitionJSON').value);
 const isOriginal=(j.definition.previous_default_digests||[]).includes(ENGINE_DEFINITION_EDIT.digest)&&JSON.stringify(raw)===JSON.stringify(engineDefinitionRaw(ENGINE_DEFINITION_EDIT));
 if(isOriginal){raw=engineDefinitionRaw(j.definition);$('engineDefinitionJSON').value=JSON.stringify(raw,null,2);$('engineDefinitionPath').textContent='Updated default definition previewed, including all model controls and combined model paths. Review and Save to apply. Your existing file stays unchanged until Save.';return;}
 const known=new Set((raw.fields||[]).map(f=>f.key));raw.fields||=[];let count=0;for(const f of j.definition.fields||[]){if(!known.has(f.key)){raw.fields.push(f);count++}}
 for(const key of ['new_config','model_bindings','requirements','discovery','runtime_executable_path','runtime_libraries'])if(raw[key]===undefined&&j.definition[key]!==undefined)raw[key]=j.definition[key];if(raw.schema_version==='1.0'&&j.definition.schema_version==='1.1')raw.schema_version='1.1';
 raw.compatible_definition_digests=[...new Set([...(raw.compatible_definition_digests||[]),...(j.definition.compatible_definition_digests||[])])];
 $('engineDefinitionJSON').value=JSON.stringify(raw,null,2);$('engineDefinitionPath').textContent=`${count} missing default controls added to this preview. Existing custom fields and model bindings are retained. Review their discovery requirements and model-path rules in your custom definition before Save.`;
 }catch(e){toast(e.message,true)}}
function engineDefinitionRaw(value){const raw={...value};for(const key of ['digest','definition_file','default_controls_available','bundled_definition_version'])delete raw[key];return raw;}

$('engineDefinitionMergeDefaults').onclick=engineMergeDefaults;
$('engineUpdateDefaultControls').onclick=async()=>{engineReadFields();const build=engineBuild($('engineModelBuild').value);await engineOpenBuilds(build.id);$('engineEditDefinition').click();await engineMergeDefaults()};
