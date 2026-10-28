# Development and checks

[Back to README](../README.md) · [Architecture](ARCHITECTURE.md)

## Development environment

Use the platform prerequisites in [Installation](INSTALLATION.md). Keep the backend
in Perl modules under `lib/VisLlama/` and the entry scripts thin. HTML belongs in
`templates/`; public assets belong in `public/assets/{img,css,js}/`. Only assets
are statically served. No frontend compilation is required.

Install development-only dependencies with `npm ci --prefix tests`. The pinned
jsdom version requires Node `^22.22.2`, `^24.15.0` or `>=26.0.0`; the lockfile is
part of the repository. Node and npm are not application runtime dependencies.
Do not upgrade dependencies as a side effect of an unrelated change.

## Run the checks

From the repository root in PowerShell:

```powershell
perl -c VisLlama.pl
if ($LASTEXITCODE) { throw 'Main syntax check failed' }
perl -c llama_openai_proxy.pl
if ($LASTEXITCODE) { throw 'Proxy syntax check failed' }
Get-ChildItem tests/*.pl | ForEach-Object {
    perl $_.FullName
    if ($LASTEXITCODE) { throw "Failed: $($_.Name)" }
}
Get-ChildItem public/assets/js -Recurse -Filter *.js | ForEach-Object {
    node --check $_.FullName
    if ($LASTEXITCODE) { throw "Syntax failed: $($_.Name)" }
}
Get-ChildItem tests/*.js | ForEach-Object {
    node $_.FullName
    if ($LASTEXITCODE) { throw "Failed: $($_.Name)" }
}
```

From Bash:

```bash
set -e
perl -c VisLlama.pl
perl -c llama_openai_proxy.pl
for f in tests/*.pl; do perl "$f"; done
for f in public/assets/js/*.js public/assets/js/chat/*.js public/assets/js/chat/vendor/*.js; do node --check "$f"; done
for f in tests/*.js; do node "$f"; done
```

Version 1.5.18 contains 39 Perl regression scripts, 45 JavaScript regression
scripts, 30 browser JavaScript syntax checks and two entry syntax checks:
116 commands before environment-dependent skips. Record each skip and failure.

`linux_router.pl` requires real procfs and owned-process support.
`linux_platform.pl` includes a native-process subtest requiring readable `/proc`.
`linux_cuda_helper.pl` uses a C compiler and synthetic ELF libraries.
`cuda_identity_helper.pl` needs its documented Linux/compiler and PowerShell or
Mono/mcs prerequisites. Some JavaScript tests have opt-in browser execution;
consult their headers before enabling it. Default DOM tests do not establish
actual rendering, pointer or touch behavior.

## Regression coverage

| Area | Representative tests and contracts |
| --- | --- |
| Modules, assets, HTTP | `module_layout.pl`, `http_assets.js`: portable entry paths, templates, containment and saved-state preservation |
| Catalog and lifecycle | `preflight_lifecycle.pl`, `engine_router.pl`, `engine_preset_replace.pl`: readiness, ownership, startup order and saved/live/loaded distinctions |
| GPU identity and fitting | GPU/CUDA/planner tests: physical UUID/PCI joins, original/local remapping, fresh-memory planning and unsupported configurations |
| Docker | Adapter/settings/UI tests: image identity, mounts, probes, owned-container cleanup and failure retention |
| AMD/Intel telemetry | `gpu_provider_parsers.pl`, `gpu_providers.pl`: supported schemas, missing values, fallback, bounded discovery and provider failures |
| Extension definitions | `engine_registry.pl`, `engine_discovery.pl`, `engine_model_options.pl`: reusable families, stable build IDs, typed rendering and evidence invalidation |
| Model editor | `unified_model_editor.js`, `engine_workflow_ui.js`, `engine_option_fields.js`: real page scripts, native/mixed/extension-only workflows and field validation |
| Import and library folders | `engine_import.pl`, `engine_import_ui.js`, `engine_libraries.pl`, `engine_library_ui.js`: atomic import, scoped probes, relative paths, draft edits and stale-response guards |
| Chat | Chat regressions: model-default omissions, transport, cancellation, rendering, history and scoped UI |

Keep fixtures and support files. Older fixture filenames and pinned baseline
hashes identify intentional regression inputs; they are not temporary output.
Fixture provenance is documented beside the engine and GPU-provider records.
Synthetic native/GPU/process fixtures test application contracts, not hardware
compatibility or inference correctness. Hardware reports need exact engine,
model, OS, driver, launch settings and raw diagnostics. Do not infer cross-vendor
or cross-engine placement from matching numeric device indices.

## Compatibility contracts

- Preserve saved formats/UI values, authoritative Router service JSON and catalog order.
- Keep preview, durable save, live catalog publication and loaded settings distinct.
- Retain owned processes/containers until cleanup is confirmed; ordinary saves
  must not acquire broad launch/preflight requirements.
- Preserve one public Router with ordered native build/GPU groups and sequential loads.
- Keep llama.cpp enumeration authoritative and verify UUID/PCI identities before
  CUDA remapping. NVIDIA-SMI indices are not CUDA ordinals.
- Preserve central fresh-VRAM Calculated loads and native fitting in other modes.
  Monitoring alone does not enable placement or new Calculated modes.
- Keep integrated Chat's model-default temperature/output omission and scoped styles.
- Preserve useful redacted UI logs and private diagnostic references. Error
  hardening is not authentication.
- Keep engine declarations family-based and local definitions/additives upgrade-safe.
  New lifecycle/discovery dialects require explicit driver/parser support.

## Repository hygiene

Commit source, tests, fixtures, maintained docs and required licensing/assets.
Exclude host `presets/`, `logs/`, model weights, engine binaries, `node_modules`,
temporary test installations, test evidence and local archives. `.gitignore`
prevents accidental additions; it does not delete an existing installation's state.

Keep third-party versions, license files and `third-party/chat-assets.sha256`
consistent when updating bundled renderers. Run the affected checks and complete
suite for implementation changes; report hardware/browser limits separately.
See [Contributing](../CONTRIBUTING.md) for bug reports and change descriptions.

Maya fixtures: `perl tests/engine_maya.pl` and `node tests/engine_maya_ui.js`.
They exercise the shipped definition with synthetic processes, not GPU hardware.

The integrated presentation layer is documented in [UI design](UI_DESIGN.md).
`node tests/visual_refresh.js` exercises real templates/styles and mounted controls
with synthetic data; it does not validate browser pixel layout.
