# Architecture

[Back to README](../README.md)

VisLlama uses a modular Perl backend and classic browser scripts. Both entry
scripts resolve sibling modules through FindBin and are thin launchers.

| Path | Purpose |
| --- | --- |
| `VisLlama.pl` | Launch the administration application |
| `llama_openai_proxy.pl` | Launch the public inference proxy |
| `lib/VisLlama/` | Private backend modules and platform helpers |
| `templates/` | Private HTML shell, pages, editor and dialogs |
| `public/assets/{img,css,js}/` | Public static assets and local Chat renderers |
| `tests/` | Regression cases, fixtures and pinned development dependencies |
| `third-party/` | Bundled dependency licenses and asset hashes |
| `docs/` | Maintained operating and development documentation |

Only assets are a static web surface. Templates, modules, settings, logs and
documentation are not exposed as static files. Template includes and asset
resolution enforce containment. Frontend script order is defined by the private
scripts partial; shared lexical state makes arbitrary reordering unsafe.

## Backend responsibilities

`App`, `HTTP` and `API` own administration request handling. Scope-specific API
modules dispatch settings, model, serving and diagnostic actions. `Context`
holds shared version/state; `Paths`, `Config` and `Storage` manage portable paths
and durable publication. Importing modules does not start listeners.

`GPUProviders` owns optional installed AMD/Intel CLI discovery and cached
capability state. `GPUParsers` normalizes supported source-derived JSON/CSV
families. The application idle loop advances one bounded provider step; stats
API reads consume snapshots and never run those probes synchronously. Existing
lifecycle checkpoints service status and Stop during a probe. This adds no
controller-wide lock, installer, helper compiler or runtime service.

NVIDIA telemetry and `GPUIsolation` use their dedicated native paths.
AMD/Intel monitoring records never enable verified physical isolation or change
llama.cpp enumeration/planning. Candidate identities are observations, not
runtime/build mappings. The dashboard retains the NVIDIA summary and adds
individual AMD/Intel cards without summing shared or unknown memory pools.

`Catalog`, `Router`, `Process`, `ProcessState`, `Lifecycle`, `Preflight` and
`Readiness` coordinate saved catalogs, active groups, owned children and observed
readiness. `Proxy` and `ProxyResponse` provide public routing and HTTP/JSON/SSE
framing. Internal llama.cpp engines bind loopback and are grouped by build plus
ordered explicit GPU visibility. Extensions use managed per-model instances. The control listener is serialized; the public proxy
has separate request handling/threading.

`PlannerSettings`, `GPUPlanner`, `MemoryLayout` and `LayerPlanner` resolve effective
arguments and calculated placement. Manual, startup and on-demand Calculated
loads share one serialized controller path and fresh VRAM measurement. Native
fitting remains authoritative in the other GPU modes. Architecture rules are
reviewed adapters, not universal model support.

`GPUIsolation` verifies physical identities and creates local CUDA remapping.
`Platform`, `Platform/Linux` and `Platform/CUDA` contain OS-specific behavior.
The private `cuda-devices.ps1` performs the Windows identity probe; it is not a
second backend service. Linux uses process groups and the selected build's actual
runtime linkage. Windows and Linux use the same catalog and settings schema.

`Telemetry`, `ModelStats`, `Logs`, `Errors` and `Performance` provide operational
observations, safe errors and private diagnostic records. `View`, `Template` and
`Assets` implement the private-rendered/public-asset web boundary.

## State and lifecycle contracts

Durable JSON under `presets/` contains `llama-builds.json`, `build-discovery.json`,
`model-root.json`, `router-service.json` and `router-presets.json`. Router service
JSON is independent of model snapshots. Ordered catalog rows drive startup.
Generated group INIs, route maps and launchers are derived runtime artifacts.
Configuration publication stages files under a lock and uses a rollback journal.

Preview, saved preset, live native catalog and loaded child settings are distinct.
Save/reload paths coordinate publication and process state; actual launch logs
remain the evidence of active arguments. Ownership is retained after unconfirmed
stops. In-memory ownership does not survive forced controller termination.

Chat history/settings are browser-local; generation API keys are memory-only.
Chat model choices use confirmed loaded snapshots. Its provider uses the public
OpenAI-compatible endpoint, supports streaming, and omits temperature/output caps
in model-default mode. Chat styling is scoped to its own view.

Error records are private UTC-dated JSONL with correlated safe references. UI log
redaction preserves useful operational details. This is not authentication.
Installation and runtime limits are described in the operating guides.

## Docker runtime boundary

`Docker.pm` is a Linux adapter used through the existing build/Platform interfaces.
Native build JSON entries are unchanged; Docker image references use a
`docker://` path value in the same alias/path entries. Model snapshots still refer
only to build aliases. Docker startup uses resolved image metadata and image IDs,
with captured help/device probes through the same parsers as native builds.

