const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = require('./support/ui.cjs').inlineHTML();
const friendly = source.match(/^function friendlyArgs\(\)\{.*\}$/m)?.[0];
const draftFlag = source.match(/^function draftModelFlag\(\)\{.*\}$/m)?.[0];
const validate = source.match(/^function validateConfig\(\)\{.*\}$/m)?.[0];
const strip = source.match(/^function priorityArgsWithoutOverrides\(a\)\{.*\}$/m)?.[0];
assert.ok(friendly && validate && strip && draftFlag, 'GPU editor functions should be present');

const values = {gpuPriority: 'manual', gpuReserve: '2048', tensorSplit: '3,1', mainGpu: '1', splitMode: 'row', serverMode: 'router', specType: 'none', ngramType: 'none', extra: ''};
let devices = ['CUDA0', 'CUDA1'];
const sandbox = {
    $: id => ({value: values[id] ?? '', checked: false}),
    HELP: [],
    selectedDevices: () => devices,
    validateFitOptions: () => '',
    add: (a, flag, value) => {if (value !== undefined && value !== null && String(value).trim()) a.push(flag, String(value).trim())},
};
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(path.join(__dirname,'../public/assets/js/arguments.js'),'utf8'),sandbox);
vm.runInContext(`${draftFlag}\n${validate}\n${friendly}\n${strip}`, sandbox);

function option(a, flag) {const i=a.indexOf(flag); return i<0?null:a[i+1]}

let a=sandbox.friendlyArgs();
assert.equal(option(a,'--tensor-split'),'3,1');
assert.equal(option(a,'--split-mode'),'row');
assert.equal(option(a,'--main-gpu'),'1');

values.gpuPriority='even';
a=sandbox.friendlyArgs();
assert.equal(option(a,'--device'),'CUDA0,CUDA1');
assert.equal(option(a,'--tensor-split'),'1,1');
assert.equal(option(a,'--split-mode'),'layer');
assert.equal(option(a,'--main-gpu'),null);
assert.equal(sandbox.validateConfig(),'');
values.extra='--tensor-split\n9,1\n--main-gpu\n0\n--split-mode\nrow';
a=sandbox.friendlyArgs();
assert.equal(a.filter(x=>x==='--tensor-split').length,1);
assert.equal(option(a,'--tensor-split'),'1,1');
assert.equal(option(a,'--split-mode'),'layer');
assert.equal(option(a,'--main-gpu'),null);
values.extra='';
devices=['CUDA0'];
assert.match(sandbox.validateConfig(),/at least two/);
devices=['CUDA0','CUDA1','CUDA2'];
assert.equal(option(sandbox.friendlyArgs(),'--tensor-split'),'1,1,1');

values.gpuPriority='priority';
a=sandbox.friendlyArgs();
assert.equal(option(a,'--tensor-split'),null);
assert.equal(option(a,'--split-mode'),null);
assert.equal(option(a,'--device'),'CUDA0,CUDA1,CUDA2');
assert.equal(sandbox.validateConfig(),'');
values.gpuPriority='priority_split';
a=sandbox.friendlyArgs();
assert.equal(option(a,'--tensor-split'),null);
assert.equal(sandbox.validateConfig(),'');
values.ctx='32768'; values.parallel='1'; values.loadMode='none';
values.extra='--ctx-size\n262144\n--parallel\n4\n--load-mode\nmmap';
a=sandbox.friendlyArgs();
assert.equal(a.filter(x=>x==='--ctx-size').length,1);
assert.equal(option(a,'--ctx-size'),'32768');
assert.equal(option(a,'--parallel'),'1');
assert.equal(option(a,'--load-mode'),'none');
const cleaned=sandbox.priorityArgsWithoutOverrides(['--ctx-size','4096','--device','CUDA0,CUDA1','--fit-target','64','--no-fit','--gpu-layers','all','--fit','off']);
assert.equal(Array.from(cleaned).join(','),'--ctx-size,4096');
// Preview requests must carry the same slot/rollback settings that saved
// presets pass to the load-time planner. Changing either invalidates the key.
const update=source.match(/^function updateCommand\(\)\{[\s\S]*?^\}/m)?.[0];
assert.ok(update);
const elements={};
let requests=[];
Object.assign(sandbox,{
  $:id=>elements[id]??=( {value:values[id]??'',checked:false,setCustomValidity:()=>{},setAttribute:()=>{},classList:{contains:()=>true}} ),
  CFG:{builds:[{name:'test',exe:'llama-server.exe'}]},EDITOR_ALIAS:'',
  PRIORITY_PREVIEW:null,PRIORITY_PREVIEW_KEY:'',PRIORITY_TIMER:null,
  presetData:()=>Object.fromEntries(['parallel','draftTokens','swaFull','kvUnified','kvUnifiedPerSlot','noKvOffload','batch','ubatch','cacheK','cacheV'].map(id=>[id,sandbox.$(id).value])),
  syncEditorActions:()=>{},selectedModel:()=>'/test.gguf',args:()=>[],q:x=>x,
  updatePriorityPreview:(key,payload)=>requests.push({key,payload}),
});
values.build='test';values.specType='draft-mtp';values.parallel='1';values.draftTokens='4';
vm.runInContext(update,sandbox);
sandbox.updateCommand();
assert.equal(requests[0].payload.settings.parallel,'1');
assert.equal(requests[0].payload.settings.draftTokens,'4');
elements.parallel.value='4';sandbox.updateCommand();
elements.draftTokens.value='8';sandbox.updateCommand();
assert.equal(requests.length,3);
assert.equal(new Set(requests.map(r=>r.key)).size,3);
assert.equal(requests[2].payload.settings.parallel,'4');
assert.equal(requests[2].payload.settings.draftTokens,'8');
sandbox.args=()=>['--cache-type-k','q8_0','--swa-full'];
sandbox.updateCommand();
assert.deepEqual(Array.from(requests.at(-1).payload.args),['--cache-type-k','q8_0','--swa-full']);
assert.notEqual(requests.at(-1).key,requests[2].key,'Effective build-specific options invalidate preview');
elements.kvUnified.value='on';elements.kvUnifiedPerSlot.value='32768';
sandbox.updateCommand();
assert.equal(requests.at(-1).payload.settings.kvUnifiedPerSlot,'32768');
assert.equal(requests.at(-1).payload.settings.kvUnified,'on');
console.log('GPU distribution controls and hybrid preview inputs passed');
