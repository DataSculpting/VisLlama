// Real rendered controls and previous-release save outputs, plus simulated help
// responses. No pixel layout, Windows process or GPU behavior is asserted here.
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {JSDOM,VirtualConsole}=require('jsdom');
const ui=require('./support/ui.cjs');
const baseline=require('./support/editor-values-0.1.23.json');
const errors=[],vconsole=new VirtualConsole();vconsole.on('jsdomError',e=>errors.push(e.message));
const dom=new JSDOM(ui.html(),{runScripts:'outside-only',url:'http://visllama.test/',virtualConsole:vconsole});
const w=dom.window,d=w.document,$=id=>d.getElementById(id),plain=x=>JSON.parse(JSON.stringify(x));
for(const file of ['state','core','help','arguments','editor'])vm.runInContext(fs.readFileSync(path.join(ui.root,'public/assets/js',file+'.js'),'utf8'),dom.getInternalVMContext());
const initial=plain(w.presetData());assert.deepEqual(initial,baseline.defaults,'Every original default and serialized field is retained');
for(const [id,expected] of Object.entries(baseline.schema)){
 const el=$(id);assert.equal(d.querySelectorAll('[id="'+id+'"]').length,1,id+' is not duplicated');
 const actual={tag:el.tagName,type:el.type,options:el.options?[...el.options].map(o=>o.value):undefined,min:el.getAttribute('min'),max:el.getAttribute('max'),step:el.getAttribute('step')};
 assert.deepEqual(plain(actual),expected,id+' retains its type, allowed values and range');
}
for(const fixture of baseline.cases){
 for(const [id,val] of Object.entries(fixture.ui)){if(id==='devices')continue;const el=$(id);if(el.type==='checkbox')el.checked=val;else el.value=val}
 $('device').innerHTML=fixture.ui.devices.map(v=>'<input type="checkbox" value="'+v+'" checked>').join('');
 assert.deepEqual(plain(w.presetData()),fixture.ui,'Snapshot equals 0.1.23');
 assert.deepEqual(plain(w.friendlyArgs()),fixture.args,'Arguments equal 0.1.23 across GPU and N-gram modes');
}
$('editorMount').append($('singlePane'));
vm.runInContext(fs.readFileSync(path.join(ui.root,'public/assets/js/editor-presentation.js'),'utf8'),dom.getInternalVMContext());
const set=(id,v)=>{$(id).value=v;$(id).dispatchEvent(new w.Event('input',{bubbles:true}))};
async function main(){try{
 const before=plain(w.presetData()),beforeArgs=plain(w.friendlyArgs());
 w.resetEditorPresentation();assert.equal(d.querySelectorAll('#friendly details[open]').length,0);
 $('editor-gpu').open=true;
 set('editorSearch','--rope-scaling');
 assert.equal($('editor-context').open,true);assert.equal($('ropeScaling').closest('details').open,true);
 assert.equal($('editor-gpu').classList.contains('editor-search-hidden'),true);
 assert.match($('editorSearchStatus').textContent,/matching settings/);
 assert.deepEqual(plain(w.presetData()),before);assert.deepEqual(plain(w.friendlyArgs()),beforeArgs);
 $('editorClearSearch').click();assert.equal($('editor-context').open,false);assert.equal($('editor-gpu').open,true);
 assert.equal($('editorClearSearch').disabled,true);
 set('editorSearch','nothing-matches-this-setting');assert.match($('editorSearchStatus').textContent,/No matching/);
 $('editorExpand').click();assert([...d.querySelectorAll('#friendly details')].every(x=>x.open));
 $('editorCollapse').click();assert([...d.querySelectorAll('#friendly details')].every(x=>!x.open));
 assert.deepEqual(plain(w.presetData()),before,'Search and disclosure never change saved values');
 $('ngramType').value='none';w.syncNgramUi(false);set('editorSearch','--spec-ngram-map-k-size-n');
 assert($('ngramMapKOptions').classList.contains('hidden'),'Search does not activate a different N-gram family');
 $('editorClearSearch').click();
 // Build evidence follows the selected executable, not a globally assumed version.
 $('build').innerHTML='<option>Old</option><option>New</option>';
 let queue=[];w.post=(url,body)=>new Promise((resolve,reject)=>queue.push({url,body,resolve,reject}));
 w.updateCommand=()=>{}; // No live GPU planning is needed to test help presentation.
 const oldRequest=w.loadHelp();$('build').value='New';const newRequest=w.loadHelp();
 const option=(flag)=>({flag,aliases:[flag],signature:flag+' VALUE',description:'Fixture '+flag,takes_value:true});
 queue[1].resolve({options:[option('--ctx-size'),option('--rope-scaling'),option('--custom-option')],raw:'New build help'});await newRequest;
 queue[0].resolve({options:[option('--old-option')],raw:'Old build help'});await oldRequest;
 assert.equal($('rawHelp').textContent,'New build help','Late help cannot replace the newly selected build');
 assert.equal($('ctx').closest('.editor-setting').classList.contains('editor-unadvertised'),false);
 assert.equal($('reasoningEffort').closest('.editor-setting').classList.contains('editor-unadvertised'),true);
 assert.equal($('reasoningEffort').value,before.reasoningEffort,'Unadvertised saved values are retained');
 assert.equal($('reasoningEffort').disabled,false,'Availability guidance does not lock out correcting a value');
 const row=$('options').querySelector('[data-flag="--custom-option"]');assert(row);
 row.querySelector('.opt-on').checked=true;row.querySelector('.opt-val').value='7';
 const extra=plain(w.allArgs());set('optSearch','no matching option');w.filterBuildOptions();
 assert(row.classList.contains('editor-search-hidden'));assert.deepEqual(plain(w.allArgs()),extra,'Filtered checked options still serialize');
 set('optSearch','custom');w.filterBuildOptions();assert.equal($('options').firstElementChild,row,'Search keeps the same input node');
 queue=[];const failed=w.loadHelp();queue[0].reject(new Error('Help unavailable'));await failed;
 assert.match($('editorCapabilityStatus').textContent,/unavailable/);assert.equal(d.querySelectorAll('.editor-unadvertised').length,0,'No false compatibility claim after failed help');
 assert.equal($('reasoningEffort').value,before.reasoningEffort);
 assert.deepEqual(errors,[]);
 console.log('Editor presentation passed: 24 prior-release serialization cases, control parity, search/disclosure and build-help races');
}finally{w.close()}}
main().catch(e=>{console.error(e);process.exitCode=1});
