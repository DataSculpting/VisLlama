// Presentation only. All controls stay mounted with their original IDs and values.
// presetData(), friendlyArgs() and the Perl save path remain the source of truth.
let EDITOR_HELP_STATUS='unknown', EDITOR_HELP_BUILD='', EDITOR_SEARCH_OPEN=null;
const EDITOR_FIELD_FLAGS=new Map();

// Read labels before help icons are attached. Explicit aliases cover controls
// whose labels describe a behavior rather than spelling out a command flag.
function initEditorPresentation(){
 const overrides={contextShift:['--context-shift','--no-context-shift'],reasoningPreserve:['--reasoning-preserve','--no-reasoning-preserve'],temperature:['--temperature','--temp'],typicalP:['--typical-p','--typical'],topNSigma:['--top-nsigma','--top-n-sigma']};
 for(const row of document.querySelectorAll('#friendly .editor-setting')){
  const control=row.querySelector('input[id],select[id],textarea[id]');
  const label=row.querySelector('label')||row;
  const flags=overrides[control?.id]||[...new Set(label.textContent.match(/--[a-z][a-z0-9-]*/g)||[])];
  EDITOR_FIELD_FLAGS.set(row,flags);
  // Keep the familiar name prominent; command syntax remains visible below it
  // and is indexed by search. Do not replace checkbox labels or their inputs.
  if(label.tagName==='LABEL'&&!label.classList.contains('check')&&flags.length){
   const text=label.textContent.replace(/\s*\(--.*?\)/g,'').trim();
   label.textContent=text;
   const syntax=document.createElement('span');syntax.className='editor-flag';syntax.textContent=flags.join(' / ');label.append(syntax);
  }
  if(control){const tip=typeof HELP_TEXT!=='undefined'?HELP_TEXT[control.id]:'';row.dataset.editorSearch=(label.textContent+' '+flags.join(' ')+' '+(tip||'')).toLowerCase()}
 }
 $('editorSearch').addEventListener('input',filterEditorSettings);
 $('editorClearSearch').onclick=()=>{$('editorSearch').value='';filterEditorSettings();$('editorSearch').focus()};
 for(const [id,open] of [['editorExpand',true],['editorCollapse',false]])$(id).onclick=()=>{
  $('editorSearch').value='';filterEditorSettings();
  document.querySelectorAll('#friendly details').forEach(d=>{d.open=open});
 };
 $('editorReviewBuild').onclick=()=>{const panel=$('editor-build-options');panel.open=true;panel.scrollIntoView?.({block:'start',behavior:'auto'});$('optSearch').focus({preventScroll:true})};
 // If validation blocks saving, expose its GPU/fit controls even when collapsed.
 // The original save handler remains responsible for validation and error text.
 $('singlePane').addEventListener('click',event=>{
  if(!['editorSave','editorSaveReload','saveRouterPreset'].includes(event.target.closest('button')?.id))return;
  if(typeof modelEditorExternal==='function'&&modelEditorExternal())return;
  if(validateConfig()){
   $('editorSearch').value='';filterEditorSettings();$('editor-gpu').open=true;
   $('editor-gpu').querySelectorAll('.editor-advanced').forEach(detail=>{detail.open=true});
  }
 },true);
 $('singlePane').addEventListener('input',refreshEditorPresentation);
 $('singlePane').addEventListener('change',()=>{refreshEditorPresentation();if($('editorSearch').value)filterEditorSettings()});
 // Reordering devices mutates its rows without changing the form values.
 new MutationObserver(refreshEditorSummaries).observe($('device'),{childList:true,subtree:true});
 refreshEditorPresentation();
}

// Section summaries reflect actual form values, never placeholder examples.
function refreshEditorSummaries(){
 const val=id=>$(id).value.trim(), text=id=>$(id).selectedOptions?.[0]?.textContent||'Default';
 const summaries={
  context:(val('ctx')?Number(val('ctx')).toLocaleString()+' context tokens':'Model context default')+' · KV cache '+(val('cacheK')||'default')+' / '+(val('cacheV')||'default'),
  gpu:text('gpuPriority')+' · '+(selectedDevices().join(', ')||'Build device selection'),
  performance:(val('parallel')?val('parallel')+' parallel slots':'Build concurrency default')+' · '+(val('threads')?val('threads')+' CPU threads':'Automatic CPU threads'),
  response:(val('predict')?val('predict')+' max generated tokens':'Default response length')+' · Reasoning '+text('reasoning'),
  sampling:'Temperature '+(val('temperature')||'default')+' · Top P '+(val('topP')||'default'),
  acceleration:text('specType')+' · '+text('ngramType'),
  extra:val('extra')?'Custom arguments entered':'No custom arguments'
 };
 for(const [key,value] of Object.entries(summaries))document.querySelector('[data-editor-summary="'+key+'"]').textContent=value;
 // Counts refer to explicitly entered fields, not inferred engine defaults.
 // They keep advanced values discoverable while the detailed controls are shut.
 for(const detail of document.querySelectorAll('#friendly .editor-advanced')){
  const count=[...detail.querySelectorAll('input,select,textarea')].filter(e=>e.type==='checkbox'?e.checked:e.value.trim()!=='').length;
  let badge=detail.querySelector(':scope > summary > .editor-value-count');
  if(!badge){badge=document.createElement('span');badge.className='editor-value-count';detail.querySelector('summary').append(badge)}
  badge.textContent=count?' · '+count+' set':'';
 }
}

