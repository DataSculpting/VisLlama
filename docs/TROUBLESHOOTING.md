# Troubleshooting and limitations

[Back to README](../README.md)

## Optional AMD/Intel GPU monitoring

Expand **GPU monitoring providers** in Stats. `not_found` means no executable was
found on an explicit search path; `permission_denied` means the launch account
could not read the tool/device; `unsupported_schema` means the installed output
cannot be normalized safely. A timeout or missing library/interpreter disables
that provider, not the Router. Referenced private records include the failed
provider stage and raw error; do not infer GPU failure from a generic message.

Confirm the CLI works under the same account/environment as VisLlama, then use
Refresh status. If PATH changed, restart VisLlama. Automatic retry uses bounded
backoff. Old readings disappear after five seconds rather than masquerading as
fresh data. The first capability pass completes incrementally between requests.

Do not install or copy random executables just to satisfy discovery. Native
Windows AMD CLI support and Windows client Intel coverage are not established
by the source-derived fixtures. Missing monitoring does not invalidate a working
native llama.cpp backend. WSL is reported separately. See installation notes for
the supported parser families, platform limits and tool-owned dependencies.

## Collect evidence before changing settings

Record the VisLlama version, operating system, selected engine build/version,
model/head filenames and failing action. Compare the saved preset, generated
group INI and actual child launch arguments. A preview or successful save alone
does not establish active process settings.

For a `VL-...` error reference, find the corresponding private record in
`logs/diagnostics-YYYY-MM-DD.jsonl` (UTC), together with the complete raw engine and
Router logs. Review logs and payloads for credentials, paths and private prompts
before sharing or attaching them to a public issue. Do not publish `presets/` or
`logs/` to GitHub. Generic UI errors are intentionally not raw exception reports.

## Browser connectivity and conflicts

Keep the Perl process running while using the UI. If it stops, normal background
reads pause automatically and a single status probe retries after 5, 15, 30 and
then 60 seconds. A successful response restores polling. Browser network errors
cannot all be suppressed; reloading resets retry state.

HTTP 409 means the controller responded with a conflict, not that the port is
offline. A lifecycle operation or stale runtime identity can cause it. Wait for
the current operation, refresh state and deliberately retry. Mutations are not
automatically replayed. Trace repeated failures through their error references.

For Chat, check the public inference address/port, loaded-model state, CORS and
mixed-content restrictions. Management and inference URLs are different. A remote
browser cannot reach the server through the browser's own loopback address.

## Saved settings differ from a running model

Save writes durable settings and tries to update the live catalog; it does not
silently restart a loaded model. Use Save and reload for active child settings.
Changed build/GPU visibility groups can need Router restart. Inspect the current
group INI and native launch log if settings appear not to have taken effect.

Preserve `presets/` during recovery. If publication recovery fails, stop VisLlama
and retain the entire directory, including `publication-journal.json` and staging/
backup files. Removing them can discard the recoverable configuration generation.
Configuration publication does not guarantee survival of every disk/power failure.

## GPU discovery or loading fails

Refresh GPU discovery and verify the selected build's CUDA dependencies. On Windows,
check the adjacent runtime DLL and PowerShell/Add-Type policy; on Linux, check
NVIDIA driver access, GNU loader tracing and compiler prerequisites. Saved
unconfirmed devices remain visible rather than being silently reassigned.

UUID verification does not equate SMI indices with CUDA ordinals. Check the logged
original-to-local mapping. MIG/virtual layouts and mixed unsupported backends are
not validated by the isolation contract. Native fitting and Calculated estimates
do not prove a model will fit or execute successfully on the host.

## External MTP and native CUDA failures

Qwen3.8-Flash-Next external MTP has a reported unresolved failure with the Unsloth
`b11030-mix-5ff778e` Windows CUDA build: MTP off works, while enabling an external
head leads to failure at the first request. The failure has also been reported
with Unsloth quantization/head files and a separate Chat client. This is not
confined to integrated Chat. Its cause is not established; generated launch
settings remain relevant. Do not present a generic CUDA launcher line as proof
of the specific failing operation or claim that a context/cap change fixes it.

Collect full native diagnostics and actual main/draft device placement. Turning
MTP off is the reported working configuration, not a native-engine fix. Other
build/model combinations need their own compatibility evidence.

## Current validation limits

Fixtures and synthetic CUDA libraries test application contracts; they do not
validate real GPU UUID mapping, placement, sequential loading under VRAM pressure,
native inference, browser drag/touch/layout or Windows shutdown. Linux lifecycle
tests need a real readable `/proc`. Other-vendor parity remains unverified.

