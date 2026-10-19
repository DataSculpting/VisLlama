const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = require('./support/ui.cjs').inlineHTML();
const render = source.match(/function renderDashModels\(\)\{[\s\S]*?\n\}\n/)?.[0];
const action = source.match(/async function routerAction\(kind,model\)\{[\s\S]*?\n\}\n/)?.[0];
assert.ok(render && action);
let writes=0, clicks=0, requests=0, clickHandler;
const root = {
    set innerHTML(v) { this.html=v; writes++ },
    get innerHTML() { return this.html },
    addEventListener: (name,handler) => { if(name==='click')clickHandler=handler },
};
const pending = new Map();
const sandbox = {
    $: id => id==='dashModels'?root:null,
    ROUTER_PRESETS: [{alias:'sample',build:'b',enabled:true}],
    LAST_STATUS: {running:true,mode:'router',router_engines:[{build:'b',running:true,models:['sample']}]},
    MODEL_STATUS_ERROR:false,MODEL_STATUS_FETCHED:true,MODEL_ACTION_PENDING:pending,
    DASH_MODELS_MARKUP:'',LIVE_ROUTER_MODELS:[{id:'sample',status:{value:'loaded'}}],
    liveFor: alias => sandbox.LIVE_ROUTER_MODELS.find(x=>x.id===alias),
    esc: x => String(x),
    status: async()=>{},renderRouterPresets: () => {},refreshRouterModels: () => {},toast: () => {},
    post: async () => {requests++;return {}},
    waitForRouterModel: async () => ({id:'sample',status:{value:'unloaded'}}),
    routerAction: () => {clicks++},
};
vm.createContext(sandbox);
vm.runInContext(source.match(/function routerModelControls\(p\)\{[\s\S]*?\n\}\n/)[0],sandbox);
vm.runInContext(render, sandbox);
vm.runInContext(source.match(/^\$\('dashModels'\)\.addEventListener\('click'.*$/m)[0], sandbox);
sandbox.renderDashModels();sandbox.renderDashModels();sandbox.renderDashModels();
assert.equal(writes,1,'refresh must keep the same button while its status is unchanged');
assert.match(root.html,/data-dash-action="unload"/);
clickHandler({target:{closest:()=>({disabled:false,dataset:{dashAction:'unload',dashModel:'sample'}})}});
assert.equal(clicks,1);
vm.runInContext(action, sandbox);
(async () => {
    await Promise.all([sandbox.routerAction('unload','sample'),sandbox.routerAction('unload','sample')]);
    assert.equal(requests,1,'in-flight unload should never issue a second request');
    assert.match(root.html,/data-dash-action="load"/);
    console.log('Dashboard model actions passed');
})().catch(e=>{console.error(e);process.exitCode=1});