// --help is evidence of advertised flags, not proof of every supported value,
// template, backend or GPU capability. Missing flags warn without erasing values.
function editorHelpState(status,build){EDITOR_HELP_STATUS=status;EDITOR_HELP_BUILD=build;refreshEditorPresentation()}
function refreshEditorPresentation(){
 refreshEditorSummaries();
 const ready=EDITOR_HELP_STATUS==='ready'&&EDITOR_HELP_BUILD===$('build').value;
 const advertised=new Set(ready?HELP.flatMap(o=>[o.flag,...(o.aliases||[]),...(o.signature.match(/--[a-z][a-z0-9-]*/g)||[])]):[]);
 let missing=0;
 for(const [row,flags] of EDITOR_FIELD_FLAGS){
  const absent=ready&&flags.length&&!flags.some(f=>advertised.has(f));
  row.classList.toggle('editor-unadvertised',!!absent);
  let note=row.querySelector('.editor-capability');
  if(absent){missing++;if(!note){note=document.createElement('small');note.className='editor-capability';row.append(note)}note.textContent='Not advertised by this build. Check its help before using this setting.'}
  else note?.remove();
 }
 // Prevent editing stale build-specific choices while a new probe is pending.
 $('options').inert=!ready;
 $('options').classList.toggle('editor-help-pending',!ready);
 const status=$('editorCapabilityStatus');
 status.textContent=ready?$('build').value+' · '+HELP.length+' advertised options. '+(missing?'Marked settings were not found in this build’s help. ':'')+'Model and hardware support can vary.':EDITOR_HELP_STATUS==='loading'?'Reading settings from the selected build…':'Build help is unavailable or not yet checked. Values are preserved; reload the build help to check availability.';
 status.dataset.state=ready?'ready':EDITOR_HELP_STATUS;
}

// Filter existing nodes rather than rebuilding inputs: hidden values continue
// to serialize, and clearing search restores the user's previous open sections.
function filterEditorSettings(){
 const query=$('editorSearch').value.trim().toLowerCase();
 const details=[...document.querySelectorAll('#friendly details')];
 if(query&&!EDITOR_SEARCH_OPEN)EDITOR_SEARCH_OPEN=new Map(details.map(d=>[d,d.open]));
 let matches=0;
 for(const row of document.querySelectorAll('#friendly .editor-setting')){
  const relevant=!row.closest('.hidden');
  const hit=!query||(relevant&&(row.dataset.editorSearch||row.textContent.toLowerCase()).includes(query));
  row.classList.toggle('editor-search-hidden',!hit);if(query&&hit)matches++;
 }
 for(const detail of details.slice().reverse()){
  const hit=[...detail.querySelectorAll('.editor-setting')].some(row=>!row.classList.contains('editor-search-hidden'));
  detail.classList.toggle('editor-search-hidden',!!query&&!hit);
  if(query&&hit)detail.open=true;
 }
 if(!query&&EDITOR_SEARCH_OPEN){for(const [detail,open] of EDITOR_SEARCH_OPEN)detail.open=open;EDITOR_SEARCH_OPEN=null}
 $('editorClearSearch').disabled=!query;
 $('editorSearchStatus').textContent=query?(matches?matches+' matching settings. Inactive N-gram options appear after selecting their method.':'No matching settings. Try a broader term, or review additional build options below.'):'Open a section to adjust its settings. Advanced groups show how many fields are set.';
}

// A fresh edit starts with a quiet overview. This resets layout only; it never
// writes to controls, localStorage, the model snapshot or Router service values.
function resetEditorPresentation(){
 $('editorSearch').value='';filterEditorSettings();
 document.querySelectorAll('#friendly details').forEach(d=>{d.open=false});
 $('editor-build-options').open=false;$('editor-preview').open=false;
 refreshEditorPresentation();
}

// Additional build-option search used to rebuild the list, discarding checked
// flags. Filtering in place keeps the exact arguments selected by the user.
function filterBuildOptions(){
 const query=$('optSearch').value.trim().toLowerCase();let shown=0;
 for(const row of $('options').querySelectorAll('.opt')){const hit=row.textContent.toLowerCase().includes(query);row.classList.toggle('editor-search-hidden',!hit);if(hit)shown++}
 $('editorOptionStatus').textContent=shown+' additional options shown.';
}
initEditorPresentation();
