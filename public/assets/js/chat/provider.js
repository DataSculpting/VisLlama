// GPL-3.0-only. Initial OpenAI-compatible llama.cpp adapter. The view sees normalized events.
(()=>{
 const C=globalThis.VisLlamaChat;
 C.LlamaCppProvider=class{
  // Keep the browser fetch receiver when calling through this provider instance.
  constructor(connection,fetcher=(...args)=>globalThis.fetch(...args)){this.connection=connection;this.fetcher=fetcher}
  getCapabilities(){return {streaming:true,cancellation:true,usage:'optional',contextSize:!!this.connection.context_size,reasoning:'optional',prefillTiming:'optional',generationTiming:'optional'}}
  async generate(request,emit,signal,key=''){
   const headers={'Content-Type':'application/json'};if(key)headers.Authorization='Bearer '+key;
   const response=await this.fetcher(this.connection.endpoint+'/v1/chat/completions',{method:'POST',headers,body:JSON.stringify(request),signal,credentials:'omit'});
   const reference=j=>{const ref=j?.error?.reference||j?.error?.error_ref;return typeof ref==='string'&&/^VL-[A-Za-z0-9-]{1,80}$/.test(ref)?' Reference: '+ref:''};
   const overflow=j=>['context_size_exceeded','exceed_context_size_error','context_length_exceeded'].includes(j?.error?.type)||['context_size_exceeded','context_length_exceeded'].includes(j?.error?.code);
   const safeError=j=>(overflow(j)?'The conversation exceeds the model context window. Start a new conversation or shorten it.':'The inference server rejected or interrupted the request.')+reference(j);
   if(!response.ok){let j;try{j=await response.json()}catch{}const messages={400:'The inference server rejected this request. Check the context window and output-token limit, or start a new conversation.',401:'The inference server requires a valid API key.',403:'The inference server denied this request.',404:'The selected model or chat endpoint is unavailable.',413:'The conversation is too large for this request.',503:'The model or inference server is currently unavailable.'};throw new Error(overflow(j)?safeError(j):messages[response.status]?messages[response.status]+reference(j):safeError(j))}
   emit({type:'start'});let finished=false;
   const accept=j=>{if(!j||typeof j!=='object'||Array.isArray(j))throw new Error('Invalid streaming response.');if(j.error)throw new Error(safeError(j));if(!Array.isArray(j.choices)&&!j.usage&&!j.timings&&!j.generation_settings&&!j.context_size)throw new Error('Invalid chat response.');const choice=j.choices?.[0],delta=choice?.delta||choice?.message||{};const reasoning=delta.reasoning_content??delta.reasoning;if(typeof reasoning==='string'&&reasoning)emit({type:'reasoning',delta:reasoning});if(typeof delta.content==='string'&&delta.content)emit({type:'content',delta:delta.content});if(choice?.finish_reason){finished=true;emit({type:'finish',reason:choice.finish_reason})}if(j.usage||j.timings||j.generation_settings||j.context_size)emit({type:'usage',value:j});};
   if((response.headers.get('content-type')||'').includes('application/json')){const json=await response.json();if(!json?.choices?.[0]?.message)throw new Error('Invalid chat response.');accept(json);emit({type:'complete'});return}
   if(!(response.headers.get('content-type')||'').includes('text/event-stream')||!response.body)throw new Error('The server did not return a supported chat stream.');
   const parser=new C.SSEParser((text,event)=>{let j;try{j=JSON.parse(text)}catch{throw new Error('The server returned a malformed streaming event.')}if(event==='error')throw new Error(safeError(j));accept(j)}),reader=response.body.getReader();
   try{while(!parser.done){const {value,done}=await reader.read();if(signal.aborted)throw new DOMException('Stopped','AbortError');parser.push(value,done);if(done)break}if(!parser.done&&!finished)throw new Error('The stream ended before generation completed.');emit({type:'complete'})}finally{await reader.cancel().catch(()=>{});reader.releaseLock()}
  }
 };
})();
