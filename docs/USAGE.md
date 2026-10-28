# Using VisLlama

[Back to README](../README.md)

## Router and model catalog

Start Router from the header after completing setup. Its public OpenAI-compatible
proxy groups native llama.cpp engines by build and ordered GPU visibility
selection; extension models have managed per-model instances.
Saved Router service JSON is authoritative and is not restored from model snapshots.
Per-engine model limits are not a global capacity limit.

Manage Models contains one sortable table. Add starts with clean defaults; Clone
explicitly copies a preset. Saved catalog order controls sequential startup across
all builds/groups. Disabled/on-demand presets keep their positions without being
started automatically. There is no separate load-order list.

## Build aliases

Choose a named engine build when editing a model. llama.cpp supports native
executables and Linux Docker images; extensions use registered installed builds. Image
references are managed in the build dialog, not copied into each model preset.
Build aliases share one namespace across both launch types. A referenced alias
cannot be deleted; the manager lists affected saved models. Remove or reassign
those models first. Initial setup reappears only when no native or extension builds remain configured.

## Editing, saving and applying settings

The editor heading follows the alias field. Choosing another preset's name shows
a warning; saving requires confirmation before overwriting that preset. The
currently edited preset is excluded from the collision warning. Changing a name
does not silently confirm an overwrite.

Build-dependent help reflects the selected executable. Hidden or collapsed
settings retain their values. The command preview describes proposed settings;
it does not prove what a running child is using.

- **Save** persists the preset and attempts to publish compatible settings to the
  running Router catalog. A catalog-apply failure is reported separately.
- **Save and load/reload** applies saved settings to the selected model process.
  A resident child keeps its active settings until reloaded.
- A new build/GPU visibility group may require restarting Router. Follow the
  reported restart guidance instead of treating a save as a completed reload.

For llama.cpp, ordinary Load republishes the current saved group catalog and requests its native
reload before loading an unloaded model. Generated INIs and actual child launch
logs show the settings passed to llama.cpp. Preflight validates required files and
identity, but does not guarantee VRAM fit or architecture support.

llama.cpp Extra options accept natural `--option value` lines, `--option=value`, and legacy
separated flag/value lines. Windows paths are retained. These are executable
arguments, not shell commands or scripts.

## Model files and speculative decoding

Opening/focusing model and draft/head selectors refreshes the model-directory
inventory. Manual Refresh uses the same scan. A deleted selected file remains
marked unavailable instead of silently selecting another file.

An external MTP/head GGUF is selected through the draft/head control. An empty
external selection means embedded target heads. Support depends on the build and
model; the selector cannot guarantee native compatibility. Calculated priority
retains restrictions on separate draft residency. See troubleshooting for the
reported Qwen3.8-Flash-Next external-MTP crash.

## llama.cpp GPU placement

Available modes include Manual, Even split, Adaptive auto-fit/priority and
Calculated priority layer split. Other modes preserve llama.cpp's native fitting.
Calculated manual/startup/on-demand loads use one central planner, measuring free
VRAM immediately before each plan. Catalog order matters under VRAM pressure.

Calculated estimates are architecture-dependent; unsupported metadata can require
an approximate fallback or rejection. Minimum reserve is a planning floor, not a
protected memory allocation. Even split does not promise equal total VRAM usage.

Explicit CUDA devices are verified by physical UUID. NVIDIA-SMI indices and original
CUDA ordinals are not interchangeable. Saved choices use original build IDs;
launch configuration remaps them to local ordinals after visibility isolation.
Unavailable saved selections remain visible for deliberate removal or refresh.

## Chat

Start Router and load a model, then select Chat in the left sidebar. The model
picker offers currently confirmed loaded presets and stays in sync with their
state. A conversation's unavailable model is not silently replaced.

Enter sends; Shift+Enter inserts a newline. Stop cancels that generation and keeps
partial output. It does not stop Router. Expand Details for the system prompt,
conversation settings, endpoint, session API key and response statistics.

New conversations use **Use model setting** for output length and temperature.
Chat omits these request fields so the running instance's defaults apply. Choose
**Set output cap** or **Override temperature** for explicit per-conversation
overrides. Older saved/imported conversations can retain numeric overrides;
choose the model-setting modes explicitly to change them. A server-reported
`finish_reason: length` shows **Output limit reached**, which can reflect a
request cap, native model cap or context limit.

Reasoning is displayed separately and not replayed as message content. Editing a
user turn or regenerating an earlier answer removes later turns. Delete also
removes subsequent messages after confirmation. Response details opens the
collapsible inspector; copy actions support message text and code.

History, drafts and settings use browser-local storage. Export/Import JSON is the
backup mechanism; imports create new conversations. Clearing browser data deletes
history, and a different scheme/host/port creates a different storage origin. The
optional API key is held in memory only. Direct-server authenticated model
discovery is not supported by that generation-key field.

TTFT measures time to the first content/reasoning delta in the browser. Server
usage/timings supply token counts and rates where available; browser estimates
are labeled. Missing metrics stay absent. Context percentages describe the last
observed generation and do not predict the next edited prompt's token count.

## Statistics, logs and stopping

Stats shows available GPU and CPU/RAM telemetry. Aggregate GPU power is not
whole-system power; missing readings are not zero. Model Stats records available
inference history associated with configurations where possible.

