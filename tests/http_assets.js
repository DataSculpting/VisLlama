// Real local Perl HTTP server, isolated installation and existing-config fixtures.
// Does not execute llama.cpp, PowerShell, or GPU probes.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const net = require('node:net');
const {spawn, spawnSync} = require('node:child_process');
const {once} = require('node:events');
const root = path.resolve(__dirname, '..');
const temporary = fs.mkdtempSync(path.join(__dirname, '.http-test-'));
const install = path.join(temporary, 'relocated application with spaces');
const cwd = path.join(temporary, 'unrelated working directory');
fs.mkdirSync(install); fs.mkdirSync(cwd);
for (const name of ['lib','templates','public','VisLlama.pl','llama_openai_proxy.pl']) {
  fs.cpSync(path.join(root,name), path.join(install,name), {recursive:true});
}
const presetDir = path.join(install,'presets');
fs.mkdirSync(presetDir);
const fixtures = {
  'llama-builds.json':[{alias:'Saved build',path:'C:\\Saved builds\\llama.cpp'}],
  'model-root.json':{model_root:'D:\\GGUF'},
  'build-discovery.json':{root:'C:\\Saved builds'},
  'router-service.json':{host:'192.168.6.39',port:18080,models_max:2,threads_http:'3',autoload:false},
  'router-presets.json':[
    {alias:'first',build:'Saved build',model:'D:\\GGUF\\first.gguf',enabled:false,load_on_startup:true,options:[],ui:{routerHost:'0.0.0.0'}},
    {alias:'second',build:'Saved build',model:'D:\\GGUF\\second.gguf',enabled:false,load_on_startup:false,options:[],ui:{custom:'retained'}}
  ],
};
const original = new Map();
for (const [name,obj] of Object.entries(fixtures)) {
  const content=JSON.stringify(obj,null,2)+'\n'; original.set(name,content);
  fs.writeFileSync(path.join(presetDir,name),content);
}
let child, port, output='';
const request = (method, url, body) => new Promise((resolve,reject)=>{
  const content=body===undefined?'':typeof body==='string'?body:JSON.stringify(body);
  const req=http.request({host:'127.0.0.1',port,path:url,method,headers:{'Content-Type':'application/json','Content-Length':Buffer.byteLength(content)}},res=>{
    const chunks=[];res.on('data',part=>chunks.push(part));res.on('end',()=>resolve({status:res.statusCode,headers:res.headers,body:Buffer.concat(chunks)}));
  });
  req.on('error',reject);req.setTimeout(5000,()=>req.destroy(new Error('HTTP test timeout')));req.end(content);
});
async function main(){try {
  const listener=net.createServer();listener.listen(0,'127.0.0.1');await once(listener,'listening');port=listener.address().port;
  listener.close();await once(listener,'close');
  const perl=process.env.PERL||'perl';
  for(const name of ['VisLlama.pl','llama_openai_proxy.pl']) {
    const check=spawnSync(perl,['-c',path.join(install,name)],{cwd,encoding:'utf8'});
    assert.equal(check.status,0,'Portable entry point: '+check.stderr);
  }
  // Only the in-memory test listen port differs; application file formats and
  // runtime paths are untouched. Execute the real App::run server loop.
  child=spawn(perl,['-I',path.join(install,'lib'),'-MVisLlama::App','-e',
    '$VisLlama::Context::CFG{listen_port}=shift @ARGV; exit VisLlama::App::run();',String(port)],{cwd});
  child.on('error',e=>{output+=e.message});
  child.stdout.on('data',b=>output+=b);child.stderr.on('data',b=>output+=b);
  let page;
  for(let i=0;i<80;i++) {
    try {page=await request('GET','/');break;} catch {await new Promise(r=>setTimeout(r,50));}
  }
  assert.ok(page,'Perl server started: '+output);assert.equal(page.status,200);
  const html=page.body.toString('utf8');assert.match(html,/<title>VisLlama 1\.5\.18<\/title>/);
  assert.equal(+page.headers['content-length'],page.body.length);
  assert.equal((await request('GET','/index.html')).body.toString(),html);
  const urls=[...new Set([...html.matchAll(/(?:src|href)="(\/assets\/[^"#]+)"/g)].map(m=>m[1]))];
  assert.ok(urls.length>=19,'All front-end files referenced by the renderer');
  for(const url of urls) {
    const response=await request('GET',url);assert.equal(response.status,200,url);
    if(/\.(js|css)(?:\?|$)/.test(url))assert.equal(response.headers['cache-control'],'no-cache','Code/style assets revalidate on reload');
    const file=path.join(install,'public',url.split('?')[0]);
    assert.deepEqual(response.body,fs.readFileSync(file),'Exact bytes: '+url);
    assert.equal(+response.headers['content-length'],response.body.length);
    assert.match(response.headers['content-type'],url.includes('/css/')?/^text\/css/:url.includes('/js/')?/^text\/javascript/:/^image\//);
  }
  for(const name of ['favicon.png','favicon.ico','visllama-logo-large.png','visllama-logo.svg','datasculpting-logo-ico.png']) {
    assert.deepEqual((await request('GET','/'+name)).body,(await request('GET','/assets/img/'+name)).body,'Legacy image URL: '+name);
  }
  for(const url of ['/VisLlama.pl','/llama_openai_proxy.pl','/lib/VisLlama/Context.pm','/templates/app.html','/presets/router-service.json','/logs/model-stats.jsonl','/public/assets/css/base.css','/assets/../templates/app.html','/assets/css/../../lib/VisLlama/App.pm','/assets/%2e%2e/templates/app.html','/assets/css%2fbase.css','/assets/css\\base.css','/assets/css/','/assets/css/missing.css']) {
    const response=await request('GET',url);assert.equal(response.status,404,'Private/invalid path: '+url);
    assert.doesNotMatch(response.body.toString(),/\b(?:line \d+|package VisLlama|listen_port)\b/);
  }
  // Check real-path containment as well as URL validation (symlinks may require
  // elevated privileges on Windows, so only this case is skipped if unavailable).
  const link=path.join(install,'public/assets/css/escape.css');
  try {fs.symlinkSync(path.join(presetDir,'router-service.json'),link);} catch(e) {if(!['EPERM','EACCES','ENOSYS'].includes(e.code))throw e;}
  if(fs.existsSync(link))assert.equal((await request('GET','/assets/css/escape.css')).status,404);
  const config=JSON.parse((await request('POST','/api/config',{})).body);
  assert.equal(config.app_version,'1.5.18');assert.deepEqual(config.router_service,fixtures['router-service.json']);
  assert.equal(config.builds[0].name,'Saved build');assert.equal(config.model_root,'D:\\GGUF');
  assert.equal(config.build_config_file,path.join(presetDir,'llama-builds.json'));
  assert.equal(config.router_presets[1].ui.custom,'retained');
  const status=JSON.parse((await request('POST','/api/status',{})).body);assert.equal(status.running,false);
  for(const [name,content] of original)assert.equal(fs.readFileSync(path.join(presetDir,name),'utf8'),content,'Read-only startup preserves '+name);
  assert.equal((await request('POST','/api/config','{invalid')).status,400);
  assert.equal((await request('POST','/api/not-a-route',{})).status,404);
  const badAlias=await request('POST','/api/router-preset-save',{alias:'Model (test)'});
  assert.equal(badAlias.status,400);assert.match(JSON.parse(badAlias.body).error,/Alias may contain only/);
  const order=JSON.parse((await request('POST','/api/router-preset-order',{aliases:['second','first']})).body);
  assert.deepEqual(order.presets.map(p=>p.alias),['second','first']);
  assert.equal(JSON.parse(fs.readFileSync(path.join(presetDir,'router-presets.json')))[0].ui.custom,'retained');
  assert.equal(fs.readFileSync(path.join(presetDir,'router-service.json'),'utf8'),original.get('router-service.json'));
  const changed={host:'127.0.0.2',port:19080,models_max:3,threads_http:'2',autoload:true};
  const saved=JSON.parse((await request('POST','/api/router-settings-save',changed)).body);
  assert.deepEqual(saved.router_service,changed);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(presetDir,'router-service.json'))),changed);
  assert.equal(fs.existsSync(path.join(cwd,'presets')),false,'No files written relative to working directory');
  const truncated=await new Promise((resolve,reject)=>{
    const socket=net.connect(port,'127.0.0.1');let data='';
    socket.on('connect',()=>socket.end('POST /api/router-settings-save HTTP/1.1\r\nHost: localhost\r\nContent-Length: 50\r\n\r\n{}'));
    socket.on('data',chunk=>data+=chunk);socket.on('end',()=>resolve(data));socket.on('error',reject);
    socket.setTimeout(5000,()=>socket.destroy(new Error('Truncated request did not complete')));
  });
  assert.match(truncated,/HTTP\/1\.1 400/);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(presetDir,'router-service.json'))),changed,'Truncated request never reaches settings save');
  // Native filesystem failure: preserve diagnostics privately, return only a
  // safe message/reference, and continue serving the next control request.
  const serviceFile=path.join(presetDir,'router-service.json');
  fs.unlinkSync(serviceFile);fs.mkdirSync(serviceFile);
  const failed=await request('POST','/api/router-settings-save',changed);
  const failure=JSON.parse(failed.body);assert.equal(failure.ok,false);
  assert.match(failure.error_ref,/^VL-[a-f0-9]{20}$/);
  assert(!failed.body.toString().includes(install));
  assert.doesNotMatch(failed.body.toString(),/Config\.pm|line \d+|Cannot write/);
  const logs=path.join(install,'logs');
  const diagnostic=fs.readdirSync(logs).find(n=>n.startsWith('diagnostics-'));
  assert(fs.readFileSync(path.join(logs,diagnostic),'utf8').includes(failure.error_ref));
  assert.equal((await request('GET','/logs/'+diagnostic)).status,404);
  fs.rmSync(serviceFile,{recursive:true});fs.writeFileSync(serviceFile,JSON.stringify(changed));
  // A missing page template exercises App's outer exception catch as well.
  const template=path.join(install,'templates/app.html');fs.renameSync(template,template+'.held');
  const pageFailure=await request('GET','/');assert.equal(pageFailure.status,500);
  assert.doesNotMatch(pageFailure.body.toString(),/Template\.pm|line \d+/);
  fs.renameSync(template+'.held',template);
  assert.equal((await request('POST','/api/status',{})).status,200);
  if(process.platform!=='win32') {
    const exited=once(child,'exit');child.kill('SIGINT');const [code]=await exited;
    assert.equal(code,0,'SIGINT exits the real control loop cleanly');assert.match(output,/Stopped\./);
  }
  console.log('HTTP/assets, private paths, relocated installation, saved configuration and API dispatch passed');
} finally {
  if(child&&child.exitCode===null&&child.signalCode===null){const exited=once(child,'exit');child.kill();await exited;}
  fs.rmSync(temporary,{recursive:true,force:true});
}}
main().catch(e=>{console.error(e);process.exitCode=1});
