# Engine definitions and installed builds

[Back to README](../README.md)

llama.cpp is built in. Extension definitions describe compatible engine families,
independent of installation paths. Each installed build has an explicit engine
type, editable name and stable ID. All presets share one catalog, sequential
startup controller, public Router and model editor.

## Register a build and configure a model

1. In Settings > Manage builds, choose Register another engine type. Select the
   engine type, give the build a name and choose its installation root and server
   executable/interpreter. For Strata, choose the prepared environment's Python,
   not `strata.exe`.
2. For Strata, set the separate inference executable to the native `strata.exe`
   or Linux binary. It supplies Create-mode defaults and native option discovery.
   Add library folders with Add folder/Browse, or Check / detect folders.
3. In Manage Models > Add model, choose the registered Engine build and API alias.
   For a JSON engine, either import a working configuration at the top of the
   settings or configure the prepared model, tokenizer and fields directly.
4. Optionally choose Discover this build's options. Declared help/schema probes
   inspect the installation without loading a model. Reviewed base fields can
   remain editable with advisory support notices; strict discovered fields need
   current evidence.
5. Preview and Save. Start/restart Router when required, then load the model from
   Dashboard or Router. Save and load/reload is an explicit lifecycle action.

The model root is optional for extensions. VisLlama does not install engines,
download/convert/pack models or calibrate them. Paths selected through Browse
refer to the VisLlama host. Import reads a file on the browser's computer; paths
inside that file must be valid on the host.

## Shared editor and saved settings

The same identity fields, named build selector and toolbar serve llama.cpp and
extension engines. Native builds retain their existing serialization; extensions
use the metadata renderer. Edit/Clone use that same screen. Duplicate build names
are disambiguated by engine type; persisted names/IDs do not use UI-only prefixes.

A clone retains configuration/settings and gets a new alias. Switching engine
families keeps separate drafts until the editor closes. Settings are not translated
between families. Replacing an existing preset's engine type requires Router
stopped; catalog position, enabled/startup choices and stop timeout are preserved.

Save persists the preset and attempts compatible live catalog publication without
replacing a loaded process. Ordinary Save does not discover, probe, load or unload.
Explicit Save and load/reload validates launch configuration before saving or
unloading. Save, live apply and confirmed loading are separate outcomes. A later
load failure does not undo the durable save. New aliases/build mappings may need
Router restart. Unconfirmed cleanup retains process ownership.

## Import, overrides and omission

Import existing configuration JSON pre-fills mapped fields and the catalog path.
An empty new alias can be suggested; entered/saved/clone aliases are retained.
Invalid, oversized or failed imports preserve the draft. Late responses after
closing or switching builds cannot overwrite another draft.

Imported values are inherited until edited. Unknown keys/tokens and the original
JSON snapshot remain available under Advanced: JSON configuration. No original
imported file is edited. Config/flag controls override only their declared targets.
Whole-array edits run before per-flag overrides. Explicit advanced JSON edits
refresh matching controls.

Clearing an optional populated config control or choosing Omit option records a
null override, removing its generated key/flag. Restore imported value or Restore
configuration value removes the override and restores the source/default value.
A missing setting preserves source/default behavior; an unset checkbox does not
force false. Use engine default omits an option; it does not discover data folders.

The catalog model path identifies the preset. Import mode preserves native model
paths instead of rewriting unknown configuration keys. Create mode uses explicit
model_bindings. Strata's pack/native/PLE inputs can coexist: preserve_existing
bindings fill a missing selected primary path without erasing complementary inputs.

## Definition storage and identity

| Path | Purpose |
| --- | --- |
| `engines/<id>/engine.json` | Bundled default family definition |
| `presets/engines/<id>/engine.json` | Retained local editable base |
| `presets/engines/<id>/origin.json` | Marker authorizing the local override |
| `presets/engines/<id>/additive-<build-id>.json` | Per-installation discovered additions and evidence |

Use Edit engine definition to save a retained local copy. Direct edits to bundled
files can be replaced by application upgrades. Discovery creates a local base copy
when needed before writing its additive file. Unmarked duplicate IDs fail closed.
Retain `presets/` and `logs/` on upgrade.

Each registered installation gets a stable build ID; display names and upstream
version labels are not identity. Stable/experimental installations have separate
additive files even when version strings match. Rename retains identity. Evidence
records installation paths, fingerprints, definition digest, time and bounded raw
probe output. Changed executables, declared source files or definitions invalidate
related evidence without erasing saved values.

