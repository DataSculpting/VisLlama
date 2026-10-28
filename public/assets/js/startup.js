// VisLlama: startup. Loaded in the order declared in templates/partials/scripts.html.

// Wire existing DOM nodes after all classic scripts have loaded. Event
// handlers share state.js; do not add async/defer reordering to script declarations.

$('cancelOperation').onclick=cancelCurrentOperation;

$('dashModels').addEventListener('click',event=>{const button=event.target.closest('[data-dash-model]');if(button&&!button.disabled)routerAction(button.dataset.dashAction,button.dataset.dashModel)});

// Load durable configuration, mount shared controls and bind page actions.
// Capture new-model defaults before loading a preset; Router settings load separately.
async function init(){try{initInstrument();CFG=await post('/api/config');MODELS=CFG.models;ROUTER_PRESETS=CFG.router_presets||[];$('rootPill').textContent=CFG.model_root||'Model root not set';$('modelRootPath').value=CFG.model_root||'';$('modelRootConfigPath').textContent='Config: '+(CFG.model_root_config_file||'');$('buildConfigPath').textContent='Config: '+(CFG.build_config_file||'');$('discoveryRoot').value=CFG.discovery_root||'';$('setupModelRoot').value=CFG.model_root||'';$('discoveryConfigPath').textContent='Discovery root config: '+(CFG.discovery_config_file||'');const rs=CFG.router_service||{};$('routerHost').value=rs.host||'0.0.0.0';$('routerPort').value=rs.port||8080;$('routerMax').value=rs.models_max??4;$('routerThreadsHttp').value=rs.threads_http??'';$('routerAutoload').checked=rs.autoload!==false;$('routerSettingsPath').textContent='Config: '+(CFG.router_service_file||'');const preferred=CFG.builds.find(b=>b.available)||CFG.builds[0];renderBuildSelector(preferred?.name);setBuildManagerDocker(false);rebuildHierarchy();ensureAlias();renderRouterPresets();$('routerPresetPath').textContent='Catalog: '+(CFG.router_json||'')+'; build-specific Router INIs are kept synchronized; Apply config reloads them into running build engines when possible.';decorateHelp();initHelpTooltips();syncSpecUi();$('serverMode').value='router';syncMode();mountRouterView();syncSettingsView();syncStatsView();syncLogView();renderModelLibrary();const identityGrid=$('editorIdentityGrid');if(identityGrid){if($('singleAliasField')&&!identityGrid.contains($('singleAliasField')))identityGrid.appendChild($('singleAliasField'));if($('singleBuildField')&&!identityGrid.contains($('singleBuildField')))identityGrid.appendChild($('singleBuildField'));}if($('editorMount')&&$('singlePane')&&!$('editorMount').contains($('singlePane')))$('editorMount').appendChild($('singlePane'));$('singlePane').classList.add('hidden');modelEditorMount();document.querySelectorAll('.nav-button').forEach(b=>b.onclick=()=>showView(b.dataset.view));$('dashRouter').onclick=()=>showView('router');$('dashManageModels').onclick=()=>showView('models');$('routerManageModels').onclick=()=>showView('models');$('routerManageModelsTable').onclick=()=>showView('models');$('settingsManageModels').onclick=()=>showView('models');$('dashHardwareDetails').onclick=()=>showView('stats');$('dashFullActivity').onclick=()=>showView('logs');$('refreshModelStats').onclick=refreshModelStats;for(const id of ['modelStatsRange','modelStatsGroup','modelStatsMetric'])$(id).onchange=renderModelStats;$('modelStatsConfig').onchange=()=>{MODEL_STATS_CONFIG=$('modelStatsConfig').value;renderModelStats()};$('headerStats').onclick=()=>showView('stats');$('headerSettings').onclick=()=>showView('settings');$('dashOpenLogs').onclick=()=>showView('logs');$('dashAddModel').onclick=()=>showView('models');$('newModelEditor').onclick=()=>newModelInDrawer().catch(e=>toast(e.message,true));$('editorClose').onclick=closeEditor;$('editorSave').onclick=()=>saveEditorPreset(false);$('editorSaveReload').onclick=()=>saveEditorPreset(true);$('dashStopCompute').onclick=()=>$('stopComputeBtn').click();$('dashClearLog').onclick=()=>$('clearLog').click();if($('routerSearch'))$('routerSearch').addEventListener('input',renderRouterPresets);if($('applyRouterConfig'))$('applyRouterConfig').onclick=async()=>{try{const j=await applyRouterConfig(false,true);toast(j.applied?'Router configuration applied live':'No Router changes applied')}catch(e){toast(e.message,true)}};showView('dashboard');updateSetup();if(CFG.builds.some(b=>b.available))await Promise.all([loadHelp(),loadDevices()]);await Promise.all([status(),refreshGpuStats(),refreshRouterModels()]);updateDashboard()}catch(e){toast(e.message,true)}}

