// GPL-3.0-only. Own generation/message identity, mutations and persistence cadence.
(()=>{
 const C=globalThis.VisLlamaChat;
 C.Controller=class{
  constructor(store,changed,notice){this.store=store;this.changed=changed;this.notice=notice;this.conversation=C.create();this.active=null;this.persistTimer=null;this.navSerial=0}
  notify(){this.conversation.updatedAt=Date.now();this.changed(this.conversation);if(!this.persistTimer)this.persistTimer=setTimeout(()=>{this.persistTimer=null;this.save()},1000)}
  async save(){clearTimeout(this.persistTimer);this.persistTimer=null;try{await this.store.save(this.conversation)}catch{this.notice('Chat could not be saved in this browser. Export it before leaving; storage may be full or disabled.')}}
  async open(id){const serial=++this.navSerial;this.stop();await this.save();const c=await this.store.load(id);if(serial!==this.navSerial)return;this.conversation=c||C.create();this.notify()}
  async fresh(){const serial=++this.navSerial;this.stop();await this.save();if(serial!==this.navSerial)return;this.conversation=C.create();this.notify()}
  stop(){const a=this.active;if(!a)return;this.active=null;a.abort.abort();a.message.status='aborted';a.message.metrics=a.metrics.finish();this.notify();this.save()}
  async generate(provider,key=''){
   if(this.active)throw new Error('Stop the current response first.');const c=this.conversation;
   const request=C.buildRequest(c);if(!request.model||!request.messages.some(m=>m.role==='user'))throw new Error('Choose a model and enter a message.');
   const message=C.message('assistant'),active={id:C.id(),message,abort:new AbortController(),metrics:new C.Metrics(provider.connection.context_size)};
   c.messages.push(message);this.active=active;this.notify();
   try{await provider.generate(request,event=>{
    if(this.active!==active||this.conversation!==c)return;
    if(event.type==='start')message.status='streaming';
    if(event.type==='content'||event.type==='reasoning'){active.metrics.token();const field=event.type==='reasoning'?'reasoning':'content';message[field]+=event.delta;if(message[field].length>2*1024*1024){this.stop();this.notice('Response size limit reached; partial output retained.');return}}
    if(event.type==='usage')message.metrics=active.metrics.update(event.value);
    if(event.type==='finish')message.finishReason=event.reason;
    this.notify();
   },active.abort.signal,key);
   if(this.active===active){message.status='complete';message.metrics=active.metrics.finish()}
   }catch(e){if(this.active===active){message.status=e.name==='AbortError'?'aborted':'error';message.metrics=active.metrics.finish();if(message.status==='error'){message.error=e instanceof TypeError?'Cannot reach the inference endpoint. Check Router, connection and browser access.':e.message;this.notice(message.error)}}}
   finally{if(this.active===active){this.active=null;this.notify();await this.save()}}
  }
  async send(text,provider,key){if(this.active)throw new Error('Stop the current response first.');if(!text.trim())return;const c=this.conversation;c.messages.push(C.message('user',text));c.draft='';if(c.title==='New conversation')c.title=text.trim().slice(0,60);return this.generate(provider,key)}
  async edit(id,text,provider,key){if(this.active)throw new Error('Stop the current response first.');const c=this.conversation,m=c.messages.find(m=>m.id===id);if(m?.role!=='user'||!text.trim())throw new Error('Enter a user message.');C.truncate(c,id,true);m.content=text;m.editedAt=Date.now();return this.generate(provider,key)}
  async regenerate(id,provider,key){if(this.active)throw new Error('Stop the current response first.');const m=this.conversation.messages.find(m=>m.id===id);if(m?.role!=='assistant')throw new Error('Choose an assistant response.');C.truncate(this.conversation,id);return this.generate(provider,key)}
  remove(id){if(this.active)throw new Error('Stop the current response first.');C.truncate(this.conversation,id);this.notify();this.save()}
 };
})();
