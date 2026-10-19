// Actual chat modules, normalized fixture streams and controlled races. No GPU inference.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const base=path.join(__dirname,'../public/assets/js/chat');
const sandbox={crypto:require('node:crypto').webcrypto,TextDecoder,TextEncoder,performance,AbortController,DOMException,fetch,setTimeout,clearTimeout,structuredClone};vm.createContext(sandbox);
for(const name of ['conversation','streaming','metrics','provider','storage','generation'])vm.runInContext(fs.readFileSync(path.join(base,name+'.js'),'utf8'),sandbox);
const C=sandbox.VisLlamaChat,plain=x=>JSON.parse(JSON.stringify(x));
(async()=>{
 const available=C.create();assert.equal(available.options.outputLimit,'available');assert(!Object.hasOwn(C.buildRequest(available),'max_tokens'));assert(!Object.hasOwn(C.buildRequest(available),'max_completion_tokens'));assert(C.validate(available));assert.equal(available.options.temperatureMode,'model');assert(!Object.hasOwn(C.buildRequest(available),'temperature'),'Model default omits temperature rather than guessing it');
 const restoredMode=plain(available);restoredMode.options.maxTokens=262144;
 assert(C.validate(restoredMode));assert(!Object.hasOwn(C.buildRequest(restoredMode),'max_tokens'),'Existing available-mode chats no longer send -1');
 assert(!Object.hasOwn(C.buildRequest(restoredMode),'max_completion_tokens'));
 const legacy=plain(available);delete legacy.options.outputLimit;delete legacy.options.temperatureMode;legacy.options.maxTokens=1024;
 assert(C.validate(legacy));assert.equal(C.buildRequest(legacy).max_tokens,1024,'Legacy conversations retain saved caps');
 assert.equal(C.buildRequest(legacy).temperature,0.8,'Legacy override retained');
 const override=plain(available);override.options.temperatureMode='override';override.options.temperature=0;
 assert.equal(C.buildRequest(override).temperature,0,'Greedy zero override is sent');assert(C.validate(override));
 override.options.temperature=1.2;assert.equal(C.buildRequest(override).temperature,1.2);
 for(const value of [-0.1,2.1,NaN]){const c=plain(override);c.options.temperature=value;assert(!C.validate(c))}
 override.options.temperatureMode='invalid';assert(!C.validate(override));
 const capped=plain(available);capped.options.outputLimit='cap';capped.options.maxTokens=262144;assert(C.validate(capped));assert.equal(C.buildRequest(capped).max_tokens,262144,'Explicit caps can match large context sizes');
 for(const invalid of [0,-1,1.5,2147483648]){const c=plain(capped);c.options.maxTokens=invalid;assert(!C.validate(c))}
 const invalid=plain(available);invalid.options.outputLimit='other';assert(!C.validate(invalid));
 assert.match(C.limitNotice({status:'complete',finishReason:'length'}),/^Output limit reached/);
 for(const status of ['aborted','error','streaming'])assert.equal(C.limitNotice({status,finishReason:'length'}),'');assert.equal(C.limitNotice({status:'complete',finishReason:'stop'}),'');
 const events=[],parser=new C.SSEParser((data,event)=>events.push([JSON.parse(data),event]));const bytes=new TextEncoder().encode(': heartbeat\r\ndata: {"text":\r\ndata: "π🙂"}\r\n\r\ndata: [DONE]\n\n');for(const b of bytes)parser.push(Uint8Array.of(b));assert.equal(parser.done,true);assert.deepEqual(plain(events),[[{text:'π🙂'},'message']]);
 assert.throws(()=>new C.SSEParser(()=>{}).push(new TextEncoder().encode('data: incomplete'),true),/incomplete|ended|truncated/i);
 let now=0;const metrics=new C.Metrics(100,()=>now);now=100;metrics.update({usage:{prompt_tokens:10,completion_tokens:1}});assert.equal(metrics.value.ttftMs,undefined);now=150;metrics.token();now=250;metrics.token();metrics.update({usage:{prompt_tokens:10,completion_tokens:5}});assert.equal(metrics.value.totalTokens,15);assert.equal(metrics.value.contextPercent,15);metrics.update({timings:{cache_n:4,prompt_n:6,predicted_n:5,prompt_ms:20,prompt_per_second:300,predicted_per_second:50}});assert.equal(metrics.value.prefillTokensPerSecond,300);assert.equal(metrics.value.generationTokensPerSecond,50);assert.equal(metrics.value.ttftMs,150);now=300;assert.equal(metrics.finish().totalTimeMs,300);
 const missing=new C.Metrics();missing.token();missing.finish();assert.equal(missing.value.prefillTokensPerSecond,undefined);assert.equal(missing.value.totalTokens,undefined);
 const delivered=[];const sse='data: '+JSON.stringify({choices:[{delta:{role:'assistant'}}]})+'\n\ndata: '+JSON.stringify({choices:[{delta:{reasoning_content:'Think',reasoning:'Think',content:'Hi'}}]})+'\n\ndata: '+JSON.stringify({choices:[{delta:{},finish_reason:'stop'}],usage:{completion_tokens:2}})+'\n\ndata: [DONE]\n\n';
 const response=()=>new Response(new ReadableStream({start(c){const b=new TextEncoder().encode(sse);for(let i=0;i<b.length;i+=3)c.enqueue(b.slice(i,i+3));c.close()}}),{headers:{'content-type':'text/event-stream'}});
 await new C.LlamaCppProvider({endpoint:'http://fixture'},async()=>response()).generate({model:'m'},e=>delivered.push(e),new AbortController().signal);assert.equal(delivered.filter(e=>e.type==='reasoning').length,1);assert.equal(delivered.at(-1).type,'complete');
 await assert.rejects(new C.LlamaCppProvider({endpoint:''},async()=>new Response('data: {}\n\n',{headers:{'content-type':'text/event-stream'}})).generate({},()=>{},new AbortController().signal),/Invalid/);
 const data=new Map(),storage={get length(){return data.size},key:i=>[...data.keys()][i],getItem:k=>data.get(k)||null,setItem:(k,v)=>data.set(k,v),removeItem:k=>data.delete(k)},store=new C.BrowserStore(storage),notices=[];
 const ctrl=new C.Controller(store,()=>{},n=>notices.push(n));ctrl.conversation.model='m';let release,late;
 const pending={connection:{context_size:100},generate:async(req,emit,signal)=>{late=emit;emit({type:'content',delta:'partial'});await new Promise(r=>release=r);emit({type:'content',delta:'STALE'})}};
 const run=ctrl.send('Hello',pending);const old=ctrl.conversation.messages.at(-1);ctrl.stop();assert.equal(old.status,'aborted');assert.equal(old.content,'partial');
 const quick={connection:{},generate:async(req,emit)=>{assert(!req.messages.some(m=>m.reasoning));emit({type:'content',delta:'new'});emit({type:'usage',value:{usage:{completion_tokens:1}}})}};
 await ctrl.send('Again',quick);release();await run;assert.equal(old.content,'partial');assert.equal(ctrl.conversation.messages.at(-1).content,'new');
 const first=ctrl.conversation.messages[0];await ctrl.edit(first.id,'Edited',quick);assert.equal(ctrl.conversation.messages.length,2);assert.equal(ctrl.conversation.messages[0].id,first.id);assert.equal(ctrl.conversation.messages[0].content,'Edited');const responseID=ctrl.conversation.messages[1].id;await ctrl.regenerate(responseID,quick);assert.notEqual(ctrl.conversation.messages[1].id,responseID);ctrl.remove(ctrl.conversation.messages[1].id);assert.equal(ctrl.conversation.messages.length,1);
 const loaded=await store.load(ctrl.conversation.id);assert(C.validate(loaded));loaded.messages.push({...loaded.messages[0]});assert(!C.validate(loaded),'duplicate identities rejected');assert.equal(notices.length,0);clearTimeout(ctrl.persistTimer);
 const bad=new C.Controller({save:async()=>{throw Error('private')}} ,()=>{},n=>notices.push(n));await bad.save();assert.match(notices[0],/could not be saved/);
 const limits=new C.Controller(store,()=>{},()=>{});limits.conversation.model='m';
 await limits.send('Long answer',{connection:{},generate:async(req,emit)=>{assert(!Object.hasOwn(req,'max_tokens'));assert(!Object.hasOwn(req,'max_completion_tokens'));emit({type:'content',delta:'Retained partial answer'});emit({type:'finish',reason:'length'})}});
 const limited=limits.conversation.messages.at(-1);assert.equal(limited.status,'complete');assert.equal(limited.content,'Retained partial answer');assert.match(C.limitNotice(limited),/Output limit reached/);
 const restored=await store.load(limits.conversation.id);assert.match(C.limitNotice(restored.messages.at(-1)),/Output limit reached/);clearTimeout(limits.persistTimer);
 console.log('Chat core passed: split UTF-8/SSE, metrics truth, provider validation, cancellation races, edit/regenerate/delete, storage and import identity');
})().catch(e=>{console.error(e);process.exitCode=1});
