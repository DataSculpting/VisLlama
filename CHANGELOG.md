# Changelog

User-visible changes in the 1.5.x source releases. Current setup and behavior
are documented in [Installation](docs/INSTALLATION.md), [Usage](docs/USAGE.md)
and [Engine extensions](docs/ENGINES.md).

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