See [Development](DEVELOPMENT.md) for the complete check commands, test scope
and environment-dependent skips. Passing fixtures do not guarantee host fit.

## Docker builds

Check Docker access under the account running VisLlama and confirm a local Linux
Docker context. A missing image can require a download. Raw Build Details help and
GPU output retain both streams and the NVIDIA banner. Generic Docker API errors
refer to private diagnostics; do not infer GPU or model failure from a CLI error.

An image must support native llama.cpp Router mode. Changing its resolved image
or introducing files outside the running container's mounted directories requires
restart rather than silently treating the new settings as active. Stop verifies
owned container exit/removal; if cleanup is unconfirmed, ownership is retained
and replacement starts remain blocked. Forced controller termination can leave
containers; review their full IDs/owner labels before manual cleanup.

## Extension builds

A changed definition must be reviewed/re-registered; a changed executable or
declared source file triggers an automatic compatibility check when loading.
Probe success is not GPU/model acceptance. Use Settings > Manage builds > Manage
for the selected engine, then Check compatibility to diagnose a failure. For Strata,
register the prepared Python interpreter, not strata.exe. Import the working model
JSON; its model paths are not rewritten by the catalog model-path field.

Invalid aliases are rejected beside the input before saving. Use letters, numbers,
dots, underscores, hyphens or colons, with no spaces or slashes.
Inspect `logs/instances/engine-*/launch.json`, `config.json`, `engine.log` and
(native Strata) `native.log` privately. Configs may contain credentials/hooks;
share redacted evidence only. Readiness requires both its JSON predicate and
the public alias in `/v1/models`. A failed startup retains owned processes for
Stop. Concurrent instances are opt-in when the definition marks them unverified.

## Engine capability discovery and configuration creation

Create in VisLlama does not require a premade Strata JSON. It still requires a
prepared compatible model, native executable and tokenizer artifacts. If native
--help reports a missing DLL, import the working model JSON and review Native
library folders; do not substitute strata.exe for the Python server interpreter.
Discovery is optional and never installs dependencies.
A stale option can be rediscovered or explicitly removed from the preset; saved
values are preserved. See ENGINES.md for per-build additive file identity.

### Strata option discovery cannot find CUDA DLLs

Import the working model JSON, then review Native library folders in the model
editor. Discovery uses those folders and any current field edits. Check /
detect folders marks missing/inaccessible folders and can find known library
locations beside the selected interpreter when the list is absent. Correct paths
with Browse; no JSON editing is needed. Save retains changes.

The Strata inference executable must match the selected registered build. A
folder existing does not prove that cublas64_12.dll/cudart64_12.dll or their
dependencies have the right version/architecture or can load. A repeated Windows
loader error still requires its exact dialog and discovery diagnostics. VisLlama
does not install CUDA or repair native library dependencies.

## Strata out of memory or shared-GPU loading failure

A native message such as `native dense upload ... out of memory` identifies a
failed GPU allocation during weight loading. It does not alone establish whether
the cause is occupied memory, a split estimate, runtime accounting or another
allocation constraint. Compare the generated config and native log with available
VRAM on the selected physical GPUs before the load.

Strata's automatic split is engine-specific, not VisLlama's Calculated priority
planner. Explicit and automatic splits may have different memory costs. More
selected GPUs do not guarantee a fit. Restricting the selection to unused GPUs
or using a supported explicit split can help isolate the problem; confirm the
exact installed version and logged placement. Monitoring indices alone are not
proof of cross-engine physical mapping. VisLlama does not automatically evict
other engines or rebalance their loaded weights.

## Windows external-engine launch diagnostics

The extension launcher's PowerShell error handling can interrupt capture of a
native Python traceback. A `NativeCommandError` console wrapper is not the
underlying Python exception. Inspect the instance's `native.log`, `engine.log`,
`config.json` and `launch.json`, plus any remaining console traceback. PowerShell
redirection may produce UTF-16 logs; read them with an encoding-aware viewer such
as PowerShell Get-Content. This is a known diagnostic limitation, not an indication
that every stderr line represents a model failure.

## Missing Windows CPU load

A `Windows did not return CPU load` diagnostic means the telemetry query did not
supply a usable load value. It is not evidence of model or GPU failure. Check the
query's private diagnostic record under the same launch account; do not substitute
zero for a missing reading.
