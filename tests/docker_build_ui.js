// Actual build-manager functions and templates with fixture transport; no layout/GPU.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),{JSDOM}=require('jsdom'),ui=require('./support/ui.cjs');
const dom=new JSDOM(ui.html(),{runScripts:'outside-only',pretendToBeVisual:true,url:'http://visllama.test/'}),w=dom.window,$=id=>w.document.getElementById(id),run=code=>vm.runInContext(code,dom.getInternalVMContext());
for(const name of ['state','core','navigation','builds','router'])run(fs.readFileSync(path.join(ui.root,'public/assets/js',name+'.js'),'utf8'));
w.loadHelp=w.loadDevices=async()=>{};w.updateCommand=()=>{};w.renderDevices=()=>{};w.toast=()=>{};w.confirm=()=>true;
w.syncEditorActions=()=>{};
const events=[];w.post=async(url,body)=>{events.push({url,body});if(url==='/api/build-save')return {builds:[{name:body.alias,type:'docker',image:body.image,available:true,exe:'docker://'+body.image}]};if(url==='/api/build-delete')return {builds:[]};throw Error('Unexpected '+url)};
run("CFG={platform:'linux',builds:[],server_executable:'llama-server'};LAST_STATUS={running:false};ROUTER_PRESETS=[]");
(async()=>{try{
 assert.equal($('toggleDockerBuilds').textContent,'Add Docker Images');assert.equal($('toggleDockerBuilds').nextElementSibling.dataset.closeModal,'buildManagerModal','Docker action is immediately left of Close');
 w.updateSetup();assert(run('SETUP_REQUIRED'));assert(!$('buildManagerModal').classList.contains('hidden'));assert($('buildManagerModal').querySelector('[data-close-modal]').classList.contains('hidden'));
 w.setBuildManagerDocker(true);assert.equal($('buildPathLabel').textContent,'Build image');assert($('browseBuildPath').classList.contains('hidden'));assert($('nativeBuildDiscovery').classList.contains('hidden'));assert(!$('dockerBuildNote').classList.contains('hidden'));
 $('buildAliasConfig').value='Spark';$('buildPathConfig').value='scitrera/dgx-spark-llama-cpp:latest';await w.saveConfiguredBuild();
 assert.equal(events[0].body.type,'docker');assert.equal(events[0].body.image,'scitrera/dgx-spark-llama-cpp:latest');assert.equal($('build').value,'Spark','Rest of UI selects Docker by alias');assert(!run('SETUP_REQUIRED'),'Docker-only setup is sufficient');assert($('buildManagerModal').classList.contains('hidden'));
 assert($('buildStatus').textContent.includes('Docker image:'));assert($('buildManager').textContent.includes('scitrera/'));
 $('buildManager').querySelector('[data-edit-build]').click();assert.equal($('buildAliasConfig').value,'Spark');assert.equal($('buildPathConfig').value,'scitrera/dgx-spark-llama-cpp:latest');assert.equal(run('EDITING_BUILD_ALIAS'),'Spark');
 run("ROUTER_PRESETS=[{alias:'Dependent model',build:'Spark'}]");const beforeDelete=events.length;$('buildManager').querySelector('[data-delete-build]').click();assert.equal(events.length,beforeDelete,'Referenced alias is not deleted');run('ROUTER_PRESETS=[]');
 $('buildManager').querySelector('[data-delete-build]').click();await new Promise(r=>setTimeout(r,10));assert(run('SETUP_REQUIRED'),'Removing final alias restores setup');assert(!$('buildManagerModal').classList.contains('hidden'));assert($('startBtn').disabled,'Start remains unavailable without an alias');
 run("CFG.builds=[{name:'Unavailable native',type:'native',available:false,dir:'/missing'}]");w.setBuildManagerDocker(false);w.updateSetup();assert(!run('SETUP_REQUIRED'),'Setup counts configured aliases rather than probe health');assert.equal($('buildPathLabel').textContent,'Build folder');assert(!$('browseBuildPath').classList.contains('hidden'));
 run("CFG.platform='windows'");w.setBuildManagerDocker(true);assert($('toggleDockerBuilds').disabled);assert(!run('BUILD_MANAGER_DOCKER'),'Native Windows UI cannot add Docker images');
 console.log('Docker build UI passed: additive views, two fields, alias selection/editing, optional root and last-alias setup recovery');
}finally{dom.window.close()}})().catch(e=>{console.error(e);process.exitCode=1});
