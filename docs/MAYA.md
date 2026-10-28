# Maya

VisLlama includes `engines/maya/engine.json` for prepared Project Maya
**GLM-5.3-Flash** installations. The same definition covers multiple named,
compatible installations. This is experimental integration: automated fixtures
exercise the application contracts; real Windows/Linux GPU loading still needs
testing. The separate `maya-ds4` DeepSeek engine is outside this definition.

## Prepare Maya

Install [Project Maya](https://github.com/mw00/project-maya) using its own
[Linux setup](https://github.com/mw00/project-maya/blob/main/docs/SETUP.md) or
[Windows instructions](https://github.com/mw00/project-maya/blob/main/docs/WINDOWS.md).
Complete setup and confirm the generated model launcher works, then stop it.
Keep its generated `maya-<model>.json`: that is the easiest starting point.

Maya handles its own model downloads, dependencies, compilation, packs and
calibration. VisLlama does not perform those steps. Windows and HIP are
experimental upstream paths; use a Maya build prepared for the actual GPUs.
V100 installations need a compatible CUDA 12 toolchain rather than CUDA 13.
Maya's published setup and native CMake architecture checks differ; rely on the
upstream prepared installation and actual launch evidence, not a VisLlama
hardware-compatibility promise. ARM64/DGX Spark and arbitrary GGUF models are
not established by this integration.

## Register and run

1. Open **Settings → Manage builds → Register another engine type**. Choose
   **Maya — GLM prepared server** and give the installation a name.
2. Set the installation root to the Maya checkout. Select its prepared server
   interpreter: `.venv/Scripts/python.exe` on Windows or `.venv/bin/python` on Linux.
3. Select the separate GLM inference executable: `build/maya.exe`, `build/maya`,
   or the prepared HIP binary `build-hip/maya`. Register the build.
4. In the model editor choose that named build. Import the generated Maya JSON
   using the file picker at the top. Review the alias, pack/catalog path,
   tokenizer, GPUs and native library folders, then adjust the named controls.
5. Save, start Router and load the model. A compatibility probe runs when needed
   at explicit load; saving alone does not run it.

You can also create a preset from already prepared assets: select the pack
directory as the catalog path and fill the tokenizer directory (and select `hip` as the backend for HIP). This creates
configuration, not model packs. Preview the resulting launch before loading.
Cloning retains imported settings and overrides; review GPU and writable-data
paths before running both copies.

## Settings and ownership

The shared editor exposes pack/tokenizer/runtime paths, expert cache and
prefill, context, resident KV window, KV streaming, GPU list and layer boundaries,
request parallelism, per-GPU VRAM reserves, RAM tier/headroom, CPU lane, PCIe
share, read chunks, expert profile and optional prepared DFlash2 drafter.
Tuning fields write into the native JSON's `env` object. No tuning, temperature
or output cap is forced when creating a preset. Imported sampling stays intact.
Use the advanced native JSON/argument array for options outside these controls.

“Native setting” means keep the imported value when present, otherwise let Maya
choose. Clearing an explicit value and restoring inheritance are separate
actions. Current Maya writes `MAYA_*` environment keys. Older `STRATA_*` keys are
preserved in advanced JSON; Maya gives an explicit `MAYA_*` key precedence when
both exist. Review old keys there when removing an older tuning override.

VisLlama runs the prepared `serve/server.py` directly with `--engine strata`
(the upstream server's actual selector), a private JSON, loopback host and
allocated port. It owns the worker alias and native log path, disables worker
API keys and idle unloading, and does not open another browser. Imported API
keys remain in the saved source snapshot but are omitted from the generated
private worker configuration; the existing VisLlama proxy access contract
applies. This adds no authentication to VisLlama.

The imported JSON and unknown nested data, including vision configuration, are
preserved. Direct launch bypasses Maya's setup wrapper and therefore its automatic
rebuild, repack/staleness checks and setup calibration. Repair or update prepared
assets with Maya externally before loading through VisLlama. Prepared vision
components are preserved but are not separately validated by these fixtures.

**Discover this build's options** invokes only the selected inference binary's
bounded `--help`. Additions belong to that installed build, not every Maya
installation. Help confirms option names, not model compatibility or memory fit.

## GPU sharing and writable files

GPU numbers and layer split boundaries remain Maya-native. VisLlama does not
translate them to llama.cpp CUDA ordinals or certify physical placement. Maya's
native fitting is separate from VisLlama Calculated mode; shared free memory can
change between measurement and allocation. No successful fit is guaranteed.

Concurrency remains **unverified**, with the existing explicit opt-in required.
Separate processes/ports do not isolate all native data. Maya's default slot
directory is `<pack>/slots`, which it may clear at startup. The editor exposes
slot directory, persistent expert usage and CPU timing cache paths. Give
simultaneous models distinct writable locations and review imported profile-save
arguments and other native writable paths too. The global setup calibration
cache is not updated by VisLlama; native timing/cache writes remain Maya behavior.

## Source contract and testing

Reviewed upstream sources:

- [Prepared configuration and wrapper](https://github.com/mw00/project-maya/blob/main/maya.py)
- [Server, environment and readiness](https://github.com/mw00/project-maya/blob/main/serve/server.py)
- [Native arguments and help](https://github.com/mw00/project-maya/blob/main/src/program/generate.cpp)
- [Settings](https://github.com/mw00/project-maya/blob/main/docs/SETTINGS.md)

Links lead to upstream source paths; exact reviewed Git blob hashes are recorded
in the definition's evidence. Compatible revisions can share this definition;
installed source/executable fingerprints keep compatibility evidence separate.

`tests/engine_maya.pl` tests registration, imports, rendering, discovery,
creation, validation, health predicates and owned lifecycle with synthetic
process handles. `tests/engine_maya_ui.js` exercises the real page/scripts and
Perl renderer, inherited fields, edits, validation, passive save and clone.
The general engine/Router tests cover mixed-family ordering and engine-only use.
These checks do not establish GPU performance, Windows execution, vision,
concurrent shared-file safety or real inference acceptance.

## Changing GPUs and diagnosing an early exit

Selecting a subset of GPUs is a runtime configuration change; a rebuild is
normally unnecessary when the prepared inference binary already supports those
cards' architectures. Rebuilding is relevant to binary/toolchain compatibility,
not selecting a different subset of supported cards. Changing GPUs does not
change which model assets were prepared.

For two GPUs, review any split inherited from a larger GPU set: use `auto` or
one valid layer boundary for that pair. Native `args` may contain an explicit
`--layer-split`. The named split control replaces that argument when edited.
Also review `env.MAYA_GLM_SPLIT`, `env.STRATA_GLM_SPLIT`, `CUDA_VISIBLE_DEVICES`,
`CUDA_DEVICE_ORDER` and `HIP_VISIBLE_DEVICES`; native configuration can supersede
what a simple GPU list suggests. These are native settings, not verified
VisLlama physical identities. Use Preview to inspect the final configuration.

A process exiting before readiness does not by itself prove VRAM exhaustion,
RAM exhaustion, GPU mapping trouble or a missing dependency. Preserve the failed
instance folder under `logs/instances/engine-*`: `engine.log` contains server
output, `native.log` contains inference-engine output, `config.json` is the
actual generated configuration and `exitcode` records an available native status.
The referenced diagnostics JSON line is an application summary, not a substitute
for those process logs. Do not assume the original imported JSON was the final
runtime configuration. Private artifacts may contain local paths and credentials;
review them before sharing.

## Windows startup argument parsing

Version 1.5.16 corrects a launch-argument defect: Windows PowerShell's legacy
native binder drops a separate empty string, so `--api-key` followed by an empty
value could reach Maya as a flag with no value and cause `server.py` to print
usage and exit before loading any model. The bundled definition now uses the
single token `--api-key=`. The external-engine Windows launcher also preserves
empty native arguments in earlier retained definitions. Existing presets and
local definitions can be retained; a Maya rebuild is not part of this fix.

A `usage: server.py` excerpt is a parser clue, not the complete diagnostic. The
following `server.py: error: ...` line identifies the rejected option. If startup
still fails, preserve that line and the failed instance's `engine.log`. Correct
argument transport does not establish GPU compatibility or memory fit.

PowerShell behavior reference: [Microsoft about_Parsing](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_parsing).