AMD/Intel cards appear automatically when an installed CLI returns a supported
schema. Expand **GPU monitoring providers** for readiness, missing-tool/access
messages and diagnostic references. **Refresh status** queues another discovery
pass; routine retries use backoff. No monitoring tool is needed to retain native
llama.cpp device selection. Missing measurements show N/A, not zero. Sensor and
power-domain labels explain vendor-specific meanings. AMD/Intel verified physical
isolation is unavailable; even/priority placement modes remain CUDA-only.

Logs/Diagnostics provides operational output with targeted redaction. Clear view
does not truncate private disk logs. Error references locate detailed records in
`logs/diagnostics-YYYY-MM-DD.jsonl`, dated in UTC.

Stop Router stops managed serving processes. Stop compute cancels active inference
by restarting the public proxy while retaining loaded models. Ctrl+C attempts
managed cleanup. An unconfirmed stop retains ownership and blocks replacement
starts rather than assuming the process exited. Forced termination can bypass
cleanup; ownership records do not survive controller termination.

## Extension model settings

Choose Engine build in the shared editor to show the selected engine's controls.
Register an extension through Settings > Manage builds > Register another engine
type. For Strata, Python interpreter runs server.py; Strata inference executable
is the native model binary and the target for native option discovery.

For JSON engines, Import existing configuration JSON is at the top of model
settings. Import fills mapped controls, suggests an alias only when empty, and
retains unknown keys/tokens. Review the catalog model path, particularly if import
reports missing/ambiguous inputs. The original JSON file is not modified.
You can also configure a prepared model directly without importing.

Strata's pack, native GGUF and supplemental PLE inputs are independent. Provide
its prepared tokenizer, expert/profile, MTP and runtime paths as needed. The
catalog model path does not rewrite unknown paths in imported JSON. VisLlama
manages binding/port, public alias and log destinations. It does not create model
data packs or infer where a separate data directory was installed.

Edit a field to create an override. Clear an optional field or select Omit option
to remove its generated key/flag. Restore imported value or Restore configuration
value restores the source/default. Unset checkboxes do not force false. Raw JSON
is under Advanced: JSON configuration. Ordinary saving retains inherited values.

Reviewed base fields can be configured with advisory support notices. Discover
this build's options optionally adds/checks controls using the registered
installation. Newly discovered strict controls need current evidence. Review new
default controls previews updates for older retained definitions; review and Save
while Router is stopped. Custom rules are preserved. See [Engine extensions](ENGINES.md).

### Library folders

Native library folders are normal path rows. Use Add folder, Browse or Remove;
no JSON-array editing is needed. Source labels distinguish imported, detected and
user-selected paths. Check / detect folders reports missing paths and can find
known locations beside the selected interpreter when directories are absent.
Explicit empty/omitted model lists stay empty.

Model discovery uses the current model edits and library folders. Successfully
detected directories enter the model draft; Save retains them. Build-management
folder controls manage separate defaults and retain manual folders during
detection. Model discovery does not overwrite those defaults. Folder existence
does not establish DLL version/architecture compatibility or available VRAM.

### Engine-specific GPU behavior

Extension GPU settings are interpreted by that engine. Strata GPU selection,
layer/pipeline split points and request slots are distinct controls. GPU order
and automatic split behavior depend on its installed build; automatic fitting
can fail while another model holds VRAM. VisLlama does not apply its llama.cpp
Calculated algorithm or promise verified Strata physical placement. Select GPUs
and explicit supported settings based on the host's logs and memory readings.

### Changing engine type and loading

Edit/Clone from the catalog, inspector or Router use the same editor. Separate
unsaved drafts are retained per family until closing; values are not translated
between engines. Replacing an existing preset's engine type requires Router
stopped and preserves catalog position, alias and enabled/startup choices.

Save and load/reload uses the shared toolbar and validates the launch settings
before lifecycle changes. A later runtime failure is reported separately from a
successful save. New external aliases/build assignments may need Router restart.
Failed startup processes remain owned for Stop rather than being silently discarded.

## HTTP threads in Router settings

HTTP threads (`--threads-http`) controls HTTP handling in each internal llama.cpp
Router server. It does not control inference threads or the public VisLlama proxy,
and has no effect on Strata or other extension engines. Blank uses the build's
default. The public proxy creates a worker per accepted connection and has no
corresponding configurable worker count.

When validation blocks preset Save, Save and load/reload, engine Preview or build
registration, a modal explains the correction. Dismiss it to return to the
invalid field. Your draft stays intact; correct the value and retry the action.

Version 1.5.17 uses a compact presentation throughout the console. Model identity,
engine-defined controls and named build choices retain their existing meaning.
For external engines, the native JSON importer appears before model identity;
advanced editable JSON remains separately disclosed below the named controls.
The Dashboard GPU panel is host-wide monitoring, not evidence of model placement.
Its saved GPU column shows preset settings, not a verified live allocation.

### Interface refinements in 1.5.18

In Add/Edit model, **Manage engines/builds** and the final **Add new engine/build** selector option open the same build manager. Register a build, close the manager, then choose it; the current model draft is retained.

Model Stats displays the registered build alias for external engines. Configuration hashes still distinguish different settings. Removed registrations appear as **Unregistered build** with their retained ID; history is not rewritten.

In Logs / Diagnostics, **Open Router / Serving** navigates to VisLlama's Router page. It does not open a separate engine web UI.
