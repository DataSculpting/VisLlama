// GPL-3.0-only. Thin mounted view: controller actions, normalized events and render services.
(()=>{
 const C=globalThis.VisLlamaChat,$=id=>document.getElementById(id);
 let controller,info=null,connectionSerial=0,drawTimer=null,initialized=false,listTimer=null,renderedConversation=null,observedRuntime=null,observedModels=null,inspectedMessageId=null;
 const notice=text=>{$('chatNotice').textContent=text;$('chatNotice').classList.toggle('hidden',!text)};
 const provider=()=>{if(!info?.available)throw new Error('Start Router or a direct server, then refresh the chat connection.');if(!loadedModels().some(m=>m.id===controller.conversation.model))throw new Error('Choose a currently loaded model before sending.');return new C.LlamaCppProvider({...info})};
 const key=()=>$('chatKey').value;
 const safely=async fn=>{try{notice('');await fn()}catch(e){notice(e.message)}};
 const busy=()=>!!controller?.active;
 // Validate a draft of settings before mutating the saved conversation.
 function settings(){const c=controller.conversation,outputLimit=$('chatOutputLimit').value,maxTokens=outputLimit==='cap'?Number($('chatMaxTokens').value):c.options.maxTokens,temperatureMode=$('chatTemperatureMode').value,temperature=temperatureMode==='override'?Number($('chatTemperature').value):c.options.temperature;if(!['model','override'].includes(temperatureMode)||!['available','cap'].includes(outputLimit)||!Number.isInteger(maxTokens)||maxTokens<1||maxTokens>2147483647||!Number.isFinite(temperature)||temperature<0||temperature>2)throw new Error('Choose valid output-token and temperature settings.');if($('chatModel').value)c.model=$('chatModel').value;c.system=$('chatSystem').value;Object.assign(c.options,{outputLimit,maxTokens,temperatureMode,temperature});syncOutputLimit()}
 function syncOutputLimit(){$('chatMaxTokens').disabled=busy()||$('chatOutputLimit').value!=='cap';$('chatTemperature').disabled=busy()||$('chatTemperatureMode').value!=='override'}
 function inputs(){const c=controller.conversation;$('chatSystem').value=c.system;$('chatOutputLimit').value=c.options.outputLimit||'cap';$('chatMaxTokens').value=c.options.maxTokens;$('chatTemperatureMode').value=c.options.temperatureMode||'override';$('chatTemperature').value=c.options.temperature;$('chatInput').value=c.draft||'';syncOutputLimit();models()}
 // The existing Router snapshot owns loaded state. Metadata/catalog membership
 // alone is not evidence that a model is loaded, and Chat never requests loading.
 function loadedModels(){
  if(!info?.available)return [];
  if(typeof CONTROL_POLL!=='undefined'&&CONTROL_POLL.offline)return [];
  if(LAST_STATUS&&!LAST_STATUS.running)return [];
  if(LAST_STATUS&&info.mode&&LAST_STATUS.mode!==info.mode)return [];
  if(info.mode!=='router')return info.models||[];
  if(!LAST_STATUS?.running||LAST_STATUS.mode!=='router'||!MODEL_STATUS_FETCHED||!observedModels)return [];
  if(LAST_STATUS.runtime_token&&observedRuntime!==LAST_STATUS.runtime_token)return [];
  // An incomplete multi-engine reply can still contain confirmed loaded rows
  // from healthy engines. Never fill missing rows from a previous snapshot.
  return observedModels.filter(m=>(m.status?.value||m.status)==='loaded'&&ROUTER_PRESETS.some(p=>p.alias===m.id));
 }
 function models(){
  const select=$('chatModel'),c=controller.conversation,choices=loadedModels();
  if(!c.model&&!busy())c.model=choices[0]?.id||'';
  const selected=choices.some(m=>m.id===c.model)?c.model:'',signature=JSON.stringify([choices.map(m=>m.id),selected]);
  // Avoid rebuilding an open native picker on every model-status poll.
  if(select.dataset.loadedSignature===signature)return;select.dataset.loadedSignature=signature;select.replaceChildren();
  if(!selected){const placeholder=document.createElement('option');placeholder.value='';placeholder.textContent=choices.length?'Select a loaded model':'No loaded models';placeholder.disabled=true;select.append(placeholder)}
  for(const m of choices){const option=document.createElement('option');option.value=m.id;option.textContent=m.id;select.append(option)}select.value=selected;
 }
 async function refresh(){const serial=++connectionSerial,model=controller.conversation.model;const result=await globalThis.post('/api/chat-info',{model},{busy:false});if(serial!==connectionSerial)return;info=result;let host=info.host||location.hostname;if(host==='0.0.0.0'||host==='::')host=location.hostname;if(host.includes(':')&&!host.startsWith('['))host='['+host+']';info.endpoint='http://'+host+':'+(info.port||8080);if(info.mode==='router'&&typeof refreshRouterModels==='function')await refreshRouterModels();if(serial!==connectionSerial)return;models();$('chatConnection').textContent=info.available?'Serving endpoint · '+info.endpoint:'Start Router to chat with your models';schedule();}
 function inspector(collapsed,save=false){
  const pane=$('chatInspectorContent');if(collapsed&&pane.contains(document.activeElement))$('chatDetailsToggle').focus();pane.hidden=collapsed;$('chatInspector').classList.toggle('collapsed',collapsed);$('chatShell').classList.toggle('inspector-collapsed',collapsed);$('chatDetailsToggle').setAttribute('aria-expanded',String(!collapsed));$('chatDetailsToggle').textContent=collapsed?'« Details':'Hide »';if(collapsed)inspectedMessageId=null;
  if(save)try{localStorage.setItem('visllama.chat.ui.v1.inspector-collapsed',String(collapsed))}catch{}
  if(controller)schedule();
 }
 function positionLatest(){const height=$('chatComposer').offsetHeight;if(height)$('chatLatest').style.bottom=(height+22)+'px'}
 function performanceDetails(m){
  const root=$('chatPerformance');root.replaceChildren();const add=(label,value)=>{const dt=document.createElement('dt'),dd=document.createElement('dd');dt.textContent=label;dd.textContent=value;root.append(dt,dd)};
  if(Number.isFinite(m.completionTokens))add('Output',m.completionTokens+' tokens');
  if(Number.isFinite(m.generationTokensPerSecond))add('Decode',m.generationTokensPerSecond.toFixed(1)+' tok/s'+(m.source?.generationSpeed==='client'?' (client estimate)':''));
  if(Number.isFinite(m.ttftMs))add('First token',Math.round(m.ttftMs)+' ms');
  if(Number.isFinite(m.prefillTokensPerSecond))add('Prefill',m.prefillTokensPerSecond.toFixed(1)+' tok/s');
  if(Number.isFinite(m.totalTimeMs))add('Elapsed',(m.totalTimeMs/1000).toFixed(2)+' s');
  if(Number.isFinite(m.contextPercent))add('Context',m.contextPercent.toFixed(1)+'%');
  if(!root.children.length)add('Measurements','No response measurements yet');
  $('chatMetricValues').textContent=JSON.stringify(m,null,2);$('chatRawMetrics').hidden=!Object.keys(m).length;
 }
 // Familiar symbols stay local to Chat. Accessible names also own action
 // identity; neither disabled-state logic nor tests depend on icon text.
 function actionIcon(label){
  const paths={Copy:'M9 8h11v13H9zM15 8V3H4v13h5',Regenerate:'M20 8a8 8 0 1 0 0 8M20 3v5h-5',Delete:'M4 6h16M9 6V3h6v3M6 6l1 15h10l1-15M10 10v7M14 10v7'},ns='http://www.w3.org/2000/svg';
  const svg=document.createElementNS(ns,'svg');svg.setAttribute('viewBox','0 0 24 24');svg.setAttribute('aria-hidden','true');svg.setAttribute('focusable','false');const path=document.createElementNS(ns,'path');path.setAttribute('d',paths[label]);svg.append(path);return svg;
 }
 function schedule(){if(!drawTimer)drawTimer=setTimeout(()=>{drawTimer=null;render()},40);clearTimeout(listTimer);listTimer=setTimeout(list,1200)}
 async function list(){try{const summaries=await controller.store.list(),root=$('chatConversations');root.replaceChildren();for(const item of summaries){const row=document.createElement('div');row.className='chat-conversation'+(item.id===controller.conversation.id?' selected':'');const open=document.createElement('button');open.type='button';open.textContent=item.title;open.title=item.title;open.onclick=()=>safely(async()=>{await controller.open(item.id);inputs();await refresh();render();await list()});const remove=document.createElement('button');remove.type='button';remove.textContent='×';remove.setAttribute('aria-label','Delete '+item.title);remove.onclick=()=>safely(async()=>{if(!confirm('Delete this saved conversation?'))return;const current=item.id===controller.conversation.id;if(current){controller.stop();clearTimeout(controller.persistTimer);controller.conversation=C.create()}await controller.store.delete(item.id);if(current){inputs();render()}await list()});row.append(open,remove);root.append(row)}}catch{notice('Saved conversations could not be read. Stored data has been retained.')}}
 function row(message){const article=document.createElement('article');article.className='chat-message '+message.role;article.dataset.messageId=message.id;const head=document.createElement('div');head.className='chat-message-head';const role=document.createElement('strong');role.textContent=message.role;const status=document.createElement('span');status.className='chat-message-state';const actions=document.createElement('div');actions.className='chat-message-actions';const action=(label,fn)=>{const b=document.createElement('button');b.type='button';b.dataset.chatAction=label;b.setAttribute('aria-label',label);if(['Copy','Regenerate','Delete'].includes(label)){b.className='chat-icon-action';b.title=label;b.append(actionIcon(label))}else b.textContent=label;b.onclick=()=>safely(fn);actions.append(b)};
  action('Copy',()=>navigator.clipboard.writeText(message.content));
  if(message.role==='user')action('Edit',()=>{const edit=document.createElement('textarea');edit.className='chat-message-edit';edit.rows=4;edit.value=message.content;const save=document.createElement('button');save.type='button';save.textContent='Save and regenerate';save.onclick=()=>safely(async()=>{if(!confirm('Replace this turn and remove all later messages?'))return;settings();const text=edit.value,p=provider();edit.remove();save.remove();cancel.remove();await controller.edit(message.id,text,p,key())});const cancel=document.createElement('button');cancel.type='button';cancel.textContent='Cancel edit';cancel.onclick=()=>{edit.remove();save.remove();cancel.remove()};if(!article.querySelector('.chat-message-edit')){article.append(edit,save,cancel);edit.focus()}});
  if(message.role==='assistant')action('Regenerate',async()=>{if(controller.conversation.messages.at(-1)?.id!==message.id&&!confirm('Regenerate this answer and remove all later messages?'))return;settings();await controller.regenerate(message.id,provider(),key())});
  action('Delete',()=>{if(confirm('Delete this message and all later messages?'))controller.remove(message.id)});head.append(role,status);
  const reasoning=document.createElement('details');reasoning.className='chat-reasoning hidden';const summary=document.createElement('summary');summary.textContent='Reasoning';const reasonBody=document.createElement('div');reasonBody.className='chat-markdown';reasoning.append(summary,reasonBody);
  const content=document.createElement('div');content.className='chat-markdown'+(message.role==='user'?' chat-user-text':'');const error=document.createElement('div');error.className='chat-message-error';const metrics=document.createElement('div');metrics.className='chat-metrics';const link=document.createElement('button');link.type='button';link.className='chat-response-details';link.textContent='Response details';link.onclick=()=>{inspectedMessageId=message.id;inspector(false,true);$('chatDetailsToggle').focus()};metrics.append(link);actions.append(metrics);article.append(head,reasoning,content,error,actions);return article;
 }
 function render(){if(!controller)return;const c=controller.conversation,root=$('chatMessages'),following=root.scrollHeight-root.scrollTop-root.clientHeight<70;
  if(renderedConversation!==c.id){root.replaceChildren();renderedConversation=c.id;inspectedMessageId=null}
  const wanted=new Set(c.messages.map(m=>m.id));for(const el of root.querySelectorAll('[data-message-id]'))if(!wanted.has(el.dataset.messageId))el.remove();root.querySelector('.chat-empty')?.remove();
  if(!c.messages.length){const empty=document.createElement('div');empty.className='chat-empty';empty.textContent='Choose a model and send a message. Conversations stay in this browser.';root.append(empty)}
  for(const m of c.messages){let el=[...root.children].find(e=>e.dataset.messageId===m.id);if(!el){el=row(m);root.append(el)}el.querySelector('.chat-message-state').textContent=C.limitNotice(m)?'Output limit reached':m.status;el.querySelectorAll('.chat-message-actions button').forEach(b=>b.disabled=busy()&&b.dataset.chatAction&&b.dataset.chatAction!=='Copy');const body=el.querySelector(':scope>.chat-markdown');if(body.dataset.raw!==m.content){if(m.role==='assistant')C.renderMarkdown(body,m.content);else body.textContent=m.content;body.dataset.raw=m.content}const reasoning=el.querySelector('.chat-reasoning');reasoning.classList.toggle('hidden',!m.reasoning);if(reasoning.dataset.raw!==m.reasoning){C.renderMarkdown(reasoning.querySelector('.chat-markdown'),m.reasoning||'');reasoning.dataset.raw=m.reasoning}const messageNotice=el.querySelector('.chat-message-error');messageNotice.textContent=m.error||C.limitNotice(m);messageNotice.classList.toggle('chat-limit-notice',!m.error&&!!C.limitNotice(m));el.querySelector('.chat-metrics').hidden=!$('chatInspectorContent').hidden||m.role!=='assistant'||!Object.keys(m.metrics||{}).length;}
  for(const id of ['chatModel','chatSystem','chatOutputLimit','chatTemperatureMode','chatRefresh'])$(id).disabled=busy();syncOutputLimit();$('chatSend').textContent=busy()?'Stop':'Send';$('chatSend').classList.toggle('danger',busy());$('chatSend').disabled=!busy()&&(!info?.available||!c.model||!loadedModels().some(m=>m.id===c.model));$('chatActivity').textContent=busy()?'Generating...':loadedModels().some(m=>m.id===c.model)?'Ready':'Choose a loaded model';
  const latest=[...c.messages].reverse().find(m=>m.role==='assistant'),selected=c.messages.find(m=>m.id===inspectedMessageId&&m.role==='assistant'),m=(selected||latest)?.metrics||{};$('chatPerformanceHeading').textContent=selected?'Selected response':'Last response';$('chatContext').textContent=m.contextPercent!==undefined?(selected?'Selected response: ':'Last generation: ')+m.tokensInContext+' / '+m.contextSize+' tokens ('+m.contextPercent.toFixed(1)+'% context)'+(m.contextPercent>=90?' · Near context limit; consider a new conversation.':''):(info?.context_size?'Server context window: '+info.context_size+' tokens':'Context usage will appear when the server supplies token counts and a context window.');$('chatContext').classList.toggle('warning',m.contextPercent>=90);
  performanceDetails(m);positionLatest();if(following)root.scrollTop=root.scrollHeight;$('chatLatest').classList.toggle('hidden',following);
 }
 async function mount(){if(initialized)return;initialized=true;let store;try{store=new C.BrowserStore()}catch{notice('Browser storage is unavailable. Export chats before leaving.');const data=new Map();store={save:async c=>data.set(c.id,structuredClone(c)),load:async id=>structuredClone(data.get(id)),list:async()=>[...data.values()],delete:async id=>data.delete(id)}}
  controller=new C.Controller(store,schedule,notice);C.controller=controller;
  let collapsed=globalThis.matchMedia?.('(max-width:850px)')?.matches||false;try{const saved=localStorage.getItem('visllama.chat.ui.v1.inspector-collapsed');if(saved!==null)collapsed=saved==='true'}catch{}inspector(collapsed);
  $('chatDetailsToggle').onclick=()=>inspector(!$('chatInspectorContent').hidden,true);
  if(typeof ResizeObserver==='function')new ResizeObserver(positionLatest).observe($('chatComposer'));
  try{const items=await store.list();if(items.length)controller.conversation=await store.load(items[0].id)}catch{notice('Saved conversations could not be loaded. Stored data has been retained.')}
  inputs();render();await list();
  $('chatNew').onclick=()=>safely(async()=>{await controller.fresh();inputs();render();await list();await refresh()});$('chatRefresh').onclick=()=>safely(refresh);$('chatModel').onchange=()=>safely(async()=>{settings();await controller.save();await refresh()});
  for(const id of ['chatSystem','chatOutputLimit','chatMaxTokens','chatTemperatureMode','chatTemperature'])$(id).onchange=()=>safely(()=>{settings();controller.notify()});
  $('chatInput').oninput=()=>{controller.conversation.draft=$('chatInput').value;controller.notify()};
  $('chatComposer').onsubmit=event=>{event.preventDefault();if(busy()){controller.stop();return}safely(async()=>{settings();const text=$('chatInput').value;if(!text.trim())return;const promise=controller.send(text,provider(),key());$('chatInput').value='';await promise;await list();if(!busy())await refresh()})};
  $('chatInput').onkeydown=event=>{if(event.key==='Enter'&&!event.shiftKey&&!event.isComposing){event.preventDefault();if(!busy())$('chatComposer').requestSubmit()}};
  $('chatMessages').onscroll=()=>{$('chatLatest').classList.toggle('hidden',$('chatMessages').scrollHeight-$('chatMessages').scrollTop-$('chatMessages').clientHeight<70)};$('chatLatest').onclick=()=>{$('chatMessages').scrollTop=$('chatMessages').scrollHeight;$('chatLatest').classList.add('hidden')};
  $('chatExport').onclick=()=>{const url=URL.createObjectURL(new Blob([JSON.stringify(controller.conversation,null,2)],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download='VisLlama-chat-'+controller.conversation.id+'.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000)};
  $('chatImport').onchange=()=>safely(async()=>{const file=$('chatImport').files[0];if(!file)return;if(file.size>5*1024*1024)throw new Error('Import is limited to 5 MiB.');let c;try{c=JSON.parse(await file.text())}catch{throw new Error('Choose a valid conversation JSON file.')}if(!C.validate(c))throw new Error('This file is not a supported VisLlama conversation.');controller.stop();await controller.save();c.id=C.id();for(const m of c.messages)if(['pending','streaming'].includes(m.status))m.status='aborted';controller.conversation=c;controller.notify();await controller.save();inputs();render();await list();await refresh();$('chatImport').value=''});
  addEventListener('pagehide',()=>{controller.stop();controller.save()});
 }
 C.open=async()=>{await mount();if(initialized)await safely(refresh)};
 // Status publishers call this after accepting their normal runtime-checked
 // snapshots. No new polling loop, engine probe or autoload path is introduced.
 C.syncLoadedModels=(token,data)=>{if(token===false)observedModels=null;else if(Array.isArray(data)){observedModels=data;observedRuntime=token||LAST_STATUS?.runtime_token||null}if(!controller)return;models();schedule()};
})();
