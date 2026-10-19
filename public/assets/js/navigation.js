// VisLlama: navigation. Loaded in the order declared in templates/partials/scripts.html.

// Move between views and reuse the same mounted editor/settings nodes.
// Focus restoration and modal isolation are essential for keyboard navigation.


// Switch the operations-first application view without reloading the page.
function showView(name){if(APP_VIEW==='settings'&&name!=='settings'&&routerSettingsDirty()){syncRouterSettingsDirty();toast('Save Router settings before leaving Settings.',true);$('saveRouterSettings').focus();return false}APP_VIEW=name;syncInstrumentView(name);document.querySelectorAll('.view').forEach(v=>v.classList.toggle('active',v.id===name+'View'));document.querySelectorAll('.nav-button').forEach(b=>b.classList.toggle('active',b.dataset.view===name));if(name==='router'){refreshRouterModels(true);setTimeout(()=>window.scrollTo(0,ROUTER_SCROLL_Y||0),0)}if(name==='dashboard'&&LAST_STATUS?.running&&LAST_STATUS.mode==='router')refreshRouterModels(true);if(name==='models'){renderModelLibrary();window.scrollTo(0,0)}if(name==='logs')syncLogView();if(name==='settings'){syncSettingsView();syncRouterSettingsDirty()}if(name==='stats')syncStatsView();if(name==='modelStats')refreshModelStats();if(name==='chat')globalThis.VisLlamaChat.open();return true}

// Mount and open the model editor as a first-class application view.
function openEditor(title='Model editor'){EDITOR_RETURN_CONTROL=rememberControl(document.body);PRIORITY_PREVIEW_KEY='';ROUTER_SCROLL_Y=window.scrollY;EDITOR_RETURN_VIEW=APP_VIEW&&APP_VIEW!=='editor'?APP_VIEW:'router';const p=$('singlePane');const mount=$('editorMount');if(mount&&!mount.contains(p))mount.appendChild(p);p.classList.add('editor-open');p.classList.remove('hidden');$('editorTitle').dataset.mode=/^Clone\b/.test(title)?'Clone':/^Add\b/.test(title)?'Add':'Edit';$('editorTitle').textContent=title;syncEditorIdentity();showView('editor');syncMode();updateCommand();resetEditorPresentation();window.scrollTo(0,0)}

// Close the model editor and restore the caller view/Router scroll position.
function closeEditor(){if(typeof modelEditorReset==='function')modelEditorReset();const p=$('singlePane');p.classList.remove('editor-open');p.classList.add('hidden');EDITOR_ALIAS=null;EDITOR_ORIGINAL_BUILD=null;$('serverMode').value='router';syncMode();refreshRouterPresets();refreshRouterModels();const back=EDITOR_RETURN_VIEW||'router';showView(back);requestAnimationFrame(()=>{restoreControl(document.body,EDITOR_RETURN_CONTROL);if(!document.activeElement?.getClientRects().length)$(back+'View')?.querySelector('.page-title')?.focus({preventScroll:true})});if(back==='router')setTimeout(()=>window.scrollTo(0,ROUTER_SCROLL_Y||0),0)}

// Mount the existing log card in its page without duplicating polling targets.
function syncLogView(){if($('logCard')&&$('logsMount')&&!$('logsMount').contains($('logCard')))$('logsMount').appendChild($('logCard'));}

// Mount the existing installation and Router settings cards in the Settings view.
function syncSettingsView(){if($('buildConfigCard')&&$('settingsMount')&&!$('settingsMount').contains($('buildConfigCard')))$('settingsMount').appendChild($('buildConfigCard'));if($('installConfigCard')&&$('settingsMount')&&!$('settingsMount').contains($('installConfigCard')))$('settingsMount').appendChild($('installConfigCard'));if($('routerSettingsCard')&&$('settingsMount')&&!$('settingsMount').contains($('routerSettingsCard')))$('settingsMount').appendChild($('routerSettingsCard'));}

// Mount the shared live status card in the hardware Stats view.
function syncStatsView(){if($('statusCard')&&$('statsMount')&&!$('statsMount').contains($('statusCard')))$('statsMount').appendChild($('statusCard'))}

// Move the existing operational catalog into its Router page mount point.
function mountRouterView(){if($('routerPresetsCard')&&$('routerMount')&&!$('routerMount').contains($('routerPresetsCard')))$('routerMount').appendChild($('routerPresetsCard'));}

// Push a dialog with its return-focus target; only the top dialog is interactive.
function openModal(id){if(MODAL_STACK.some(x=>x.id===id))return;MODAL_STACK.push({id,returnTo:document.activeElement});$(id).classList.remove('hidden');$(id).style.zIndex=900+MODAL_STACK.length;syncModalLayers();requestAnimationFrame(()=>modalFocusables($(id))[0]?.focus())}

// Close this dialog and any children, then restore the calling control.
// Required initial setup cannot be dismissed through this ordinary close path.
function closeModal(id){if(id==='buildManagerModal'&&SETUP_REQUIRED)return;const index=MODAL_STACK.findIndex(x=>x.id===id);if(index<0)return;const entry=MODAL_STACK[index];for(const item of MODAL_STACK.splice(index)){$(item.id).classList.add('hidden');$(item.id).inert=false;if(item.id==='presetOverwriteModal')cancelPresetOverwrite()}syncModalLayers();if(entry.returnTo?.isConnected&&!entry.returnTo.disabled)entry.returnTo.focus({preventScroll:true})}

