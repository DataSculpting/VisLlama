const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = require('./support/ui.cjs').inlineHTML();
const functions = ['runningModelArgs', 'argumentValue', 'savedRuntimeMismatch', 'currentRouterModel', 'waitForRouterModel'].map(name => {
    const match = source.match(new RegExp(`^(?:async )?function ${name}\\(.*$`, 'm'));
    assert.ok(match, `${name} exists`);
    return match[0];
}).join('\n');

let states = [];
const sandbox = {
    LAST_STATUS: {runtime_token:"fixture"},
    post: async () => ({result: {data: [{id: 'sample', status: states.shift()}]}}),
    setTimeout: resolve => resolve(),
};
vm.createContext(sandbox);
vm.runInContext(functions, sandbox);

const saved = {options: [['ctx-size', '32768'], ['parallel', '1'], ['load-mode', 'none']]};
const oldChild = {status: {value: 'loaded', args: ['llama-server', '--ctx-size', '262144', '--parallel', '4', '--load-mode', 'mmap']}};
const newChild = {status: {value: 'loaded', args: ['llama-server', '--ctx-size', '32768', '--parallel', '1', '--load-mode', 'none']}};
assert.equal(Array.from(sandbox.savedRuntimeMismatch(saved, oldChild)).join(','), 'ctx-size,parallel,load-mode');
assert.equal(sandbox.savedRuntimeMismatch(saved, newChild).length, 0);

(async () => {
    states = [{value: 'loaded'}, {value: 'unloaded'}];
    assert.equal((await sandbox.waitForRouterModel('sample', 'unloaded', 1000)).status.value, 'unloaded');
    states = [{value: 'loading'}, newChild.status];
    assert.equal((await sandbox.waitForRouterModel('sample', 'loaded', 1000)).status.value, 'loaded');
    states = [{value: 'unloaded', failed: true}];
    await assert.rejects(sandbox.waitForRouterModel('sample', 'loaded', 1000), /failed to load/);
    sandbox.post=async()=>({runtime_token:'replacement',result:{data:[]}});
    await assert.rejects(sandbox.waitForRouterModel('sample','loaded',1000), /Runtime changed/);
    console.log('Router reload verification passed');
})().catch(error => {console.error(error); process.exitCode = 1});
