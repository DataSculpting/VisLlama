// VisLlama: state. Loaded in the order declared in templates/partials/scripts.html.

// Shared browser state for the classic scripts. In-memory flags coordinate
// polling and focus; only explicit save paths write presets or localStorage.
const $=id=>document.getElementById(id);
 let CFG=null, MODELS=[], HELP=[], LAST_STATUS=null, DEVICES=[], ROUTER_PRESETS=[], LIVE_ROUTER_MODELS=[], SERVER_ACTION_BUSY=false, APP_VIEW='dashboard', EDITOR_ALIAS=null, EDITOR_ORIGINAL_BUILD=null, ROUTER_SCROLL_Y=0;
// Pending actions disable invalid buttons until polling confirms the result.
 const LOAD_TRACK=new Map(),MODEL_ACTION_PENDING=new Map();
let DASH_MODELS_MARKUP='',MODEL_STATUS_BUSY=false,MODEL_STATUS_PENDING=false,MODEL_STATUS_FETCHED=false,MODEL_STATUS_ERROR=false;

let BUSY_COUNT=0,BUSY_RETURN_FOCUS=null;

// New-model defaults are read from template attributes, not a live form snapshot.

// Preserve unsaved Settings edits while status polls report the running binding.
let ROUTER_HOST_DIRTY=false,ROUTER_PORT_DIRTY=false;

let EDITOR_RETURN_VIEW='router',EDITOR_RETURN_CONTROL=null;

let MODEL_ORDER_BUSY=false;

let EDITING_BUILD_ALIAS='';

let SETUP_REQUIRED=false;

let FOLDER_BROWSER_TARGET='';
let FOLDER_BROWSER_PATH='';
let FOLDER_BROWSER_PARENT='';
let FOLDER_BROWSER_FILES=false;

let DEVICE_ORDER=[];

// Preview cache/debounce belongs to the editor; backend load planning is fresh.
let PRIORITY_PREVIEW_KEY='',PRIORITY_PREVIEW=null,PRIORITY_TIMER=null;

let MODEL_STATS_DATA=null, MODEL_STATS_SELECTION='*', MODEL_STATS_CONFIG='all', MODEL_STATS_BUSY=false;

// Short live chart history is separate from the backend model-stats JSONL log.
const GPU_HISTORY=new Map();

const GPU_HISTORY_MAX=60;

// Show the branded splash for 3.6 seconds so the highlight crosses twice; if initialization runs longer,
// give it another 250 ms before revealing the existing busy indicator.
// Instrument shell: presentation state never changes Router configuration.
let INSPECTED_ALIAS=null,MODEL_LIBRARY_MARKUP='',MODEL_DRAG_ACTIVE=false;

// Last entry owns keyboard focus; preceding dialogs remain mounted but inert.
const MODAL_STACK=[];

let SPLASH_READY=false,SPLASH_MINIMUM_MET=false,SPLASH_DISMISSED=false;
