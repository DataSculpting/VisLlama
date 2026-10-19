// Production Studio DOM and Router publishers; no real browser or GPU inference.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {JSDOM}=require('jsdom'),ui=require('./support/ui.cjs');
const dom=new JSDOM(ui.html(),{runScripts:'outside-only',pretendToBeVisual:true,url:'http://127.0.0.1:9090/'}),w=dom.window,$=id=>w.document.getElementById(id);
w.TextDecoder=TextDecoder;w.TextEncoder=TextEncoder;w.AbortController=AbortController;w.structuredClone=structuredClone;w.ResizeObserver=class{observe(){}};w.scrollTo=()=>{};w.confirm=()=>true;w.navigator.clipboard={writeText:async()=>{}};
let snapshot=[{id:'alpha',status:{value:'loaded'}},{id:'beta',status:{value:'unloaded'}},{id:'loading',status:{value:'loading'}}],incomplete=false,token='runtime-one',generationRequests=0;
w.fetch=async(url,options)=>{
 if(url==='/api/chat-info')return new Response(JSON.stringify({ok:true,mode:'router',available:true,host:'127.0.0.1',port:8080,models:['alpha','beta','loading'].map(id=>({id})),context_size:8192}));
 if(url==='/api/router-models')return new Response(JSON.stringify({ok:true,runtime_token:token,result:{data:snapshot,incomplete}}));
 generationRequests++;return new Response(JSON.stringify({choices:[{message:{content:'Studio response'},finish_reason:'stop'}],usage:{prompt_tokens:12,completion_tokens:8,total_tokens:20},timings:{prompt_per_second:100,predicted_per_second:57.8},generation_settings:{n_ctx:8192}}),{headers:{'content-type':'application/json'}});
};
for(const match of ui.html().matchAll(/<script src="([^\"]+)"><\/script>/g)){if(match[1].includes('/startup.js'))continue;vm.runInContext(fs.readFileSync(path.join(ui.root,'public',match[1].split('?')[0]),'utf8'),dom.getInternalVMContext())}
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms)),options=()=>[...$('chatModel').options].filter(option=>option.value).map(option=>option.value);
const state=code=>vm.runInContext(code,dom.getInternalVMContext());
(async()=>{try{
 state('LAST_STATUS={running:true,mode:"router",runtime_token:"runtime-one"};ROUTER_PRESETS=[{alias:"alpha"},{alias:"beta"},{alias:"loading"}];');
 // Model publishers normally redraw other pages too; keep their fixture DOM idle.
 w.renderRouterPresets=()=>{};w.renderModelLibrary=()=>{};w.updateDashboard=()=>{};w.syncEditorActions=()=>{};
 await w.VisLlamaChat.open();await delay(70);const C=w.VisLlamaChat;
 assert.deepEqual(options(),['alpha'],'Only observed loaded presets are offered');assert.equal($('chatModel').value,'alpha');assert.equal($('chatSend').disabled,false);
 assert.equal(w.document.querySelector('#chatView>.page-title'),null);assert.equal(w.document.querySelector('#chatView>.page-sub'),null);
 for(const id of ['chatSystem','chatMaxTokens','chatTemperature','chatKey','chatContext','chatPerformance'])assert($('chatInspector').contains($(id)),'Settings/performance live in the Chat inspector: '+id);
 $('chatSystem').value='Keep this instruction';$('chatKey').value='private-session-key';$('chatInput').value='Keep my draft';
 $('chatSystem').focus();$('chatDetailsToggle').click();assert($('chatInspectorContent').hidden);assert.equal($('chatInspector').hidden,false,'Collapsed rail stays present');assert.equal(w.document.activeElement,$('chatDetailsToggle'));assert.equal($('chatDetailsToggle').getAttribute('aria-expanded'),'false');assert($('chatShell').classList.contains('inspector-collapsed'));
 assert.equal(w.localStorage.getItem('visllama.chat.ui.v1.inspector-collapsed'),'true');
 $('chatDetailsToggle').click();assert(!$('chatInspectorContent').hidden);assert.equal($('chatDetailsToggle').getAttribute('aria-expanded'),'true');
 assert.equal($('chatSystem').value,'Keep this instruction');assert.equal($('chatKey').value,'private-session-key');assert.equal($('chatInput').value,'Keep my draft');
 const firstOption=$('chatModel').options[0];await w.refreshRouterModels();assert.equal($('chatModel').options[0],firstOption,'Unchanged status does not rebuild a native picker');
 snapshot=[{id:'alpha',status:{value:'unloaded'}},{id:'beta',status:{value:'loaded'}},{id:'loading',status:{value:'loading'}}];await w.refreshRouterModels();await delay(70);
 assert.deepEqual(options(),['beta']);assert.equal($('chatSend').disabled,true);assert.equal(C.controller.conversation.model,'alpha','Do not silently retarget a conversation after its model unloads');
 $('chatComposer').requestSubmit();await delay(50);assert.equal(generationRequests,0,'Programmatic submit cannot autoload an unavailable model');assert.equal(C.controller.conversation.messages.length,0);
 $('chatModel').value='beta';$('chatModel').dispatchEvent(new w.Event('change'));await delay(80);assert.equal($('chatSend').disabled,false);
 incomplete=true;await w.refreshRouterModels();await delay(70);assert.deepEqual(options(),['beta'],'A healthy engine can still provide confirmed loaded models in a partial reply');
 snapshot=[];await w.refreshRouterModels();await delay(70);assert.deepEqual(options(),[]);assert($('chatSend').disabled,'Missing rows must not be reused from an older partial snapshot');
 snapshot=[{id:'beta',status:{value:'loaded'}}];
 incomplete=false;await w.refreshRouterModels();await delay(70);assert.deepEqual(options(),['beta']);
 state('LAST_STATUS.runtime_token="runtime-two"');C.syncLoadedModels();await delay(70);assert.deepEqual(options(),[],'Old-runtime model evidence is not reused');
 token='runtime-two';await w.refreshRouterModels();await delay(70);assert.deepEqual(options(),['beta']);
 $('chatInput').value='Hello';$('chatComposer').requestSubmit();await delay(150);assert.equal(C.controller.conversation.messages.at(-1).status,'complete');assert.equal(generationRequests,1);
 assert.match($('chatPerformance').textContent,/57\.8 tok\/s/);assert.match($('chatContext').textContent,/20 \/ 8192/);
 const response=w.document.querySelector('.chat-message.assistant');
 assert.equal(w.document.querySelectorAll('#chatDetailsToggle').length,1);assert.equal($('chatDetailsClose'),null);assert.equal(w.document.querySelector('.chat-toolbar #chatDetailsToggle'),null);
 assert.equal(response.querySelector('.chat-metrics details'),null,'No inline metrics disclosure remains');
 for(const action of ['Copy','Regenerate','Delete']){const button=response.querySelector('[data-chat-action="'+action+'"]');assert.equal(button.getAttribute('aria-label'),action);assert.equal(button.title,action);assert(button.querySelector('svg'));assert.equal(button.textContent,'','Icons replace visible action words')}
 $('chatDetailsToggle').click();await delay(60);assert($('chatInspectorContent').hidden);assert.equal($('chatDetailsToggle').textContent,'« Details');
 const link=response.querySelector('.chat-response-details');assert.equal(link.closest('.chat-metrics').hidden,false);link.click();await delay(60);
 assert.equal($('chatInspectorContent').hidden,false);assert.equal($('chatDetailsToggle').textContent,'Hide »');assert.equal($('chatPerformanceHeading').textContent,'Selected response');assert(link.closest('.chat-metrics').hidden,'Response link hides once the pane is open');
 assert.match($('chatMetricValues').textContent,/57.8/);
 // A selected older response keeps its own measurements when newer output arrives.
 const selectedID=C.controller.conversation.messages.at(-1).id;
 C.controller.conversation.messages.push(C.message('assistant','Newer response'));C.controller.conversation.messages.at(-1).metrics={generationTokensPerSecond:12.5,completionTokens:3};C.controller.notify();await delay(60);
 assert.match($('chatPerformance').textContent,/57\.8/);assert(!$("chatPerformance").textContent.includes('12.5'));
 $('chatDetailsToggle').click();await delay(60);$('chatDetailsToggle').click();await delay(60);assert.match($('chatPerformance').textContent,/12\.5/);assert.equal($('chatPerformanceHeading').textContent,'Last response');
 assert(C.controller.conversation.messages.some(message=>message.id===selectedID));

 assert.equal(JSON.stringify(await C.controller.store.load(C.controller.conversation.id)).includes('private-session-key'),false);
 state('LAST_STATUS.running=false');await w.refreshRouterModels();await delay(70);assert.deepEqual(options(),[]);assert($('chatSend').disabled);
 // New styling selectors are all rooted in Chat; shared style files are untouched.
 const studioCSS=fs.readFileSync(path.join(ui.root,'public/assets/css/chat.css'),'utf8').split('/* Studio is confined to Chat.')[1];
 const style=w.document.createElement('style');style.textContent=studioCSS.slice(studioCSS.indexOf('*/')+2);w.document.head.append(style);
 function scoped(rules){for(const rule of rules){if(rule.selectorText)for(const selector of rule.selectorText.split(','))assert(selector.trim().startsWith('#chatView'),'Studio styling is Chat-scoped');if(rule.cssRules)scoped(rule.cssRules)}}scoped(style.sheet.cssRules);
 assert.match(studioCSS,/#chatView #chatSend:not\(\.danger\)\{color:#11171b\}/,'Yellow Send text is explicitly dark; Stop retains danger styling');
 console.log('Chat Studio passed: inspector collapse/focus/persistence, loaded-only Router updates, stale/runtime guards, no implicit load, performance disclosure, key privacy and scoped styling');
}finally{clearTimeout(w.VisLlamaChat.controller?.persistTimer);dom.window.close()}})().catch(error=>{console.error(error);process.exitCode=1});
