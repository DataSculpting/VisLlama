# Changelog

User-visible changes in the 1.5.x source releases. Current setup and behavior
are documented in [Installation](docs/INSTALLATION.md), [Usage](docs/USAGE.md)
and [Engine extensions](docs/ENGINES.md).

## 1.5.18

- Keep Dashboard load/unload labels on one line and normalize GPU list spacing for display only; protect other controls from mid-word wrapping.
- Add Manage engines/builds beside the model engine selector and Add new engine/build as its last option. Both open the existing unified build manager without discarding the model draft.
- Align GPU metric charts independently of wrapped labels and values, with a fallback for browsers without CSS subgrid.
- Show registered external build aliases in Model Stats filters and history while retaining original configuration IDs and saved log formats.
- Replace the misleading Open llama-server UI action with navigation to VisLlama's Router / Serving page, available even while stopped.

## 1.5.17

- Integrate the approved graphite/amber/green visual refresh with compact chrome, flatter sections and consistent field/control styling.
- Tighten operational tables, hardware cards, dialogs, diagnostics and scoped Chat presentation.
- Put native JSON import above shared model identity and keep component Browse actions beside their inputs.
- Add a Dashboard per-device memory panel and host RAM summary using existing telemetry; unavailable values remain explicit.
- Show engine family and saved GPU selection beside Dashboard model state, retaining the existing load/unload dispatch.
- Preserve the splash composition/animation, backend, engine definitions, GPU planning and saved/live/loaded-state behavior.

## 1.5.16

- Pass Maya's empty worker API-key value as `--api-key=` so legacy Windows PowerShell cannot drop it.
- Preserve empty native arguments in the external-engine Windows launcher, including retained local engine definitions.
- Keep earlier Maya build registrations compatible and preserve local definitions and model presets.
- Add regressions for the current default, retained earlier definition, private launcher arguments and upgrade compatibility.

## 1.5.15

- Preserve absolute Windows drive roots when starting component file/folder browsing and normalize bare drive letters in the folder API.
- Keep external-engine Windows stderr capture running and record the native exit status separately.
- Clarify that advanced JSON edits the preset's base configuration, refreshes matching controls and leaves the source file unchanged.
- Document runtime Maya GPU selection, inherited split/environment conflicts and the private log files needed to diagnose startup failures.

## 1.5.14

- Explain validation-blocked preset Save, Save and load/reload, engine Preview and build registration in a modal.
- Retain inline field errors and return focus to the offending setting after dismissal.
- Keep typing-time validation inline and preserve drafts; blocked actions make no save or load requests.

## 1.5.13

- Add a declarative Maya GLM engine definition; no core dispatch or frontend changes.
- Import prepared Maya JSON into the shared model editor, or create presets from prepared packs.
- Expose native context/cache, GPU split, request slots, RAM/CPU tuning and writable-data settings.
- Preserve unknown native configuration and model sampling while owning worker host, port, alias and log.
- Keep Maya setup/rebuild/calibration external, native placement unverified and concurrency opt-in.
- Add Maya setup documentation and backend/full-page UI regressions. Hardware acceptance remains outstanding.

## 1.5.12

- Use current model library folders and field overrides during native option discovery.
- Replace library JSON inputs with Add/Browse/Remove and Check / detect folders.
- Detect declared interpreter-relative library locations when folders are absent.
- Retain manual build folders and keep model-specific choices separate from build defaults.
- Record the discovery library environment and check it for strict native controls.
- Guard late folder/discovery responses and report missing folders before probing.
- Bundle Strata definition revision 1.3.2.

## 1.5.11

- Put native JSON import at the top of the shared model editor and prefill mapped
  fields, catalog paths and new aliases while preserving existing identities.
- Preserve drafts on invalid, cancelled or stale imports.
- Clarify server-interpreter versus inference-executable labels and imported/default values.

## 1.5.10

- Expand Strata's named controls for model files, expert settings, speculation/MTP,
  context/cache, GPU settings and runtime paths.
- Preserve complementary pack/native/PLE paths and unknown native arguments.
- Add explicit omission/restoration and separated field/help/error cards.
- Keep reviewed base options editable with advisory support guidance.

## 1.5.9

- Unify llama.cpp and extension model editing, cloning and build selection.
- Preserve per-engine drafts and integrate shared save/load/reload actions.
- Require Router stopped for an existing preset's engine-type replacement.

## 1.5.8

- Add named Strata GPU-sharing, request-slot, context/cache and memory controls.
- Preserve imported values and retained local-definition customizations.

## 1.5.7

- Add direct extension configuration creation, typed fields and dependencies.
- Add retained editable base definitions and stable per-build additive discovery files.
- Preserve stale option values while requiring current evidence for strict controls.

## 1.5.6

- Explain the llama.cpp HTTP-thread setting with a focusable information tooltip.

## 1.5.5

- Replace the engine-registration trust checkbox with an execution notice.

## 1.5.4

- Correct load-button state and shared model controls for engine-only setups.

## 1.5.3

- Allow extension-only Router startup and check compatibility evidence at load.
- Add inline alias guidance and show registered extension builds in build management.

## 1.5.2

- Introduce reusable engine definitions, explicit build registration and Strata support.
- Add native CLI/JSON instance drivers, bounded probes and private launch artifacts.
- Integrate extensions with the catalog, Router, Chat and owned-process lifecycle.

## 1.5.1

- Add optional installed AMD-SMI, ROCm-SMI and Intel XPU-SMI discovery and monitoring.
- Normalize supported schemas, show partial telemetry/provider status and bound retries.
- Preserve the NVIDIA identity/planning path and keep monitoring separate from placement.
