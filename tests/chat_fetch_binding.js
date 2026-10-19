// Browser-style fetch receiver check; Node's native fetch does not enforce it.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const sandbox={crypto:require('node:crypto').webcrypto,performance,AbortController,DOMException,Response,setTimeout,clearTimeout,structuredClone};vm.createContext(sandbox);
vm.runInContext(`
 globalThis.calls=[];
 globalThis.fetch=function(url,options){
  'use strict';
  if(this!==globalThis)throw new TypeError('Illegal invocation');
  calls.push({url,options});
  return Promise.resolve(new Response(JSON.stringify({choices:[{message:{content:'Hello'},finish_reason:'stop'}]}),{headers:{'Content-Type':'application/json'}}));
 };
`,sandbox);
for(const name of ['conversation','metrics','provider','generation'])vm.runInContext(fs.readFileSync(path.join(__dirname,'../public/assets/js/chat',name+'.js'),'utf8'),sandbox);
(async()=>{
 const C=sandbox.VisLlamaChat,notices=[],controller=new C.Controller({save:async()=>{}},()=>{},text=>notices.push(text));
 controller.conversation.model='model';
 const provider=new C.LlamaCppProvider({endpoint:'http://192.168.6.39:8080'});
 await controller.send('Hello',provider,'session-key');
 const answer=controller.conversation.messages.at(-1);
 assert.equal(answer.status,'complete','Default browser fetch must reach inference rather than become a caught transport error');
 assert.equal(answer.content,'Hello');assert.deepEqual(notices,[]);
 assert.equal(sandbox.calls.length,1);const {url,options}=sandbox.calls[0];
 assert.equal(url,'http://192.168.6.39:8080/v1/chat/completions');
 assert.equal(options.method,'POST');assert.equal(options.credentials,'omit');
 assert.equal(options.headers.Authorization,'Bearer session-key');assert.equal(options.signal.aborted,false);
 assert.equal(JSON.parse(options.body).messages[0].content,'Hello');
 // Injected transports remain supported for fixtures and future adapters.
 let injected=0;await new C.LlamaCppProvider({endpoint:'http://fixture'},async()=>{injected++;return new Response(JSON.stringify({choices:[{message:{content:'Fixture'}}]}),{headers:{'Content-Type':'application/json'}})}).generate({model:'model'},()=>{},new AbortController().signal);
 assert.equal(injected,1);
 console.log('Chat fetch binding passed: browser receiver, controller completion, /v1 route, credentials, abort signal and injected transport');
})().catch(e=>{console.error(e);process.exitCode=1});
