// Exercise the real public proxy against a loopback-only mock inference engine.
// A relocated copy keeps logs/configuration entirely inside a temporary fixture.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const http=require('node:http'),net=require('node:net'),assert=require('node:assert/strict');
const {spawn}=require('node:child_process');
const root=path.resolve(__dirname,'..'),temp=fs.mkdtempSync(path.join(fs.existsSync(os.tmpdir())?os.tmpdir():root,'visllama-privacy-'));
const sentinel='PRIVATE_BACKEND_SENTINEL',detail='Failure '+sentinel+' C:\\secret\\handler.pm line 99 token=hidden-token';
let mode='success',proxy,server,rawServer,rawPort;
const listen=s=>new Promise(r=>s.listen(0,'127.0.0.1',()=>r(s.address().port)));
const close=s=>new Promise(r=>s.close(r));
const delay=ms=>new Promise(r=>setTimeout(r,ms));
async function main(){try{
 fs.cpSync(path.join(root,'lib'),path.join(temp,'lib'),{recursive:true});fs.copyFileSync(path.join(root,'llama_openai_proxy.pl'),path.join(temp,'llama_openai_proxy.pl'));
 const routes=path.join(temp,'routes.json');
 server=http.createServer((req,res)=>{
  req.resume();res.setHeader('X-Internal-Path',detail);
  res.setHeader('Access-Control-Allow-Origin',mode==='origin-mismatch'?'http://private/'+sentinel:'https://chat.example');
  res.setHeader('Access-Control-Allow-Methods','POST, OPTIONS');res.setHeader('Access-Control-Allow-Headers','Authorization, Content-Type, '+sentinel);
  if(req.method==='OPTIONS'){res.writeHead(204);res.end();return;}
  if(req.url==='/api/router-ensure-load' && mode==='controller-ok'){res.setHeader('Content-Type','application/json');res.end('{"ok":true}');return;}
  if(req.url==='/api/router-ensure-load' && mode==='controller-false'){res.setHeader('Content-Type','application/json');res.end(JSON.stringify({ok:false,error:detail}));return;}
  if(req.url==='/v1/models'){res.setHeader('Content-Type','application/json');res.end(JSON.stringify({data:[{id:'model',owned_by:detail,debug:detail,status:{error:detail}}]}));return;}
  if(mode==='error'){res.writeHead(500,detail,{'Content-Type':'text/html','Set-Cookie':sentinel,'Location':'http://private/'+sentinel});res.end('<html>'+detail+'</html>');return;}
  if(mode==='chunked-error'){res.writeHead(400,{'Content-Type':'application/json'});res.write('{"error":"'+detail.replaceAll('\\','\\\\'));res.end('"}');return;}
  if(mode==='json-error'){res.setHeader('Content-Type','application/json');res.end(JSON.stringify({error:{message:detail,stack:detail}}));return;}
  if(mode==='invalid-json'){res.setHeader('Content-Type','application/json');res.end(detail);return;}
  if(mode==='sse'||mode==='sse-error'||mode==='sse-bad'||mode==='named-error'){
   res.writeHead(200,{'Content-Type':'text/event-stream'});
   res.write('data: '+JSON.stringify({choices:[{delta:{content:'Hello'}}]})+'\n\n');
   if(mode==='sse'){res.end('data: [DONE]\n\n');return;}
   const event=mode==='sse-bad'?'data: '+detail+'\n\n':(mode==='named-error'?'event: error\n':'')+'data: '+JSON.stringify({error:{message:detail}})+'\n\n';
   res.write(event.slice(0,13));setTimeout(()=>res.end(event.slice(13)),20);return;
  }
  if(mode==='binary'){res.writeHead(200,{'Content-Type':'audio/wav'});res.end(Buffer.from([0,1,2,255]));return;}
  res.setHeader('Content-Type','application/json');res.end(JSON.stringify({error:null,choices:[{message:{content:'Valid answer containing /a/path and the word error'}}]}));
 });
 const backendPort=await listen(server);
 const probe=net.createServer();const port=await listen(probe);await close(probe);
 const map={models:{model:{host:'127.0.0.1',port:backendPort}},backends:[{host:'127.0.0.1',port:backendPort}]};
 const writeMap=()=>fs.writeFileSync(routes,JSON.stringify(map));writeMap();
 proxy=spawn('perl',[path.join(temp,'llama_openai_proxy.pl'),'--listen-host','127.0.0.1','--listen-port',String(port),'--route-map',routes],{stdio:'ignore',env:{...process.env,http_proxy:'http://127.0.0.1:1',HTTP_PROXY:'http://127.0.0.1:1',all_proxy:'http://127.0.0.1:1',ALL_PROXY:'http://127.0.0.1:1',no_proxy:'',NO_PROXY:''}});
 const request=()=>fetch('http://127.0.0.1:'+port+'/v1/chat/completions',{method:'POST',headers:{'Content-Type':'application/json',Origin:'https://chat.example'},body:'{"model":"model"}',signal:AbortSignal.timeout(5000)});
 for(let n=0;;n++){try{await (await request()).text();break}catch(e){if(n>60)throw e;await delay(40)}}
 let response=await request(),body=await response.text();assert.match(body,/Valid answer containing \/a\/path/);assert.equal(response.headers.get('x-internal-path'),null,'Debug headers removed from success');
 assert.equal(response.headers.get('access-control-allow-origin'),'https://chat.example');
 response=await fetch('http://127.0.0.1:'+port+'/v1/chat/completions',{method:'OPTIONS',headers:{Origin:'https://chat.example'}});assert.equal(response.status,204);assert.equal(response.headers.get('access-control-allow-methods'),'POST, OPTIONS');assert.equal(response.headers.get('access-control-allow-headers'),'Authorization, Content-Type');
 mode='origin-mismatch';response=await request();await response.text();assert.equal(response.headers.get('access-control-allow-origin'),null);mode='success';
 response=await fetch('http://127.0.0.1:'+port+'/v1/models');body=await response.text();assert.match(body,/"id":"model"/);assert(!body.includes(sentinel),'Model listing projects public metadata only');
 for(mode of ['error','chunked-error','json-error','invalid-json','sse-error','sse-bad','named-error']){
  response=await request();body=await response.text();
  assert(!body.includes(sentinel)&&!body.includes('handler.pm')&&!body.includes('hidden-token'),mode+' suppresses all raw detail');
  assert.match(body,/VL-[a-f0-9]{20}/,mode+' has diagnostic reference');
  assert.equal(response.headers.get('access-control-allow-origin'),'https://chat.example');
  assert.equal(response.headers.get('x-internal-path'),null);assert.equal(response.headers.get('set-cookie'),null);assert.equal(response.headers.get('location'),null);
  if(mode.startsWith('sse')||mode==='named-error')assert.match(body,/Hello/,'Successful earlier stream event survives');
 }
 mode='sse';response=await request();body=await response.text();assert.match(body,/Hello/);assert.match(body,/\[DONE\]/);
 mode='binary';response=await request();assert.deepEqual(Buffer.from(await response.arrayBuffer()),Buffer.from([0,1,2,255]));
 // A broken chunk after headers must emit an SSE error, not another HTTP header.
 rawServer=net.createServer(socket=>socket.once('data',()=>socket.end('HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\nZZBAD\r\n'+detail)));rawPort=await listen(rawServer);
 map.models.model.port=rawPort;writeMap();response=await request();body=await response.text();assert.match(body,/stream_error/);assert(!body.includes('HTTP/1.1'));assert(!body.includes(sentinel));
 map.models.model.port=backendPort;map.models.model.calculated=1;map.control={port:backendPort,token:'test-control-secret'};writeMap();mode='error';response=await request();body=await response.text();assert.equal(response.status,503);assert(!body.includes(sentinel));assert.match(body,/model_load_error/);
 mode='controller-false';response=await request();body=await response.text();assert.equal(response.status,503,'HTTP success must also confirm a successful model load');assert(!body.includes(sentinel));
 mode='controller-ok';response=await request();assert.equal(response.status,200,'Local model loader bypasses machine proxy settings');await response.text();
 delete map.models.model.calculated;delete map.control;writeMap();
 // Corrupt and missing route maps exercise both model-list and request catches.
 fs.writeFileSync(routes,'{"token":"hidden-token", BROKEN '+sentinel);
 response=await request();body=await response.text();assert(!body.includes(sentinel));assert(!body.includes('hidden-token'));assert.match(body,/VL-/);
 fs.unlinkSync(routes);response=await fetch('http://127.0.0.1:'+port+'/v1/models');body=await response.text();assert.equal(response.status,500);assert(!body.includes(temp));assert(!body.includes('Proxy.pm'));assert.match(body,/VL-/);
 writeMap();mode='success';response=await request();assert.equal(response.status,200,'Listener survives every failed request');await response.text();
 const records=fs.readdirSync(path.join(temp,'logs')).filter(n=>n.endsWith('.jsonl')).flatMap(n=>fs.readFileSync(path.join(temp,'logs',n),'utf8').trim().split('\n').map(JSON.parse));
 assert(records.some(r=>r.detail.includes(sentinel)),'Server-side diagnostics retain fault detail');assert(records.every(r=>!r.detail.includes('hidden-token')),'Credential assignment redacted from private records');
 console.log('Public proxy privacy passed: exceptions, backend HTTP/JSON/SSE errors, split/malformed framing, headers, private references and healthy responses');
}finally{
 if(proxy&&proxy.exitCode===null){proxy.kill();await new Promise(r=>proxy.once('exit',r));}
 if(server)await close(server);if(rawServer)await close(rawServer);fs.rmSync(temp,{recursive:true,force:true});
}}
main().catch(e=>{console.error(e);process.exitCode=1});
