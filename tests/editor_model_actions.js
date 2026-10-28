// Exercise real editor controls and lifecycle handlers with synthetic Router
// replies. No native Windows process, GPU allocation or pixel layout is tested.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {JSDOM}=require('jsdom'),ui=require('./support/ui.cjs');
const dom=new JSDOM(ui.html(),{runScripts:'outside-only',url:'http://visllama.test/'}),w=dom.window,$=id=>w.document.getElementById(id);
const context=dom.getInternalVMContext(),run=code=>vm.runInContext(code,context);
for(const file of ['state','core','arguments','editor','router'])run(fs.readFileSync(path.join(ui.root,'public/assets/js',file+'.js'),'utf8'));
let failApply=false;
let events=[],messages=[],liveState='unloaded',pollFails=false,failSave=false,failPreflight=false,holdState=null,closed=0;
w.toast=message=>messages.push(message);w.confirm=()=>true;
// This lifecycle fixture omits navigation.js; full modal/focus behavior is
// exercised by validation_modal.js with the complete page script set.
w.openModal=id=>{assert.equal(id,'validationModal');$(id).classList.remove('hidden');messages.push($('validationDescription').textContent)};
w.closeModal=id=>$(id).classList.add('hidden');
w.renderRouterPresets=()=>{};w.renderModelLibrary=()=>{};w.updateDashboard=()=>{};w.updateCommand=()=>{};
w.showView=()=>{};w.closeEditor=()=>closed++;
const preset={alias:'sample',build:'Build A',enabled:true,options:[]};
w.post=async(url,body)=>{
 events.push({url,body});
 if(url==='/api/model-preflight'){if(failPreflight)throw new Error('Replacement is invalid');return {ok:true,preflight_id:'fixture'}}
 if(url==='/api/router-models'){
  if(holdState)return new Promise(resolve=>{holdState=resolve});
  if(pollFails)throw new Error('Status temporarily unavailable');
  return {result:{data:[{id:'sample',status:{value:liveState}}]}};
 }
 if(url==='/api/router-preset-save'){
  if(failSave)throw new Error('Save failed');
  return {presets:[{...preset,alias:body.alias}]};
 }
 if(url==='/api/router-load'){liveState='loaded';return {ok:true}}
 if(url==='/api/router-unload'){liveState='unloaded';return {ok:true}}
 throw new Error('Unexpected request: '+url);
};
w.waitForRouterModel=async(alias,state)=>{events.push({url:'wait-'+state});return {id:alias,status:{value:state}}};
w.applyRouterConfig=async(force)=>{events.push({url:'apply',force});if(failApply)throw new Error('Restart Router to activate the new GPU visibility group')};
function reset(state='unloaded'){
 failApply=false;events=[];messages=[];liveState=state;pollFails=false;failSave=false;failPreflight=false;holdState=null;closed=0;
 $('singlePane').classList.add('editor-open');$('alias').value='sample';$('gpuPriority').value='manual';
 $('build').innerHTML='<option>Build A</option><option>Build B</option>';$('serverMode').value='router';
 $('model').innerHTML='<option value="D:/model.gguf">model.gguf</option>';
 run(`EDITOR_ALIAS='sample';EDITOR_ORIGINAL_BUILD='Build A';EDITOR_SAVE_BUSY=false;
 ROUTER_PRESETS=[${JSON.stringify(preset)}];MODEL_ACTION_PENDING.clear();
 LAST_STATUS={running:true,mode:'router',router_engines:[{running:true,build:'Build A',models:['sample']}]};
 LIVE_ROUTER_MODELS=[{id:'sample',status:{value:${JSON.stringify(state)}}}];
 MODEL_STATUS_FETCHED=true;MODEL_STATUS_ERROR=false;SERVER_ACTION_BUSY=false;`);
 w.syncEditorActions();
}
const mutations=()=>events.map(e=>e.url).filter(url=>url!=='/api/router-models');
async function main(){try{
 reset('loaded');
 assert.equal($('editorModelState').textContent,'Loaded');
 assert.equal($('editorSaveReload').textContent,'Save and reload');assert.equal($('editorSaveReload').disabled,false);
 const snapshot=JSON.stringify(w.presetData()),argv=JSON.stringify(w.args());
 liveState='unloaded';await w.refreshRouterModels(true);
 assert.equal($('editorModelState').textContent,'Unloaded');assert.equal($('editorSaveReload').textContent,'Save and load');
 assert.equal($('editorSaveReload').disabled,false);
 assert.equal(JSON.stringify(w.presetData()),snapshot,'Status rendering never changes saved settings');
 assert.equal(JSON.stringify(w.args()),argv,'Status rendering never changes model arguments');
 liveState='loading';await w.refreshRouterModels(true);
 assert.equal($('editorModelState').textContent,'Loading');assert.equal($('editorSaveReload').disabled,true);
 assert.equal($('editorSave').disabled,false,'Ordinary Save remains separate from load availability');
 assert.match($('editorSaveNote').textContent,/finishes loading/);
 assert.equal(await w.saveEditorPreset(true),false);assert.deepEqual(mutations(),[]);
 liveState='loaded';await w.refreshRouterModels(true);assert.equal($('editorSaveReload').disabled,false);
 run("MODEL_ACTION_PENDING.set('sample','unload')");w.syncServerButtons();
 assert.equal($('editorModelState').textContent,'Unloading');assert.equal($('editorSaveReload').disabled,true);
 run('MODEL_ACTION_PENDING.clear()');pollFails=true;await w.refreshRouterModels(true);
 assert.equal($('editorModelState').textContent,'Status unavailable');assert.equal($('editorSaveReload').disabled,true);
 pollFails=false;await w.refreshRouterModels(true);assert.equal($('editorSaveReload').disabled,false);
 run('MODEL_STATUS_FETCHED=false');w.syncEditorActions();assert.equal($('editorModelState').textContent,'Checking');
 assert.equal($('editorSaveReload').disabled,true);
 reset();run('LAST_STATUS.running=false');w.syncServerButtons();
 assert.equal($('editorModelState').textContent,'Unloaded');assert.equal($('editorSaveReload').disabled,true);
 assert.match($('editorSaveNote').textContent,/Start the Router/);assert.equal($('editorSave').disabled,false);
 reset();$('build').value='Build B';w.syncEditorActions();assert.equal($('editorSaveReload').disabled,true);
 assert.match($('editorSaveNote').textContent,/restart the Router/);
 reset();run('ROUTER_PRESETS[0].enabled=false');w.syncEditorActions();assert.equal($('editorSaveReload').disabled,true);
 reset('loaded');$('alias').value='renamed';w.syncEditorActions();
 assert.equal($('editorSaveReload').textContent,'Save and reload','Renaming still tracks the original running model');
 run('EDITOR_ALIAS=null;EDITOR_ORIGINAL_BUILD=null');$('alias').value='sample-copy';w.syncEditorActions();
 assert.equal($('editorModelState').textContent,'Unloaded','A clone does not borrow its source load state');
 assert.equal($('editorSaveReload').textContent,'Save and load');assert.equal($('editorSaveReload').disabled,false);
 reset('sleeping');assert.equal($('editorModelState').textContent,'Sleeping');assert.equal($('editorSaveReload').textContent,'Save and reload');
 reset('failed');assert.equal($('editorSaveReload').textContent,'Save and load');assert.equal($('editorSaveReload').disabled,false);

 // The same save path loads an unloaded preset, but unloads a resident one first.
 reset();assert.equal(await w.saveEditorPreset(true),true);
 assert.deepEqual(mutations(),['/api/model-preflight','/api/router-preset-save','apply','/api/router-load','wait-loaded']);
 assert.equal(run('MODEL_ACTION_PENDING.size'),0);assert.equal(run('EDITOR_SAVE_BUSY'),false);
 reset('loaded');assert.equal(await w.saveEditorPreset(true),true);
 assert.deepEqual(mutations(),['/api/model-preflight','/api/router-preset-save','/api/router-unload','wait-unloaded','apply','/api/router-load','wait-loaded']);
 reset();run('LAST_STATUS.running=false');assert.equal(await w.saveEditorPreset(false),true);
 assert.deepEqual(mutations(),['/api/router-preset-save'],'Ordinary Save works with Router stopped');

 // Plain Save updates the catalog without unloading any resident child.
 for(const state of ['unloaded','loaded']){
  reset(state);assert.equal(await w.saveEditorPreset(false),true);
  assert.deepEqual(mutations(),['/api/router-preset-save','apply']);
  assert.equal(events.find(e=>e.url==='apply').force,false,'Save cannot force unload moved models');
  assert(messages.some(m=>m.includes('Loaded models keep their current settings')));
 }
 reset();failApply=true;assert.equal(await w.saveEditorPreset(false),true,'Durable save remains successful after apply failure');
 assert(messages.some(m=>m.includes('Preset saved, but Router catalog was not updated:')&&m.includes('Restart Router')));
 assert.deepEqual(mutations(),['/api/router-preset-save','apply'],'Apply failure cannot unload or load');

 // A load may start after the button was rendered. The fresh reply must stop
 // both the save and unload, even for calculated placement requiring unload.
 for(const distribution of ['manual','priority_split']){
  reset('loaded');$('gpuPriority').value=distribution;
  if(distribution==='priority_split')$('device').innerHTML='<input type="checkbox" value="CUDA0" checked>';
  liveState='loading';assert.equal(await w.saveEditorPreset(true),false);
  assert.deepEqual(mutations(),[]);assert.equal(closed,0);
  assert.equal(run('EDITOR_SAVE_BUSY'),false);assert.equal(run('MODEL_ACTION_PENDING.size'),0);
 }
 reset('loaded');holdState=true;
 const first=w.saveEditorPreset(true);
 assert.equal($('editorSave').disabled,true);assert.equal($('editorSaveReload').disabled,true);
 assert.equal(await w.saveEditorPreset(true),false,'Repeated activation cannot send a duplicate operation');
 const resolve=holdState;holdState=null;resolve({result:{data:[{id:'sample',status:{value:'loaded'}}]}});await first;
 assert.equal(events.filter(e=>e.url==='/api/router-preset-save').length,1);
 reset();failSave=true;assert.equal(await w.saveEditorPreset(true),false);
 assert.equal(run('EDITOR_SAVE_BUSY'),false);assert.equal(run('MODEL_ACTION_PENDING.size'),0);
 assert.equal($('editorSave').disabled,false);assert.equal(closed,0);
 assert.equal(mutations().includes('/api/router-load'),false,'A failed save must not load new settings');
 for(const distribution of ['manual','priority_split']){
  reset('loaded');$('gpuPriority').value=distribution;
  if(distribution==='priority_split')$('device').innerHTML='<input type="checkbox" value="CUDA0" checked>';
  failPreflight=true;assert.equal(await w.saveEditorPreset(true),false);
  assert.deepEqual(mutations(),['/api/model-preflight'],'Rejected replacement cannot save or unload');
  assert.equal(closed,0);
 }
 console.log('Editor model actions passed: shared polling, contextual labels, guarded transitions, save/load/reload and recovery');
}finally{w.close()}}
main().catch(e=>{console.error(e);process.exitCode=1});