A Docker-owned handle implements the existing health/exit/stop interface. Full
container IDs and controller-specific owner labels authorize operations; host PID
or container name alone does not. Log followers are native managed processes.
Partial startup and failed probe cleanup retain owned containers for Stop retry.
Mount directories preserve atomic host INI updates. Live apply/load checks mounted
paths and image identity before treating a saved catalog as applicable.

Explicit CUDA identity traces image libraries and runs the private native helper
inside the image before the existing PCI/UUID cross-check and local remapping.
Calculated loads still use the central planner and fresh build device probes;
other modes keep native fitting. No universal UMA budget or hardware validation
is implied by reported memory figures.

## Optional engine boundary

`Engine/Registry.pm` validates reusable definitions; `Engine/Plan.pm` renders
typed launch plans without side effects; `Engines.pm` owns build registration,
probe evidence and native startup-load instances. `API/Engines.pm` and
`engines.js` expose common forms and operations. Narrow Process/Router dispatch
keeps existing llama.cpp modules in place. Extension presets share the catalog
and sequential startup; each native-driver model owns its own process/port.
Definitions have no host installation paths. See [ENGINES.md](ENGINES.md).

## Definition and discovery separation

Engine::Definitions manages explicit retained local engine.json copies;
Engine::Discovery executes bounded declared help/schema commands and stores
additive-<stable-build-id>.json beside the local base. Registry validates base
metadata; effective per-build controls are a read-only projection of base plus
current additions. Engine::Plan renders typed configuration/argv, dependencies,
required resources and Create-mode model bindings. API::Engines and the shared
forms expose create/import/edit/discover paths without changing native llama.cpp
GPU planning or the central runtime owner.

## Unified model editor

`model-editor.js` owns the shared editor shell, named build selection, per-family
unsaved drafts and dispatch to the existing native or declarative editor adapter.
`editor.js` retains llama.cpp's fields, serializer and save/reload implementation.
`engines.js` renders all extension definitions into an inline panel in that same
shell; it does not open a second model modal. Native build names and extension
build IDs remain the persisted references. UI-only option prefixes distinguish
otherwise identical display names and are never saved to presets.

Both save endpoints check explicit engine-type replacement intent and reject it
while Router ownership is retained. Replacement writes the target engine's
existing preset format, retaining catalog position and lifecycle choices.
`/api/engine-load-check` is a narrow launch validation for explicit extension
Save and load/reload requests; ordinary saving does not invoke it. Compatibility
probes may run there, never model loading. Load/unload still use the central
Router API and runtime token. Hardware fitting and process readiness remain load
time outcomes, not promises made by the editor or discovery metadata.

## Typed engine controls

The same metadata renderer groups controls into fieldsets and separate accessible
field cards. engine-forms.css scopes spacing, help/error placement and narrow
layouts to engine forms and shared identity fields. Field errors reference the
actual control. Checkbox unset state is presentation only and never forces false.

The generic Plan renderer applies object/whole-array bindings before per-flag
bindings. A null config/config-flag setting explicitly omits that key/flag; a
missing setting retains source/default behavior. Model bindings can opt into
preserve_existing, so multiple complementary model selectors coexist and explicit
omission does not get repopulated by a fallback. Old definitions retain their
original model-selector replacement behavior. Per-field advisory support is an
explicit definition choice; discovered additions remain strictly fingerprinted.
The Strata base exposes reviewed options without claiming verified placement.

## Foreground configuration import

engine-import.js owns file selection, bounded JSON parsing, atomic draft updates,
result messages, definition-driven installation labels and source-aware empty/
restore wording. It shares the existing renderer and editor identity. A serial
and build identity discard stale reads/responses after another import, editor
close or build switch. The local import guard only prevents saving a partial
import; ordinary saves do not acquire a new global busy/preflight state.

Private Engine/Import.pm interprets explicit ui.import mappings or conservative
existing definition bindings, resolving relative catalog paths with native host
path semantics. API/Engines exposes read-only inspection. Source JSON is neither
rewritten nor executed. No compatibility probes, native inference or filesystem
layout scanning run during import. Runtime planning, ownership and llama.cpp
identity/placement stay with the existing modules.

## Contextual library lookup

Engine::Libraries is a read-only definition-driven resolver. API::Engines exposes
a folder inspection route and passes model context to explicit discovery. The
existing Plan renderer applies typed config edits without model requirements
for this inspection. Discovery records the resolved environment alongside its
existing per-build fingerprint; strict native option launch checks compare it.
engine-libraries.js provides list controls while preserving saved arrays. The
shared folder picker dispatches changes only for these marked library rows.
