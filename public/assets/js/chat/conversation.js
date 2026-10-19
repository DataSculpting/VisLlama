// GPL-3.0-only. Conversation identity and request semantics are independent of DOM/storage.
(()=>{
 const C=globalThis.VisLlamaChat=globalThis.VisLlamaChat||{};
 C.id=()=>crypto.randomUUID?crypto.randomUUID():`${Date.now()}-${Math.random().toString(16).slice(2)}`;
 C.create=()=>({schema:1,id:C.id(),title:'New conversation',createdAt:Date.now(),updatedAt:Date.now(),model:'',system:'',draft:'',options:{outputLimit:'available',maxTokens:8192,temperatureMode:'model',temperature:0.8},messages:[]});
 C.message=(role,content='')=>({id:C.id(),role,content,reasoning:'',createdAt:Date.now(),status:role==='assistant'?'pending':'complete',metrics:{}});
 // Missing outputLimit belongs to a legacy saved chat: retain its explicit cap.
 // Keep the saved 'available' mode identifier, but defer to native defaults.
 // Do not send a sentinel or estimate output limits from context size.
 C.limitNotice=m=>m.status==='complete'&&m.finishReason==='length'?'Output limit reached. The server ended this response at a token or context limit. Check the optional output cap and available context in Details.':'';
 // Omit temperature in model mode so the serving instance owns sampling defaults.
 // A legacy chat without temperatureMode retains its saved explicit override.
 C.buildRequest=c=>({model:c.model,stream:true,stream_options:{include_usage:true},messages:[...(c.system.trim()?[{role:'system',content:c.system}]:[]),...c.messages.filter(m=>['user','assistant'].includes(m.role)&&m.content&&m.status!=='pending'&&m.status!=='streaming').map(m=>({role:m.role,content:m.content}))],...(c.options.outputLimit==='available'?{}:{max_tokens:c.options.maxTokens}),...(c.options.temperatureMode==='model'?{}:{temperature:c.options.temperature})});
 C.validate=c=>c&&c.schema===1&&typeof c.id==='string'&&typeof c.title==='string'&&typeof c.model==='string'&&typeof c.system==='string'&&typeof c.draft==='string'&&Array.isArray(c.messages)&&new Set(c.messages.map(m=>m?.id)).size===c.messages.length&&c.messages.every(m=>m&&typeof m.id==='string'&&['user','assistant','system','tool'].includes(m.role)&&typeof m.content==='string'&&typeof(m.reasoning||'')==='string')&&c.options&&(c.options.outputLimit===undefined||['available','cap'].includes(c.options.outputLimit))&&Number.isInteger(c.options.maxTokens)&&c.options.maxTokens>0&&c.options.maxTokens<=2147483647&&(c.options.temperatureMode===undefined||['model','override'].includes(c.options.temperatureMode))&&Number.isFinite(c.options.temperature)&&c.options.temperature>=0&&c.options.temperature<=2;
 C.truncate=(c,id,include=false)=>{const i=c.messages.findIndex(m=>m.id===id);if(i<0)throw new Error('Message is no longer present.');c.messages.splice(i+(include?1:0));return i};
})();
