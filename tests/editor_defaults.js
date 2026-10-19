// Reproduce browser-restored controls and edits before Add model. Template
// defaults must remain authoritative without changing explicit saved presets.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {JSDOM}=require('jsdom'),ui=require('./support/ui.cjs');
const baseline=require('./support/editor-values-0.1.23.json');
const dom=new JSDOM(ui.html(),{runScripts:'outside-only',url:'http://visllama.test/'}),w=dom.window,$=id=>w.document.getElementById(id);
const context=dom.getInternalVMContext(),run=code=>vm.runInContext(code,context),plain=x=>JSON.parse(JSON.stringify(x));
for(const file of ['state','core','models','arguments','editor','engines','engine-libraries','engine-import','model-editor'])run(fs.readFileSync(path.join(ui.root,'public/assets/js',file+'.js'),'utf8'));
const probes=[],notices=[];
w.toast=msg=>notices.push(msg);w.updateCommand=()=>{};w.syncMode=()=>{};w.syncBuildStatus=()=>{};
w.editorHelpState=()=>{};w.filterBuildOptions=()=>{};
w.openEditor=title=>{$('editorTitle').textContent=title};
let failHelp=false,delayed=false,replies=[];
w.post=async(url,body)=>{
 probes.push({url,body});
 if(delayed)return new Promise(resolve=>replies.push({url,resolve}));
 if(url==='/api/help'){
  if(failHelp)throw new Error('Help unavailable');
  return {options:[{flag:'--test-option',signature:'--test-option N',description:'Test option',takes_value:true}],raw:'Fixture build help'};
 }
 if(url==='/api/devices')return {devices:[{id:'CUDA0',description:'Test GPU'}],raw:''};
 throw new Error('Unexpected request '+url);
};
function dirty(){
 $('gpuLayers').value='192.168.6.39';$('tensorSplit').value='Qwen3.8-27B-Q8_0-MTP-PP-256Kx1';$('mainGpu').value='262144';
 $('ctx').value='262144';$('parallel').value='4';$('temperature').value='0.4';$('gpuReserve').value='8192';
 $('flash').checked=!$('flash').defaultChecked;$('gpuPriority').value='priority_split';
 $('specType').value='draft-mtp';$('extra').value='--old-extra\n9';
 $('device').innerHTML='<input type="checkbox" value="CUDA0" checked>';
 $('options').innerHTML='<div class="opt" data-flag="--old-option"><input class="opt-on" type="checkbox" checked><input class="opt-val" value="stale"></div>';
}
async function main(){try{
 // Before startup even runs, restored live values can differ from markup.
 dirty();
 assert.equal(w.presetData().gpuLayers,'192.168.6.39','The former live snapshot would preserve the reported contamination');
 assert.deepEqual(plain(w.presetData(true)),baseline.defaults,'Declared defaults ignore restored values, checks, selected options and device rows');
 for(const id of Object.keys(baseline.defaults).filter(id=>id!=='devices')){
  assert.equal($(id).getAttribute('autocomplete'),'off',id+' opts out of browser autofill');
  assert.equal($(id).name,'visllama-model-'+id,id+' has a stable semantic name');
 }
 run(`CFG={model_root:'D:/models',builds:[{name:'Unavailable',available:false},{name:'Current',available:true}]};
 MODELS=[{supplier:'Local',variant:'Model A',file:'a.gguf',path:'D:/models/a.gguf',size:1},{supplier:'Other',variant:'Model B',file:'b.gguf',path:'D:/models/b.gguf',size:2}];`);
 $('build').innerHTML='<option>Unavailable</option><option>Current</option>';
 $('routerHost').value='192.168.6.39';$('routerPort').value='18080';$('routerMax').value='2';
 w.localStorage.setItem('llamaCppControlPreset',JSON.stringify({gpuLayers:'123',tensorSplit:'old'}));
 const savedBrowser=w.localStorage.getItem('llamaCppControlPreset');
 await w.newModelInDrawer();
 assert.equal($('editorTitle').textContent,'Add model');assert.equal($('alias').value,'Model-A');
 for(const id of ['gpuLayers','tensorSplit','mainGpu','ctx','parallel','temperature','extra'])assert.equal($(id).value,'',id+' starts blank');
 assert.equal($('gpuReserve').value,'2048');assert.equal($('flash').checked,$('flash').defaultChecked);
 assert.equal($('gpuPriority').value,'manual');assert.equal($('specType').value,'none');
 assert.equal($('build').value,'Current');assert.equal($('model').value,'D:/models/a.gguf');
 assert.deepEqual(plain(w.selectedDevices()),[]);assert.deepEqual(plain(w.allArgs()),[]);
 assert.equal(w.localStorage.getItem('llamaCppControlPreset'),savedBrowser,'An explicit browser preset is neither loaded nor rewritten');
 assert.equal($('routerHost').value,'192.168.6.39');assert.equal($('routerPort').value,'18080');assert.equal($('routerMax').value,'2');
 assert(probes.every(x=>['/api/help','/api/devices'].includes(x.url)),'Opening Add model performs no settings writes');
 assert(probes.every(x=>x.body.build==='Current'),'Probes use the newly selected build');

 // Edits and even a failed build-help probe cannot leak custom option checks
 // into another new model; the previous native option list is removed first.
 dirty();failHelp=true;await w.newModelInDrawer();
 assert.equal($('gpuLayers').value,'');assert.equal($('mainGpu').value,'');
 assert.deepEqual(plain(w.allArgs()),[]);assert.equal($('options').children.length,0);
 assert.deepEqual(plain(w.selectedDevices()),[]);assert(notices.includes('Help unavailable'));
 failHelp=false;

 // A sparse older saved preset gets clean defaults only for absent fields.
 dirty();const sparse={alias:'Saved',build:'Current',supplier:'Other',variant:'Model B',model:'D:/models/b.gguf',ctx:'8192',parallel:'2',flash:false,devices:['CUDA0'],fit:false};
 const unchanged=JSON.stringify(sparse);await w.applyUiPreset(sparse);
 assert.equal(JSON.stringify(sparse),unchanged,'Restoration does not mutate the saved snapshot');
 assert.equal($('ctx').value,'8192');assert.equal($('parallel').value,'2');assert.equal($('flash').checked,false);
 assert.equal($('model').value,'D:/models/b.gguf');assert.deepEqual(plain(w.selectedDevices()),['CUDA0']);
 assert.equal($('gpuLayers').value,'');assert.equal($('tensorSplit').value,'');assert.equal($('mainGpu').value,'');
 assert.equal($('extra').value,'');assert.equal($('fit').value,'');

 // Clone remains an explicit copy, including non-default saved values.
 run(`ROUTER_PRESETS=[{alias:'Saved',build:'Current',model:'D:/models/b.gguf',ui:${JSON.stringify({...sparse,gpuLayers:'all',tensorSplit:'1',mainGpu:'0'})}}]`);
 await w.editPresetInDrawer('Saved',true);
 assert.equal($('alias').value,'Saved-copy');assert.equal($('gpuLayers').value,'all');
 assert.equal($('tensorSplit').value,'1');assert.equal($('mainGpu').value,'0');
 assert.equal($('ctx').value,'8192');assert.equal(run('EDITOR_ALIAS'),null);
 await w.newModelInDrawer();assert.equal($('gpuLayers').value,'');assert.equal($('ctx').value,'');

 // Building the new form clears old controls before slow discovery returns.
 dirty();delayed=true;const opening=w.newModelInDrawer();
 assert.equal($('gpuLayers').value,'');assert.equal($('tensorSplit').value,'');assert.equal($('mainGpu').value,'');
 for(const reply of replies)reply.resolve(reply.url==='/api/help'?{options:[],raw:''}:{devices:[],raw:''});
 await opening;
 console.log('Editor defaults passed: restored startup fields, repeated Add, sparse presets, Clone, delayed/failed probes and Router-setting isolation');
}finally{w.close()}}
main().catch(e=>{console.error(e);process.exitCode=1});