// Dependent model controls reuse their existing serializers and preview updater.
$('specType').addEventListener('change',syncSpecUi);
$('draft').addEventListener('change',syncSpecUi);
bindModelFileRefresh();
$('ngramType').addEventListener('change',()=>syncNgramUi(true));

$('supplier').addEventListener('change',()=>{rebuildVariants();ensureAlias()});
$('variant').addEventListener('change',()=>{rebuildFiles();ensureAlias()});
$('model').addEventListener('change',()=>{if(!$('alias').dataset.userEdited){$('alias').value=deriveAlias()}updateCommand()});
$('alias').addEventListener('input',()=>{$('alias').dataset.userEdited='1';if($('alias').getAttribute('aria-invalid')==='true')validateAlias();updateCommand()});
$('serverMode').addEventListener('change',syncMode);
$('gpuPriority').addEventListener('change',updateCommand);
$('build').addEventListener('change',()=>{syncBuildStatus();loadHelp();loadDevices();updateCommand();if(typeof modelEditorSelectNative==='function')modelEditorSelectNative()});

$('browseModelRoot').onclick=()=>browseFolderInto('modelRootPath','Select GGUF model root',$('modelRootPath').value);

$('saveModelRoot').onclick=async()=>{try{await saveModelRootValue($('modelRootPath').value)}catch(e){toast(e.message,true)}};

$ ('toggleDockerBuilds').onclick=()=>setBuildManagerDocker(!BUILD_MANAGER_DOCKER);
$('browseBuildPath').onclick=()=>browseFolderInto('buildPathConfig','Select llama.cpp build folder',$('buildPathConfig').value||$('discoveryRoot').value);

$('browseChatTemplate').onclick=()=>browseFileInto('chatTemplateFile','Select custom chat template',$('chatTemplateFile').value||CFG?.model_root||'');
$('clearChatTemplate').onclick=()=>{$('chatTemplateFile').value='';updateCommand()};

$('browseSetupModelRoot').onclick=()=>browseFolderInto('setupModelRoot','Select GGUF model root',$('setupModelRoot').value);
$('saveSetupModelRoot').onclick=async()=>{try{await saveModelRootValue($('setupModelRoot').value)}catch(e){toast(e.message,true)}};
$('openBuildManager').onclick=()=>{renderBuildManager();openModal('buildManagerModal')};
$('browseDiscoveryRoot').onclick=()=>browseFolderInto('discoveryRoot','Select build discovery root',$('discoveryRoot').value);
$('scanDiscovery').onclick=scanBuildRoot;

document.querySelectorAll('[data-close-modal]').forEach(btn=>btn.onclick=()=>closeModal(btn.dataset.closeModal));

$('folderRootsBtn').onclick=()=>loadFolderBrowser('');
$('folderUpBtn').onclick=()=>loadFolderBrowser(FOLDER_BROWSER_PARENT||'');
$('folderUseBtn').onclick=async()=>{const target=FOLDER_BROWSER_TARGET,path=FOLDER_BROWSER_PATH;if(target&&path&&$(target)){$(target).value=path;if($(target).hasAttribute('data-engine-library-row'))$(target).dispatchEvent(new Event('change'));}closeModal('folderBrowserModal');if(path&&(target==='modelRootPath'||target==='setupModelRoot')){try{await saveModelRootValue(path)}catch(e){toast(e.message,true)}}};

