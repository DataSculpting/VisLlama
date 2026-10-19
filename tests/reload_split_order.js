const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = require('./support/ui.cjs').inlineHTML();
const save=source.match(/async function saveEditorPreset\(reload=false\)\{[\s\S]*?\n\}\n/)?.[0];
assert.ok(save);
let events=[],failSave=false;
const fields={alias:'sample',build:'test',gpuPriority:'priority_split'};
const presets=[{alias:'sample',build:'test',enabled:true}];
const context={
    $: id=>({value:fields[id]||''}), ensureAlias:()=>{},validateConfig:()=>'',validateAlias:()=>'',
    ROUTER_PRESETS:presets,EDITOR_ALIAS:'sample',EDITOR_ORIGINAL_BUILD:'test',
    LAST_STATUS:{running:true,mode:'router',router_engines:[{running:true,build:'test',models:['sample']}]},
    EDITOR_SAVE_BUSY:false,MODEL_ACTION_PENDING:new Map(),
    editorModelAction:()=>({reason:''}),syncEditorActions:()=>{},
    currentRouterModel:async()=>({status:{value:'loaded'}}),
    selectedModel:()=>'/test.gguf',args:()=>[],presetData:()=>({}),
    post:async path=>{events.push(path);if(failSave&&path==='/api/router-preset-save')throw new Error('save failed');return path==='/api/router-preset-save'?{presets}:{ok:true}},
    waitForRouterModel:async (_name,state)=>{events.push(`wait-${state}`);return {status:{value:state}}},
    applyRouterConfig:async()=>{events.push('apply')},
    savedRuntimeMismatch:()=>[],renderRouterPresets:()=>{},renderModelLibrary:()=>{},
    closeEditor:()=>{},refreshRouterModels:async()=>{},toast:()=>{},showView:()=>{},
};
vm.createContext(context);vm.runInContext(save,context);
(async()=>{
    assert.equal(await context.saveEditorPreset(true),true);
    assert.deepEqual(events,[
        '/api/model-preflight','/api/router-unload','wait-unloaded','/api/router-preset-save',
        'apply','/api/router-load','wait-loaded'
    ]);
    events=[];failSave=true;
    assert.equal(await context.saveEditorPreset(true),false);
    assert.deepEqual(events,[
        '/api/model-preflight','/api/router-unload','wait-unloaded','/api/router-preset-save',
        '/api/router-load','wait-loaded'
    ],'failed save should restore the original loaded model');
    console.log('Calculated split reload sequence passed');
})().catch(e=>{console.error(e);process.exitCode=1});
