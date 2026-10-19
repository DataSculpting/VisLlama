// Browser contracts only: native executable guidance, case-sensitive discovery,
// usable Linux roots and safe shell copy/preview. No live browser layout test.
const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');const vm=require('node:vm');
const context=vm.createContext({CFG:{platform:'linux',server_executable:'llama-server'},Map,Set,Date,Error});
for(const file of ['core.js','builds.js'])vm.runInContext(fs.readFileSync(path.join(__dirname,'../public/assets/js',file),'utf8'),context);
const run=code=>vm.runInContext(code,context);
assert.equal(run('buildExecutableName()'),'llama-server');
assert.notEqual(run('buildPathKey("/Build/llama-server")'),run('buildPathKey("/build/llama-server")'));
assert.equal(run('q("/models/simple.gguf")'),'/models/simple.gguf');
assert.equal(run('q("a b")'),"'a b'");
assert.equal(run('q("$(touch unwanted)")'),"'$(touch unwanted)'");
assert.equal(run('q("a\'b")'),"'a'\"'\"'b'");
run("CFG={platform:'windows',server_executable:'llama-server.exe'}");
assert.equal(run('buildExecutableName()'),'llama-server.exe');
assert.equal(run('buildPathKey("C:/Build/llama-server.exe")'),'c:/build/llama-server.exe');
assert.equal(run('q("C:\\\\model files\\\\a.gguf")'),'"C:\\model files\\a.gguf"');
console.log('Linux/Windows UI platform guidance, path identity and command preview quoting passed');