Stale controls stay visible as unavailable and can be removed deliberately.
Selected unavailable strict options block launch. Capability reads are passive;
Discover executes declared bounded commands. A separate startup compatibility
probe runs automatically when required evidence is missing/stale.

Review new default controls previews a retained definition update while Router is
stopped. Exact unchanged earlier defaults can receive the complete new default;
custom definitions receive missing controls/metadata while preserving existing
rules. Review and Save explicitly; local bases are not silently replaced.

## Definition schema

Schemas 1.0 and 1.1 are accepted. `Engine/Registry.pm` is the implementation authority
for allowed keys/types; `engines/strata/engine.json` is a complete reference.

| Metadata | Meaning |
| --- | --- |
| `id`, `name`, `definition_version`, `platforms` | Family identity, presentation and supported platforms |
| `driver`, `argv` | Native CLI/JSON lifecycle and tokenized server command |
| `probe` | Startup-interface command, required flags and bounded timeout |
| `readiness` | Health path and exact JSON predicate; public alias must also appear in `/v1/models` |
| `concurrency` | Independent, single-instance or unverified instances |
| `fields` | Typed controls with config, flag, environment, config-flag or none bindings |
| `required`, `when`, `initial` | Create-mode requirement, exact field dependency and new-preset default |
| `support` | Probe/flag evidence; optional `advisory:true` keeps reviewed base controls editable |
| `file_kind`, `group`, `format` | Browse control, field grouping and validated CSV formats |
| `legacy_keys`, `clear_flags` | Earlier-key aliases and explicit conflicting-flag removal |
| `new_config` | Create-mode template; existing native JSON wins |
| `model_bindings` | Selector, argument-array path, flag and optional file/directory requirement; `preserve_existing` retains complementary inputs |
| `requirements` | Config-path file/directory/array checks and required child files |
| `discovery` | Probe IDs, commands, 1–15-second timeout, parser, target and exclusions |
| `runtime_executable_path` | Config path tying native discovery to the inference executable |
| `runtime_libraries` | Config library-array/base paths and bounded interpreter-relative lookup rules |
| `fingerprint_files` | Declared source files included in build identity |
| `compatible_definition_digests` | Explicit reviewed runtime-compatible earlier definitions |
| `previous_default_digests` | Exact earlier defaults eligible for a complete reviewed update |
| `ui` | Build field labels and import mappings |

Types are string, integer, number, boolean and json-array (string elements).
Config bindings use object-key paths; config-flag bindings replace matching
flag/value tokens inside an array and preserve unknown tokens. None bindings
store selectors for dependencies/model bindings. Numeric bounds and enums are
validated. No arbitrary Perl or JavaScript plugins are loaded.

Placeholders include `executable`, `runtime_executable`, `runtime_library_dirs`,
`root`, `model`, `alias`, `host`, `port`, `instance`, `runtime_config`, `log` and
`native_log`. Runtime commands start with the registered server executable;
discovery starts with that executable or the registered inference executable.
Model settings cannot supply discovery commands. Arguments are separate tokens,
not shell command text.

### Capability discovery

The help parser accepts unambiguous long-flag rows with INT/INTEGER/N,
FLOAT/NUMBER, PATH/FILE/DIR/STRING/VALUE signatures, or boolean rows with no
argument and a description. Ambiguous rows remain raw evidence, not guessed
controls. Descriptions are not translated into JSON keys.

The schema-json parser accepts an explicit `{"fields":[...]}` envelope with the
same descriptors and declared target binding. It is not a general JSON Schema
translator. Base field keys/targets win collisions. Other discovery dialects
require a reviewed parser. Prefer documented side-effect-free help/schema probes.

### Presentation and import metadata

`ui.build_fields.executable` and `ui.build_fields.runtime_executable` may define
label, description and placeholder. Strata distinguishes its Python server
interpreter from its native inference executable.

`ui.import` declares alias_path/base_path and ordered model_paths entries with a
path and optional argument-array flag. The first present rule supplies the
catalog path. Different duplicate values for the preferred flag are ambiguous.
Without this metadata, existing explicit model bindings and a unique alias
config override provide conservative fallback mappings. Unknown paths are not invented.

### Library-folder metadata

Strata definition revision 1.3.2 declares:

