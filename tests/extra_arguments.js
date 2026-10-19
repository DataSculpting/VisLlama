// Exercise the browser parser and the Perl catalog boundary with the same data.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {execFileSync}=require('node:child_process');
const root=path.resolve(__dirname,'..'),box={};vm.createContext(box);
vm.runInContext(fs.readFileSync(path.join(root,'public/assets/js/arguments.js'),'utf8'),box);
const parse=text=>JSON.parse(JSON.stringify(box.parseExtraArguments(text)));
const cases=[
 ['--log-verbosity 4',['--log-verbosity','4']],
 ['--log-verbosity\n4',['--log-verbosity','4']],
 ['--log-verbosity=4',['--log-verbosity','4']],
 ['--no-warmup\n--temperature -0.1',['--no-warmup','--temperature','-0.1']],
 ['--chat-template-file "C:\\Model Files\\my template.jinja"',['--chat-template-file','C:\\Model Files\\my template.jinja']],
 ['--chat-template-file\nC:\\Model Files\\my template.jinja',['--chat-template-file','C:\\Model Files\\my template.jinja']],
 ['--chat-template-file C:\\Model Files\\my template.jinja',['--chat-template-file','C:\\Model Files\\my template.jinja']],
 ['--override-kv some.key=str:two words',['--override-kv','some.key=str:two words']],
 ['--custom ""',['--custom','']],
 ['--custom {"key":"value"}',['--custom','{"key":"value"}']],
 ['--custom "a \\"quote\\" b"',['--custom','a "quote" b']],
 ['\r\n--log-verbosity 4\r\n\r\n--no-warmup\r\n',['--log-verbosity','4','--no-warmup']],
];
for(const [input,expected] of cases){const p=parse(input);assert.equal(p.error,'');assert.deepEqual(p.tokens,expected)}
for(const text of ['4','--bad] 4','--log-verbosity 4\nextra','--custom "unclosed','--log-verbosity 4 --no-warmup','--custom=x\u0000']){
 const p=parse(text);assert.match(p.error,/Extra arguments, line/);assert.deepEqual(p.tokens,[]);
}
const tokens=cases.map(([text])=>parse(text).tokens);
const perl='use JSON::PP; use VisLlama::Catalog (); local $/; my $lists=decode_json(<STDIN>); print encode_json([map { VisLlama::Catalog::args_to_preset_options($_) } @$lists]);';
const result=JSON.parse(execFileSync('perl',['-I',path.join(root,'lib'),'-e',perl],{input:JSON.stringify(tokens),encoding:'utf8'}));
assert.deepEqual(result[0],[['log-verbosity','4']]);assert.deepEqual(result[1],result[0]);assert.deepEqual(result[2],result[0]);
assert.deepEqual(result[4],[['chat-template-file','C:\\Model Files\\my template.jinja']]);
console.log('Extra arguments passed: natural/legacy/equal syntax, Windows paths, quotes, malformed input and real Perl conversion');

// Cover the real editor argument builder, not only the standalone parser. The
// reported preview quoted "--log-verbosity 4" as a single argument.
const {JSDOM}=require('jsdom'),ui=require('./support/ui.cjs');
const dom=new JSDOM(ui.html(),{runScripts:'outside-only',url:'http://visllama.test/'});
try {
 const w=dom.window,ctx=dom.getInternalVMContext();
 for(const file of ['state','core','arguments','editor','router'])vm.runInContext(fs.readFileSync(path.join(root,'public/assets/js',file+'.js'),'utf8'),ctx);
 w.document.getElementById('extra').value='--log-verbosity 4';
 w.document.getElementById('gpuPriority').value='manual';
 const actual=JSON.parse(JSON.stringify(vm.runInContext('args()',ctx)));
 assert.ok(!actual.includes('--log-verbosity 4'));
 assert.deepEqual(actual.slice(-2),['--log-verbosity','4']);
 const saved=JSON.parse(execFileSync('perl',['-I',path.join(root,'lib'),'-e',perl],{input:JSON.stringify([actual]),encoding:'utf8'}))[0];
 assert.deepEqual(saved.find(p=>p[0]==='log-verbosity'),['log-verbosity','4']);
 // Older pages can still submit the whole line. The backend must accept the
 // same intent while retaining strict INI identifier validation.
 const legacy=actual.slice(0,-2).concat('--log-verbosity 4');
 const repaired=JSON.parse(execFileSync('perl',['-I',path.join(root,'lib'),'-e',perl],{input:JSON.stringify([legacy]),encoding:'utf8'}))[0];
 assert.deepEqual(repaired,saved);
 console.log('Real editor and legacy combined-token requests save identical options');
} finally {dom.window.close()}
