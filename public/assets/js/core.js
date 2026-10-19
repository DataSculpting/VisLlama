// VisLlama: core. Loaded in the order declared in templates/partials/scripts.html.

// Shared browser transport and feedback. post() owns JSON/error handling;
// background polls and user actions choose whether the busy overlay is shown.

// Show the global busy overlay for explicit user actions.
function busyBegin(label='Working...'){if(BUSY_COUNT===0)BUSY_RETURN_FOCUS=document.activeElement;BUSY_COUNT++;$('busyTitle').textContent=label;$('busyDetail').textContent='Waiting for the local control service.';const overlay=$('busyOverlay');overlay.classList.remove('hidden');overlay.tabIndex=-1;syncModalLayers();overlay.focus({preventScroll:true})}

// Release one busy-overlay reference and hide it when all work is complete.
function busyEnd(){BUSY_COUNT=Math.max(0,BUSY_COUNT-1);if(BUSY_COUNT===0){$('busyOverlay').classList.add('hidden');syncModalLayers();if(BUSY_RETURN_FOCUS?.isConnected&&!BUSY_RETURN_FOCUS.disabled&&!BUSY_RETURN_FOCUS.closest('[inert]'))BUSY_RETURN_FOCUS.focus({preventScroll:true});BUSY_RETURN_FOCUS=null}}

