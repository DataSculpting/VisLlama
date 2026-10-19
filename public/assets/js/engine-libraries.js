// GPL-3.0-only. Folder lists keep existing saved arrays; no hand-written JSON.
let ENGINE_LIBRARY_SERIAL=0;
function engineLibraryField(){return (ENGINE_EFFECTIVE?.fields||[]).find(f=>f.binding==='config'&&f.type==='json-array'&&JSON.stringify(f.path)===JSON.stringify(ENGINE_EFFECTIVE?.runtime_libraries?.config_path))}
function engineLibraryModelContext(){return {settings:engineReadFields(),native_config:JSON.parse($('engineNativeConfig').value||'{}'),config_mode:$('engineConfigMode').value}}
function engineFolderList(container,input,folders,changed,detect){
 const serial=++ENGINE_LIBRARY_SERIAL;
 function render(){
  container.innerHTML=folders.map((f,i)=>`<div class="engine-library-row"><label class="sr-only" for="engineLibrary-${serial}-${i}">Library folder ${i+1}</label><input id="engineLibrary-${serial}-${i}" data-engine-library-row value="${esc(f.path)}"><small>${esc(f.source||'User-selected')}${f.exists===false?' — Folder missing or inaccessible':''}</small><button type="button" data-library-browse="${i}">Browse</button><button type="button" data-library-remove="${i}">Remove</button></div>`).join('')+'<div class="engine-field-actions"><button type="button" data-library-add>Add folder</button><button type="button" data-library-detect>Check / detect folders</button></div><small class="engine-library-status" role="status"></small>';
  const save=()=>{input.value=JSON.stringify(folders.filter(f=>f.path.trim()).map(f=>f.path.trim()));changed?.()};
  folders.forEach((f,i)=>{const row=$(`engineLibrary-${serial}-${i}`);row.onchange=()=>{f.path=row.value;f.source='User-selected';delete f.exists;save();render()}});
  container.querySelectorAll('[data-library-remove]').forEach(b=>b.onclick=()=>{folders.splice(Number(b.dataset.libraryRemove),1);save();render()});
  container.querySelectorAll('[data-library-browse]').forEach(b=>b.onclick=()=>browseFolderInto(`engineLibrary-${serial}-${b.dataset.libraryBrowse}`,'Native library folder',folders[Number(b.dataset.libraryBrowse)].path||$('engineRoot').value));
  container.querySelector('[data-library-add]').onclick=()=>{folders.push({path:'',source:'User-selected'});render();$(`engineLibrary-${serial}-${folders.length-1}`).focus()};
  container.querySelector('[data-library-detect]').onclick=async()=>{const snapshot=input.value,status=container.querySelector('.engine-library-status');try{
   const result=await detect();if(!container.isConnected||input.value!==snapshot||!status.isConnected)return;
   folders=result.folders;input.value=JSON.stringify(result.directories);changed?.();render();container.querySelector('.engine-library-status').textContent=result.missing.length?'Some folders are missing or inaccessible. Correct or remove them before discovery.':folders.length?'Folders checked. This does not prove DLL compatibility. Save to retain changes.':'No folders found using this definition’s detection rules. Add the folders from your working configuration.';
  }catch(e){if(status.isConnected)status.textContent=e.message}};
 }
 render();
}
function engineBuildLibraries(){const input=$('engineRuntimeLibraries'),container=$('engineBuildLibraryList');if(!container)return;engineFolderList(container,input,JSON.parse(input.value||'[]').map(path=>({path,source:'User-selected'})),null,async()=>{
 const engine=$('engineType').value,root=$('engineRoot').value.trim(),executable=$('engineExecutable').value.trim();if(!root||!executable)throw Error('Choose the installation folder and interpreter first.');
 const j=await post('/api/engine-library-folders',{engine,root,executable,runtime_library_dirs:JSON.parse(input.value||'[]')},{busy:false});return j.libraries;
})}
function engineModelLibraries(){const f=engineLibraryField();if(!f)return;const input=$('engineField-'+f.key);if(!input)return;let container=document.createElement('div');container.id='engineModelLibraryList';input.after(container);
 input.closest('.field').querySelector('label[for="'+input.id+'"]').textContent='Native library folders';
 const value=input.value?JSON.parse(input.value):Object.hasOwn(ENGINE_SETTINGS,f.key)?[]:(engineBuild($('engineModelBuild').value)?.runtime_library_dirs||[]),source=Object.hasOwn(ENGINE_SETTINGS,f.key)?'User-selected':Object.hasOwn(ENGINE_INHERITED,f.key)?'Imported':'Build defaults';
 const changed=()=>{ENGINE_SETTINGS[f.key]=JSON.parse(input.value);input.dataset.inherited='false'};
 engineFolderList(container,input,value.map(path=>({path,source})),changed,async()=>{
  // Resolve edited model values; if absent, declarative environment detection runs.
  const context=engineLibraryModelContext(),id=$('engineModelBuild').value;
  const j=await post('/api/engine-library-folders',{id,model_context:context},{busy:false});return j.libraries;
 });
}
function engineShowDiscoveryFolders(folders){
 const f=engineLibraryField();if(!f)return;
 if(folders.some(f=>f.source==='Detected')){ENGINE_SETTINGS[f.key]=folders.map(f=>f.path);engineRenderFields();$('engineModelErrors').textContent='Detected library folders were added to this model draft. Save to retain them.';}
 const container=$('engineModelLibraryList');if(container)container.querySelector('.engine-library-status').textContent='Discovery used: '+(folders.map(f=>`${f.path} (${f.source})`).join('; ')||'no extra library folders')+'. Build defaults were not changed.';
}
