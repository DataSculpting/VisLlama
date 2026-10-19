// Mounted native-select contracts and the real Perl serializer/INI boundary.
// No actual native dropdown popup, GPU or Qwen inference is represented here.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {execFileSync}=require('node:child_process'),{JSDOM}=require('jsdom'),ui=require('./support/ui.cjs');
const dom=new JSDOM(ui.html(),{runScripts:'outside-only',url:'http://visllama.test/'}),w=dom.window,$=id=>w.document.getElementById(id);
const run=code=>vm.runInContext(code,dom.getInternalVMContext()),plain=value=>JSON.parse(JSON.stringify(value));
for(const file of ['state','core','models','arguments','editor'])run(fs.readFileSync(path.join(ui.root,'public/assets/js',file+'.js'),'utf8'));
w.filterBuildOptions=()=>{};w.syncEditorActions=()=>{};w.priorityPlanPreview=()=>{};w.syncNgramUi=()=>{};
const notices=[];w.toast=text=>notices.push(text);
const model=(file,variant='Target')=>({supplier:'Local',variant,file,path:'C:\\GGUF\\Local\\'+variant+'\\'+file,size:1024});
const target=model('target.gguf'),head=model('external heads.gguf','MTP'),added=model('new.gguf','Other');
run(`CFG={model_root:'C:\\\\GGUF',builds:[]};MODELS=${JSON.stringify([target,head])};HELP=[]`);
w.rebuildHierarchy();$('draft').value=head.path;$('specType').value='draft-mtp';$('alias').value='target';
let pending=[],requests=0;
w.post=(url,body,opts)=>{assert.equal(url,'/api/refresh-models');assert.equal(opts.busy,false);requests++;return new Promise((resolve,reject)=>pending.push({resolve,reject}));};
w.bindModelFileRefresh();
const tick=()=>new Promise(resolve=>setImmediate(resolve));
(async()=>{try{
 $('draft').dispatchEvent(new w.Event('pointerdown'));$('draft').dispatchEvent(new w.Event('focus'));await tick();assert.equal(requests,1,'Pointer/focus share one scan');assert.equal($('draft').getAttribute('aria-busy'),'true');
 pending.shift().resolve({model_root:'C:\\GGUF',models:[target,head,added]});await tick();
 assert.equal($('draft').value,head.path,'External MTP selection survives refresh');assert.equal($('model').value,target.path,'Target choice survives refresh');assert([...$('draft').options].some(o=>o.value===added.path));assert.equal($('supplier').getAttribute('aria-busy'),null);
 // Unchanged inventories preserve native option nodes rather than resetting a picker.
 const option=$('draft').selectedOptions[0];let scan=w.refreshModelFileChoices();pending.shift().resolve({models:[target,head,added]});await scan;assert.equal($('draft').selectedOptions[0],option);
 scan=w.refreshModelFileChoices();$('draft').value=added.path;pending.shift().resolve({models:[target,head,added]});await scan;assert.equal($('draft').value,added.path,'Selection made during scan wins');
 $('draft').value=head.path;scan=w.refreshModelFileChoices();pending.shift().resolve({models:[target,added]});await scan;
 assert.equal($('draft').value,head.path,'Deleted external head is not replaced with embedded MTP');assert($('draft').selectedOptions[0].disabled);assert.match($('draft').selectedOptions[0].textContent,/Unavailable file/);assert.match($('mtpHint').textContent,/unavailable/);
 assert(![...$('draft').options].some(o=>o.value===head.path&&!o.disabled),'Deleted file is no longer an available choice');
 scan=w.refreshModelFileChoices();pending.shift().resolve({models:[target,head,added]});await scan;assert.equal($('draft').value,head.path);assert(!$('draft').selectedOptions[0].disabled,'Recreated head restores choice');
 // Old-root response must not overwrite a newly configured library.
 scan=w.refreshModelFileChoices();run("CFG.model_root='D:\\\\New'");pending.shift().resolve({model_root:'C:\\GGUF',models:[]});assert.equal(await scan,false);assert.equal($('draft').value,head.path);
 $('model').dispatchEvent(new w.KeyboardEvent('keydown',{key:'ArrowDown'}));pending.shift().reject(new Error('Scan unavailable'));await tick();assert.equal(notices.length,1);assert.equal($('draft').value,head.path,'Scan failure retains configuration');
 run(`MODELS=${JSON.stringify([target])}`);w.rebuildHierarchy({supplier:'Local',variant:'Target',model:target.path,draft:head.path});assert.equal($('draft').value,head.path,'Saved missing head retained when reopening');
 const legacy=plain(w.friendlyArgs());assert.equal(legacy[legacy.indexOf('--model-draft')+1],head.path);assert.equal(legacy[legacy.indexOf('--spec-type')+1],'draft-mtp');
 run("HELP=[{flag:'--spec-draft-model',aliases:['--spec-draft-model','--model-draft'],signature:'--spec-draft-model FNAME',description:'Draft',takes_value:true}]");
 const modern=plain(w.friendlyArgs());assert.equal(modern[modern.indexOf('--spec-draft-model')+1],head.path);assert(!modern.includes('--model-draft'));assert.equal(w.presetData().draft,head.path);w.renderOptions();assert.equal($('options').querySelector('[data-flag="--spec-draft-model"]'),null,'External draft option is not duplicated in Advanced');
 for(const argv of [legacy,modern]){
  const result=JSON.parse(execFileSync('perl',['-I',path.join(ui.root,'lib'),'-MVisLlama::Catalog','-MJSON::PP','-e','local $/;my $args=decode_json(<STDIN>);print encode_json(VisLlama::Catalog::args_to_preset_options($args));'],{input:JSON.stringify(argv),encoding:'utf8'}));
  assert(result.some(([key,value])=>['model-draft','spec-draft-model'].includes(key)&&value===head.path),'Literal external path reaches backend options');
 }
 $('draft').value='';const embedded=plain(w.friendlyArgs());assert(!embedded.includes('--model-draft')&&!embedded.includes('--spec-draft-model'));assert(embedded.includes('draft-mtp'),'Embedded MTP remains explicit');
 console.log('File selector refresh, added/deleted/recreated files, current choices, stale-root/error handling and external/embedded MTP argument roundtrip passed');
}finally{dom.window.close()}})().catch(error=>{console.error(error);process.exitCode=1});