document.querySelectorAll('.modal-overlay').forEach(m=>m.addEventListener('mousedown',e=>{if(e.target===m)closeModal(m.id)}));

$('clearBuildEditor').onclick=clearBuildEditor;

$('saveBuildConfig').onclick=saveConfiguredBuild;

document.addEventListener('input',e=>{if(['routerHost','routerPort','routerMax','routerThreadsHttp'].includes(e.target.id))syncRouterSettingsDirty();if(e.target.id==='routerHost')ROUTER_HOST_DIRTY=true;if(e.target.id==='routerPort')ROUTER_PORT_DIRTY=true;if(e.target.closest('#friendly')||e.target.closest('#routerPane'))updateCommand()});
document.querySelectorAll('.tab').forEach(t=>t.onclick=()=>{document.querySelectorAll('.tab').forEach(x=>x.classList.remove('active'));t.classList.add('active');$('friendly').classList.toggle('hidden',t.dataset.tab!=='friendly');$('all').classList.toggle('hidden',t.dataset.tab!=='all')});

$('optSearch').addEventListener('input',filterBuildOptions);
$('reloadHelp').onclick=loadHelp;
$('refreshDevices').onclick=()=>{PRIORITY_PREVIEW_KEY='';loadDevices(selectedDevices())};
$('refreshModels').onclick=async()=>{try{await refreshModelFileChoices();toast('Model list refreshed')}catch(e){toast(e.message,true)}};

$('routerAutoload').addEventListener('change',syncRouterSettingsDirty);
$('saveRouterSettings').onclick=async()=>{try{await saveRouterSettings(true)}catch(e){toast(e.message,true)}};

$('startBtn').onclick=async()=>{if(SERVER_ACTION_BUSY)return;if(APP_VIEW==='settings'&&routerSettingsDirty()){toast('Save Router settings before starting.',true);$('saveRouterSettings').focus();return}const router=$('serverMode').value==='router';const problem=router?'':validateConfig();if(problem){toast(problem,true);return}SERVER_ACTION_BUSY=true;syncServerButtons();try{const payload=router?{mode:'router'}:{mode:'single',build:$('build').value,model:selectedModel(),alias:$('alias').value.trim(),args:args(),gpu_priority:$('gpuPriority').value,gpu_devices:selectedDevices(),gpu_reserve:$('gpuReserve').value,gpu_settings:presetData()};const j=await post('/api/start',payload);LAST_STATUS=j;if(!j.running){toast(`llama-server exited during startup (code ${j.last_exit_code??'unknown'})`,true)}else if(j.mode==='router'&&j.last_error){toast('Router started, but a startup model failed. Open Logs / Diagnostics for details.',true)}else{toast(j.mode==='router'?`Started ${(j.router_engines||[]).filter(e=>e.running).length} Router engine(s)`:`Started PID ${j.pid}`)}}catch(e){toast(e.message,true)}finally{SERVER_ACTION_BUSY=false;await status(true);await refreshRouterModels(true);syncServerButtons()}};
$('stopBtn').onclick=async()=>{if(SERVER_ACTION_BUSY)return;SERVER_ACTION_BUSY=true;syncServerButtons();try{await post('/api/stop');toast(LAST_STATUS?.mode==='router'?'Router stopped':'Direct server stopped')}catch(e){toast(e.message,true)}finally{SERVER_ACTION_BUSY=false;await status(true);await refreshRouterModels(true);syncServerButtons()}};
$('stopComputeBtn').onclick=async()=>{if(!confirm('Stop all active inference requests? Loaded Router models will remain resident.'))return;try{const j=await post('/api/stop-compute',{}, {label:'Stopping active inference...'});toast(j.message||'Active inference stopped');await status(true)}catch(e){toast(e.message,true)}};
$('refreshStatus').onclick=async()=>{busyBegin('Refreshing status...');try{await Promise.all([status(true),refreshGpuStats(true)])}finally{busyEnd()}};
$('clearLog').onclick=async()=>{try{const j=await post('/api/clear-log',{}, {label:'Clearing log view...'});$('log').textContent='No log output since clear.';toast(j.message||'Log view cleared');await status(true)}catch(e){toast(e.message,true)}};
$('copyDiagnostics').onclick=async()=>{try{const j=LAST_STATUS||await post('/api/status');const text=['VisLlama diagnostics','Build: '+(j.build||''),'Model: '+(j.model||''),'Running: '+j.running,'PID: '+(j.pid||''),'Exit code: '+(j.last_exit_code??''),'Exit hex: '+(j.last_exit_hex||''),'Exit name: '+(j.last_exit_name||''),'Launcher exit: '+(j.wrapper_exit_code??''),'Exit time: '+(j.last_exit_time||''),'Command: '+(j.command||''),'Log: '+(j.log_file||''),'','Detected error:',''+diagnosticsError(j),'','Readiness:',JSON.stringify(j.readiness||{}),'','Server timings:',JSON.stringify(j.performance||{}),'','Recent browser timings:',JSON.stringify(REQUEST_TIMINGS),'','Log tail:',''+(j.log_tail||'')].join('\n');await navigator.clipboard.writeText(text);toast('Diagnostics copied to clipboard')}catch(e){toast('Could not copy diagnostics: '+e.message,true)}};
$('openServer').onclick=()=>showView('router');

