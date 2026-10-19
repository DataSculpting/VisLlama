const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = require('./support/ui.cjs').inlineHTML();
const validation = source.match(/^function validateAlias\(\)\{.*\}$/m)?.[0];
assert.ok(validation, 'alias validation must be present in the editor');
const elements = {
  alias: {value:'', attributes:{}, setAttribute(key,value){this.attributes[key]=value}, getAttribute(key){return this.attributes[key]}},
  aliasError: {textContent:'', classList:{hidden:false,toggle(name,hidden){this.hidden=hidden}}},
};
const context = {$: id => elements[id]};
vm.createContext(context);
vm.runInContext(validation, context);
for (const value of ['Model (test)', 'Model test', 'Model/test', '']) {
  elements.alias.value=value;
  assert.ok(context.validateAlias(), `expected ${JSON.stringify(value)} to be rejected`);
  assert.equal(elements.alias.attributes['aria-invalid'], 'true');
  assert.equal(elements.aliasError.classList.hidden, false);
}
elements.alias.value='Model-test';
assert.equal(context.validateAlias(), '');
assert.equal(elements.alias.attributes['aria-invalid'], 'false');
assert.equal(elements.aliasError.classList.hidden, true);
assert.ok(source.includes('const aliasProblem=validateAlias();if(aliasProblem)'));
assert.ok(source.includes('Project page: <a href="https://www.visllama.com/"'));
console.log('Alias editor validation and footer passed');