```json
{
  "runtime_libraries": {
    "config_path": ["lib_dirs"],
    "base_path": ["cwd"],
    "interpreter_relative": [
      "../Lib/site-packages/nvidia/cublas/bin",
      "../Lib/site-packages/nvidia/cuda_runtime/bin",
      "../lib/python*/site-packages/nvidia/cublas/lib",
      "../lib/python*/site-packages/nvidia/cuda_runtime/lib"
    ]
  }
}
```

Folder checking is read-only and does not run the interpreter. It examines
bounded declared patterns, sorts/normalizes paths and reports missing folders.
Current model overrides/omissions are applied first. Imported directories take
precedence; absent directories fall back to build defaults, then detection.
Explicit empty/omitted model lists stay empty. Relative paths use base_path or
registered root. Detection does not install libraries or prove DLL compatibility.

Model discovery receives the current draft settings/JSON/mode and applies the
resolved search path only to the native probe. It does not change the controller
environment or registered defaults. Successfully detected model-discovery folders
enter the draft; Save retains them for later model loads. Build detection keeps
manual folders while adding detected ones.

Evidence includes the actual library-folder list/digest. Strict native controls
cannot borrow evidence from a different folder context or inference executable.
The digest identifies paths, not library contents or GPU placement.

Older explicit `${runtime_library_dirs}` config-array bindings support imported
folders and list controls. Exact known unchanged Strata defaults can use bundled
detection rules read-only. Custom definitions do not inherit new search rules
implicitly; Review new default controls previews metadata for an explicit Save.

## Strata support

The reference definition uses the reviewed server contract:
`serve/server.py --engine strata --config FILE --host HOST --port PORT`.
The interpreter and native executable are separate. Prepared tokenizer artifacts
include `vocab.json`, `merges.txt` and `token_type.json`. Pack/native/PLE paths,
expert cache/profile, prefill, speculation/MTP, context/KV/RoPE, GPU selection,
layer-split boundaries, request slots and runtime/memory controls are declarative.
Raw configuration remains available for unsupported options.

VisLlama manages host/port, public alias, logs, readiness and process ownership;
the definition disables browser opening and lazy/idle unloading. Shared model,
cache and calibration data are not relocated automatically. Parallel model
instances remain unverified and require the definition's build-level opt-in.
Request batching, layer/pipeline splitting and tensor parallelism are different
features; the Strata definition does not advertise tensor parallelism.

GPU numbers remain Strata-native. VisLlama does not establish their physical
mapping or apply its llama.cpp Calculated planner. Automatic fitting can still
fail on busy GPUs. Restrict selection or set explicit supported split values
based on host evidence; successful loading on one machine is not a compatibility
claim for other builds/models. See [Troubleshooting](TROUBLESHOOTING.md).

Source provenance: [server.py](https://github.com/Niko1221/Strata/blob/2e805773dc56788bfe2f899bc7a78f20bd6db553/serve/server.py),
[MULTI_GPU.md](https://github.com/Niko1221/Strata/blob/30e316d527d47b5cf2b24b1fcde9c63056a73937/docs/MULTI_GPU.md),
[DETAILS.md](https://github.com/Niko1221/Strata/blob/5c5724f121db8778b038c58e36d4f59787384f0e/docs/DETAILS.md),
and [INSTALL.md](https://github.com/Niko1221/Strata/blob/1a7a430951281538154a9d13f1cacb060a2d3b6b/docs/INSTALL.md).
Installed-build help supplies discovered controls; upstream documentation alone
is not runtime acceptance. No upstream implementation is bundled.

## Execution and scope

Definitions and imported configurations can execute installed programs under the
VisLlama account and may reference writable shared data or engine hooks. Validation
is not an OS sandbox or authentication. Review them before use. Keep complete
private diagnostics locally and share redacted copies.

The native drivers do not provide extension Docker deployment, arbitrary YAML
rendering, authenticated internal engine APIs or managed-server model switching.
Engines needing another lifecycle/protocol require implementation support;
a manifest alone cannot supply a new driver. Engine/model provisioning is external.

## Maya support

The bundled Maya GLM definition uses the same registration, import, shared model
editor, discovery and lifecycle code. See [Maya setup and settings](MAYA.md) for
the prepared-installation contract, GPU limits and writable-cache guidance.
The separate Maya DeepSeek pathway is not included.

The advanced **Editable base configuration JSON** field is saved inside the
VisLlama preset. It supports native options without named controls. Finishing a
JSON edit (leaving the field) refreshes matching controls and clears their prior
overrides; later named-control edits override that base. Source files remain
unchanged. Supervisor-owned host, port, alias and log values still come from the
engine definition. Inspect Preview for the generated configuration.