$('saveRouterPreset').onclick=()=>saveEditorPreset(false);

$('refreshRouterPresets').onclick=refreshRouterPresets;
$('refreshRouterModels').onclick=refreshRouterModels;

// Browser working copies are separate from durable Router presets on the server.
$('savePreset').onclick=()=>{localStorage.setItem('llamaCppControlPreset',JSON.stringify(presetData()));toast('Preset saved in this browser')};
$('loadPreset').onclick=async()=>{const p=JSON.parse(localStorage.getItem('llamaCppControlPreset')||'null');if(!p)return toast('No saved preset',true);await applyUiPreset(p);refreshEditorPresentation();toast('Preset loaded')};
$('clearPreset').onclick=()=>{localStorage.removeItem('llamaCppControlPreset');toast('Preset cleared')};


const SPLASH_STARTED_AT=performance.now();

// Dismiss only after the minimum display period and readiness grace window.
// CSS owns the light motion; this function only coordinates splash lifetime.
function finishStartupSplash(){
 if(!SPLASH_MINIMUM_MET||SPLASH_DISMISSED||(!SPLASH_READY&&performance.now()-SPLASH_STARTED_AT<3850))return;
 SPLASH_DISMISSED=true;
 const splash=$('startupSplash');if(!splash)return;
 splash.classList.add('dismissed');setTimeout(()=>splash.remove(),250);
}

setTimeout(()=>{SPLASH_MINIMUM_MET=true;finishStartupSplash();setTimeout(finishStartupSplash,250)},3600);

// Background polling uses pending-action guards; do not let redraws interrupt
// an active row edit, device drag or model-order drag.
setInterval(()=>{if(!document.hidden||SERVER_ACTION_BUSY||MODEL_ACTION_PENDING.size)status()},2500);
setInterval(()=>{if(!document.hidden)refreshGpuStats()},2000);
setInterval(()=>{if(!document.hidden&&APP_VIEW==='modelStats')refreshModelStats()},30000);
setInterval(()=>{if((!document.hidden||MODEL_ACTION_PENDING.size)&&LAST_STATUS?.running&&LAST_STATUS.mode==='router')refreshRouterModels()},1500);
setInterval(()=>{if(LIVE_ROUTER_MODELS.some(m=>(m.status?.value||'')==='loading')){if(!routerInteractionActive())renderRouterPresets();updateDashboard()}},1000);

document.addEventListener('visibilitychange',()=>{if(!document.hidden){status(true);refreshGpuStats(true);if(LAST_STATUS?.running)refreshRouterModels(true)}});

init().finally(()=>{SPLASH_READY=true;finishStartupSplash()});
