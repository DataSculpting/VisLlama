const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const source = require('./support/ui.cjs').inlineHTML();
const editor=source.match(/async function applyUiPreset\(p\)\{[\s\S]*?\n\}/)?.[0];
assert.ok(editor);
const fields=new Map([
    ['routerHost',{type:'text',value:'192.168.6.39'}],
    ['routerPort',{type:'text',value:'18080'}],
    ['routerMax',{type:'text',value:'2'}],
    ['routerAutoload',{type:'checkbox',checked:false}],
]);
const context={
    $:id=>fields.get(id)||(id==='options'?{replaceChildren:()=>{}}:id==='rawHelp'?{}:undefined),loadHelp:async()=>{},loadDevices:async()=>{},
    newModelDefaults:()=>({}),rebuildHierarchy:()=>{},HELP:[],
    rebuildVariants:()=>{},rebuildFiles:()=>{},syncSpecUi:()=>{},
    syncBuildStatus:()=>{},syncMode:()=>{},updateCommand:()=>{},
};
vm.createContext(context);vm.runInContext(editor,context);
(async()=>{
    await context.applyUiPreset({routerHost:'0.0.0.0',routerPort:'8080',routerMax:'4',routerAutoload:true});
    assert.equal(fields.get('routerHost').value,'192.168.6.39');
    assert.equal(fields.get('routerPort').value,'18080');
    assert.equal(fields.get('routerMax').value,'2');
    assert.equal(fields.get('routerAutoload').checked,false);
    const backend=fs.readFileSync(path.join(__dirname,'..','lib','VisLlama','Process.pm'),'utf8');
    const start=backend.match(/sub start_router_impl \{[\s\S]*?\n\}/)?.[0];
    assert.ok(start);
    assert.doesNotMatch(start,/save_router_service_config\(/,'Router start must not overwrite saved settings');
    assert.match(start,/my \$host = \$saved_router->\{host\}/);
    console.log('Router settings isolation passed');
})().catch(error=>{console.error(error);process.exitCode=1});