// POST JSON to the local VisLlama control API with optional busy UI.
const REQUEST_TIMINGS=[];
let CANCELLABLE_ACTION=null;
// Shared read-poll recovery. Never retry a mutation or confuse HTTP busy with
// a missing control service. A page reload starts with a fresh connection state.
const CONTROL_POLL={offline:false,recovering:false,step:0,next:0,backoff:new Map()};
const CONTROL_RETRY_DELAYS=[5000,15000,30000,60000];
function controlPollNotice(text=''){
 let node=$('controlPollNotice');
 if(!node&&$('workspace')){node=document.createElement('div');node.id='controlPollNotice';node.className='warning';node.setAttribute('role','status');node.style.margin='8px 0';$('workspace').prepend(node)}
 if(node){if(node.textContent!==text)node.textContent=text;node.classList.toggle('hidden',!text)}
}
function pausedControlPoll(){const error=new Error('Live updates paused; retrying automatically.');error.pollPaused=true;return error}
async function post(path,data={},opts={}){
 const readPoll=opts.busy===false&&/^\/api\/(?:status|gpu-stats|model-stats|router-models|chat-info)$/.test(path);
 let recovery=false;
 if(readPoll){
  const retry=CONTROL_POLL.backoff.get(path);
  if(retry&&Date.now()<retry.next)throw pausedControlPoll();
  if(CONTROL_POLL.offline){
   if(path!=='/api/status'||CONTROL_POLL.recovering||Date.now()<CONTROL_POLL.next)throw pausedControlPoll();
   CONTROL_POLL.recovering=true;recovery=true;
  }
  if(/^\/api\/(?:gpu-stats|model-stats)$/.test(path)&&((typeof SERVER_ACTION_BUSY!=='undefined'&&SERVER_ACTION_BUSY)||(typeof MODEL_ACTION_PENDING!=='undefined'&&MODEL_ACTION_PENDING.size)||(typeof LAST_STATUS!=='undefined'&&LAST_STATUS?.active_operation)))throw pausedControlPoll();
 }
 if(/^\/api\/(?:start|stop|stop-compute|model-preflight|router-(?:load|unload|apply-config))$/.test(path)&&!Object.hasOwn(data,'runtime_token'))data={...data,runtime_token:LAST_STATUS?.runtime_token||CFG?.runtime_token};
 const cancellable=/^\/api\/(?:start|router-load|router-apply-config)$/.test(path);
 const actionId=cancellable?`${Date.now()}-${Math.random()}`:null;
 if(actionId)data={...data,action_id:actionId};
 const showBusy=opts.busy!==false,started=performance.now();
 if(showBusy)busyBegin(opts.label||'Working...');
 if(actionId){CANCELLABLE_ACTION=actionId;$('cancelOperation')?.classList.remove('hidden')}
 try{
  let r,text;
  try{r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(data)});text=await r.text()}
  catch(error){
   if(error instanceof TypeError){
    if(!CONTROL_POLL.offline){CONTROL_POLL.offline=true;CONTROL_POLL.step=0;CONTROL_POLL.next=Date.now()+CONTROL_RETRY_DELAYS[0]}
    else if(recovery){CONTROL_POLL.step=Math.min(CONTROL_POLL.step+1,CONTROL_RETRY_DELAYS.length-1);CONTROL_POLL.next=Date.now()+CONTROL_RETRY_DELAYS[CONTROL_POLL.step]}
    controlPollNotice('Control service unavailable. Live readings are stale; reconnecting automatically.');globalThis.VisLlamaChat?.syncLoadedModels?.();error.controlTransportFailure=true;
   }
   throw error;
  }
  if(readPoll&&r.status===409){const prior=CONTROL_POLL.backoff.get(path),step=prior?Math.min(prior.step+1,CONTROL_RETRY_DELAYS.length-1):0;CONTROL_POLL.backoff.set(path,{step,next:Date.now()+CONTROL_RETRY_DELAYS[step]})}
  else if(readPoll&&r.ok)CONTROL_POLL.backoff.delete(path);
  let j;try{j=JSON.parse(text)}catch(_){throw new Error(`Invalid response from control service (${r.status})`)}
  if(path==='/api/status'&&r.ok&&j.ok){CONTROL_POLL.offline=false;CONTROL_POLL.step=0;CONTROL_POLL.next=0;controlPollNotice()}
  const elapsed=Math.round(performance.now()-started);
  REQUEST_TIMINGS.push({path,round_trip_ms:elapsed,handler_ms:j.server_elapsed_ms??null,queue_and_network_ms:j.server_elapsed_ms===undefined?null:Math.max(0,elapsed-j.server_elapsed_ms)});
  if(REQUEST_TIMINGS.length>50)REQUEST_TIMINGS.shift();
  if(!j.ok){const error=new Error((j.error||'Request failed')+(j.error_ref?' Reference: '+j.error_ref:''));error.httpStatus=r.status;throw error}return j
 }finally{
  if(recovery)CONTROL_POLL.recovering=false;
  if(CANCELLABLE_ACTION===actionId){CANCELLABLE_ACTION=null;$('cancelOperation')?.classList.add('hidden')}
  if(showBusy)busyEnd()
 }
}
async function cancelCurrentOperation(){
 const action=CANCELLABLE_ACTION;if(!action)return;
 const button=$('cancelOperation');button.disabled=true;
 try{
  const status=await post('/api/status',{}, {busy:false});
  if(status.active_operation?.id!==action)throw new Error('The operation has finished or changed. Refresh status before stopping.');
  await post('/api/stop',{runtime_token:status.runtime_token,cancel_operation:action},{busy:false});
  toast('Operation cancelled; managed Router processes stopped.');
 }catch(e){toast(e.message,true)}finally{button.disabled=false}
}

// Show a short success/error notification.
function toast(msg,bad=false){const t=$('toast');t.textContent=msg;t.className='toast'+(bad?' error':'');t.style.display='block';setTimeout(()=>t.style.display='none',4500)}

// Escape untrusted text before inserting it into generated HTML fragments.
function esc(s){return String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}

// Quote one displayed command argument; this preview is not a shell executor.
function q(s){s=String(s);if(CFG?.platform==='linux')return /^[A-Za-z0-9_./:@%+=,-]+$/.test(s)?s:"'"+s.replace(/'/g,"'\"'\"'")+"'";return /[\s"]/g.test(s)?'"'+s.replace(/"/g,'\\"')+'"':s}
