// Discovery failures and late replies must never erase an explicit saved GPU choice.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),{JSDOM}=require('jsdom'),ui=require('./support/ui.cjs');
const dom=new JSDOM(ui.html(),{runScripts:'outside-only',url:'http://localhost/'}),w=dom.window,$=id=>w.document.getElementById(id),ctx=dom.getInternalVMContext(),plain=x=>JSON.parse(JSON.stringify(x));
for(const name of ['state','core','arguments','editor'])vm.runInContext(fs.readFileSync(path.join(ui.root,'public/assets/js',name+'.js'),'utf8'),ctx);
w.updateCommand=()=>{};w.toast=()=>{};const queue=[];w.post=()=>new Promise((resolve,reject)=>queue.push({resolve,reject}));
(async()=>{try{
 $('build').innerHTML='<option>Build A</option><option>Build B</option>';
 const first=w.loadDevices(['CUDA1']);assert.deepEqual(plain(w.selectedDevices()),['CUDA1'],'Saved GPU survives while discovery is pending');queue[0].reject(Error('Controller busy'));await first;assert.deepEqual(plain(w.presetData().devices),['CUDA1'],'Failed discovery cannot turn saved selection into automatic placement');assert.equal($('device').querySelector('input').checked,true);assert.equal($('device').querySelector('input').disabled,true);
 const refreshed=w.loadDevices();queue[1].resolve({devices:[{id:'CUDA0',description:'First'},{id:'CUDA1',description:'Second'}],raw:'devices'});await refreshed;assert.deepEqual(plain(w.selectedDevices()),['CUDA1']);assert.equal($('device').querySelector('[value="CUDA1"]').disabled,false);
 const late=w.loadDevices();$('device').querySelector('[value="CUDA1"]').checked=false;$('device').querySelector('[value="CUDA0"]').checked=true;$('device').querySelector('[value="CUDA0"]').dispatchEvent(new w.Event('change'));queue[2].resolve({devices:[{id:'CUDA0',description:'First'},{id:'CUDA1',description:'Second'}]});await late;assert.deepEqual(plain(w.selectedDevices()),['CUDA0'],'Late refresh preserves the choice made while it was pending');
 const absent=w.loadDevices();queue[3].resolve({devices:[],raw:'temporarily empty'});await absent;assert.deepEqual(plain(w.selectedDevices()),['CUDA0'],'Empty discovery retains explicit selection as visibly unconfirmed');assert.equal($('device').querySelector('input').disabled,true);
 const fresh=w.loadDevices([]);queue[4].resolve({devices:[{id:'CUDA0',description:'First'}]});await fresh;assert.deepEqual(plain(w.selectedDevices()),[],'Explicit Add defaults still clear selection');
 console.log('GPU selection recovery passed: pending/error/empty discovery, refresh, user edits during refresh and clean Add defaults');
}finally{dom.window.close()}})().catch(e=>{console.error(e);process.exitCode=1});
