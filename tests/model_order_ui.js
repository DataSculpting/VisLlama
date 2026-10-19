const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const source = require('./support/ui.cjs').inlineHTML();
const routine=source.match(/async function moveModelOrder\(from,to\)\{[\s\S]*?\n\}/)?.[0];
assert.ok(routine,'model order handler must exist');
assert.ok(!source.includes('id="modelLoadOrderCard"'), 'do not render a duplicate model order list');
assert.ok(source.includes('data-order-handle draggable='), 'drag handle belongs in each model library row');
assert.ok(source.includes('data-order-up=')&&source.includes('data-order-down='), 'keyboard-accessible buttons belong in each model library row');
const events=[];
const originals=[{alias:'alpha'},{alias:'beta'},{alias:'gamma'}];
let fail=false;
const context={
    ROUTER_PRESETS:originals,MODEL_ORDER_BUSY:false,
    renderModelLibrary:()=>{},renderRouterPresets:()=>{},toast:message=>events.push(message),
    post:async (route,body)=>{events.push([route,[...body.aliases]]);if(fail)throw Error('save failed');return {presets:context.ROUTER_PRESETS}},
};
vm.createContext(context);vm.runInContext(routine,context);
(async()=>{
    await context.moveModelOrder('gamma','alpha');
    assert.equal(context.ROUTER_PRESETS.map(x=>x.alias).join(','),'gamma,alpha,beta');
    assert.equal(events[0][0],'/api/router-preset-order');
    assert.equal(events[0][1].join(','),'gamma,alpha,beta');
    const saved=context.ROUTER_PRESETS;
    fail=true;events.length=0;
    await context.moveModelOrder('gamma','beta');
    assert.equal(context.ROUTER_PRESETS,saved,'failed reorder must restore the saved catalog');
    assert.equal(context.MODEL_ORDER_BUSY,false);
    console.log('Model load order UI passed');
})().catch(error=>{console.error(error);process.exitCode=1});