// Capture a stable ID or row data key, plus input selection, before rerendering.
function rememberControl(root){
 const el=document.activeElement;if(!root?.contains(el))return null;
 return {id:el.id,data:Object.entries(el.dataset||{}),start:el.selectionStart,end:el.selectionEnd};
}

// Restore focus only to a still-present enabled control, including its caret.
function restoreControl(root,saved){
 if(!saved)return;
 const el=saved.id?document.getElementById(saved.id):[...root.querySelectorAll('button,input,select,[tabindex]')].find(e=>saved.data.length&&saved.data.every(([k,v])=>e.dataset[k]===v));
 if(el&&!el.disabled){el.focus({preventScroll:true});if(typeof saved.start==='number'&&el.setSelectionRange)try{el.setSelectionRange(saved.start,saved.end)}catch(_){}}
}

// Synchronize mobile navigation visibility and its accessible expanded state.
function setNavigation(open){
 document.body.classList.toggle('nav-open',open);$('navToggle').setAttribute('aria-expanded',String(open));
 if(open)$('appNav').querySelector('.active')?.focus();
}

// Mark the active page and close mobile navigation before moving page focus.
function syncInstrumentView(name){
 document.querySelectorAll('[data-view]').forEach(b=>{if(b.dataset.view===name)b.setAttribute('aria-current','page');else b.removeAttribute('aria-current')});
 for(const [id,view] of [['headerStats','stats'],['headerSettings','settings']]){if(name===view)$(id).setAttribute('aria-current','page');else $(id).removeAttribute('aria-current')}
 const menuWasOpen=document.body.classList.contains('nav-open');setNavigation(false);
 if(menuWasOpen)requestAnimationFrame(()=>{const title=$(name+'View')?.querySelector('.page-title');if(title){title.tabIndex=-1;title.focus({preventScroll:true})}});
}

// Collect visible enabled controls in the active dialog for keyboard trapping.
function modalFocusables(root){return [...root.querySelectorAll('button:not(:disabled),input:not(:disabled),select:not(:disabled),textarea:not(:disabled),a[href],[tabindex="0"]')].filter(el=>el.getClientRects().length&&!el.closest('[inert]'))}

// Make background views and lower dialogs inert while the top modal is active.
function syncModalLayers(){
 const top=MODAL_STACK.at(-1);
 for(const entry of MODAL_STACK)$(entry.id).inert=BUSY_COUNT>0||entry!==top;
 document.body.classList.toggle('modal-open',!!top);
 for(const el of document.querySelectorAll('body>header,body>.app-shell,body>.hardware-strip,body>.app-footer'))el.inert=BUSY_COUNT>0||!!top;
}

// Initialize shell sizing, label associations and keyboard/focus behavior.
// This runs once before configuration data is mounted into the views.
function initInstrument(){
 const updateHeader=()=>{document.documentElement.style.setProperty('--header-height',document.querySelector('header').offsetHeight+'px');if(innerWidth>800)setNavigation(false)};
 new ResizeObserver(updateHeader).observe(document.querySelector('header'));updateHeader();
 $('navToggle').onclick=()=>setNavigation(!document.body.classList.contains('nav-open'));
 $('navShade').onclick=()=>{setNavigation(false);$('navToggle').focus()};
 $('hardwareStats').onclick=()=>showView('stats');
 $('modelInspector').addEventListener('click',e=>{const b=e.target.closest('[data-inspector-edit]');if(b)editPresetInDrawer(b.dataset.inspectorEdit,false)});
 document.querySelectorAll('.page-title').forEach((el,i)=>{el.dataset.index=String(i+1).padStart(2,'0')+' / VISLLAMA';el.tabIndex=-1});
 for(const field of document.querySelectorAll('.field')){const label=field.querySelector('label'),control=field.querySelector('input[id],select[id],textarea[id]');if(label&&control&&!label.htmlFor)label.htmlFor=control.id}
 $('routerSearch').setAttribute('aria-label','Search Router models');
 document.addEventListener('keydown',e=>{
  if(!$('busyOverlay').classList.contains('hidden')){
   // The busy overlay now owns an explicit cancellation control. Keep focus
   // inside it while allowing native keyboard activation of that control.
   if(e.key==='Tab'){const controls=modalFocusables($('busyOverlay'));e.preventDefault();e.stopImmediatePropagation();if(controls.length){const i=controls.indexOf(document.activeElement);controls[(i+(e.shiftKey?-1:1)+controls.length)%controls.length].focus()}}
   else if(['Enter',' '].includes(e.key)&&document.activeElement!==$('cancelOperation')){e.preventDefault();e.stopImmediatePropagation()}
   return
  }
  const top=MODAL_STACK.at(-1);
  if(top){const root=$(top.id);if(e.key==='Escape'){e.preventDefault();e.stopImmediatePropagation();closeModal(top.id);return}if(e.key==='Tab'){const all=modalFocusables(root),first=all[0],last=all.at(-1);if(!first){e.preventDefault();return}if(e.shiftKey&&(document.activeElement===first||!root.contains(document.activeElement))){e.preventDefault();last.focus()}else if(!e.shiftKey&&(document.activeElement===last||!root.contains(document.activeElement))){e.preventDefault();first.focus()}}return}
  if(document.body.classList.contains('nav-open')){if(e.key==='Escape'){setNavigation(false);$('navToggle').focus();e.preventDefault()}else if(e.key==='Tab'){const all=[$('navToggle'),...modalFocusables($('appNav'))],i=all.indexOf(document.activeElement);e.preventDefault();all[(i+(e.shiftKey?-1:1)+all.length)%all.length].focus()}}
 },true);
}
