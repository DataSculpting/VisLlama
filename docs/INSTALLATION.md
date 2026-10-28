# Installation and setup

[Back to README](../README.md)

## Package layout

Keep both entry scripts and `lib/`, `templates/`, `public/`, `engines/` together. Use a writable
installation directory. VisLlama creates `presets/` and `logs/` for host-specific
configuration and private runtime output. These directories are not part of the
published source package. Never run two controllers against one installation.

The application needs Perl, a browser and a separately installed supported engine.
llama.cpp uses GGUF model files; other engines require their own prepared inputs. No npm installation or frontend compilation is needed to run
VisLlama. Node dependencies in `tests/` are for development checks only.

## Windows

If not already installed in your system, install
[Strawberry Perl](https://strawberryperl.com/) before running VisLlama. Download
the Windows MSI installer appropriate for your system and run it. Open a new
PowerShell window after installation and verify:

```powershell
perl -v
```

If PowerShell cannot find `perl`, check that the installed Perl `bin` directory
is on your PATH and reopen PowerShell. The module check below verifies that the
interpreter you are actually using has the required modules.

Use Strawberry Perl with thread support, `Win32::Process` and `Win32API::File`,
and Windows PowerShell 5.1. Obtain a llama.cpp build containing `llama-server.exe`
and its required adjacent DLLs. Keep each build in its own complete directory.

From PowerShell in the VisLlama installation directory:

```powershell
perl -Mthreads -MHTTP::Tiny -MJSON::PP -MWin32::Process -MWin32API::File -e 1
if ($LASTEXITCODE) { throw 'Missing Perl prerequisites' }
perl .\VisLlama.pl
```

If a module is missing, install it for the Perl interpreter used to launch
VisLlama. Open the management URL printed in the console, normally
<http://127.0.0.1:9090/>. Keep that console running while using the application.

### Windows GPU support: NVIDIA, AMD and Intel

#### NVIDIA selection

Explicit CUDA isolation needs working NVIDIA-SMI and exactly one `cudart64*.dll`
adjacent to the selected executable. The private PowerShell identity probe uses
`Add-Type` to join CUDA PCI bus addresses to driver UUIDs. Host policy must allow
that probe. It is not necessary to install a Python service or a separate GPU
administration service. Ambiguous runtime DLLs or failed UUID verification block
explicit placement rather than silently selecting another GPU.

#### AMD and Intel

Use a native llama.cpp build with the appropriate GPU backend. Its
`llama-server --list-devices` output remains the source for model-editor device
choices. Monitoring tools do not replace that list or select inference devices.

VisLlama automatically checks already-installed `amd-smi.exe`, `rocm-smi.exe`
and `xpu-smi.exe` on explicit PATH directories. A tool must run successfully and
produce a supported output schema; merely finding its executable is insufficient.
No tools, SDKs, drivers or other dependencies are bundled or installed by VisLlama.
If a tool is not found, add its existing installation directory to the launch
account's PATH and restart VisLlama. Do not copy executable names into the model
folder. Hardware Stats shows each provider's readiness and safe failure reason;
Refresh status requests another check without changing model settings.

The reviewed AMD-SMI/ROCm-SMI interfaces target Linux; native Windows AMD CLI
parity is not established. Missing Windows AMD telemetry is a supported outcome,
not proof that the selected llama.cpp AMD backend cannot run. Intel XPU-SMI has
Windows builds, but the vendor matrix currently lists Windows Server 2022/2025
and selected devices; Windows client editions and other Intel GPUs need actual
tool/driver/hardware validation. See the
[Intel project compatibility list](https://github.com/intel/xpumanager).

AMD/Intel telemetry is additive and may be partial. Unsupported fan, power,
temperature or memory readings appear as N/A. Device/provider indices are not
llama.cpp ordinals. AMD/Intel physical isolation is not verified in this release:
existing native selections remain available without a claim of verified physical
mapping. Even split and priority modes retain their existing CUDA-only checks.

## Linux

### Install Perl on Ubuntu

If not already installed in your system, install Perl before running VisLlama:

```bash
sudo apt update
sudo apt install perl
perl -v
```

Use Ubuntu's full `perl` package, not only a minimal `perl-base` installation.
The module check below verifies the runtime prerequisites. For other Linux
distributions, install Perl using that distribution's package manager.

Use a thread-enabled Perl with its standard modules, including `HTTP::Tiny`,
`JSON::PP`, `Digest::SHA` and `IO::Socket::INET`. Obtain a working executable
`llama-server` build with its required libraries. Keep `/proc` mounted and readable
for process ownership checks and CPU/RAM sampling. Windows Perl modules and
PowerShell are not required on Linux.

From a terminal in the installation directory:

```bash
perl -Mthreads -MHTTP::Tiny -MJSON::PP -MDigest::SHA -MIO::Socket::INET -e 1
perl ./VisLlama.pl
```

Run as an ordinary user with write access to the installation and read/execute
access to models, builds and applicable GPU devices. Ensure `llama-server` is
executable. Normal `bin/` layouts are supported; Linux paths are case-sensitive.
Open the printed management URL, normally <http://127.0.0.1:9090/>.

### Linux NVIDIA selection

Explicit selection requires `nvidia-smi`, the NVIDIA driver, and `cc` with libc
development headers to compile a small helper under `logs/`. A separate CUDA
SDK/toolkit is not required for this helper. VisLlama traces the selected build's
actual CUDA linkage through the GNU loader, verifies the loaded runtime and joins
PCI bus addresses to physical UUIDs. Shared runtimes and accessible static-runtime
symbols in a shared backend are supported. Hidden fully static runtimes and
non-GNU tracing environments are unsupported for explicit isolation. Native
fitting without explicit CUDA selection remains available.

Linux lifecycle operations use owned process groups and bounded TERM/KILL.
Children that deliberately detach outside their group are unsupported. Forced
controller termination can bypass cleanup. Real Linux hardware/process acceptance
requires host-specific testing; see the development guide.

### Linux AMD and Intel monitoring

VisLlama probes existing `amd-smi`, with `rocm-smi` as a fallback, and `xpu-smi`.
It checks explicit PATH directories and bounded known ROCm locations rather than
assuming a complete ROCm/oneAPI installation. Native inference does not require
these monitoring tools. Both vendors can report alongside NVIDIA on a mixed host.

AMD-SMI JSON records with explicit value/unit measurements and ROCm-SMI card JSON
are supported. Intel uses supported `--query-gpu` CSV fields or its separately
validated detailed-discovery/stats JSON family. Unrecognized older JSON layouts
are reported as unsupported rather than guessed. Intel JSON tile measurements
are used as device readings only when discovery proves a single tile; unsupported
domains remain N/A. No cross-vendor capacity/power total is calculated.

Run the tools under the same account as VisLlama. Discovery may succeed while
individual sensors are denied. VisLlama reports this without elevating privileges
or installing missing libraries/interpreters. AMD's existing CLI uses Python
internally; this does not introduce a VisLlama Python backend. See the
[AMD prerequisites](https://rocm.docs.amd.com/projects/amdsmi/en/latest/install/install.html)
and [Intel CLI documentation](https://intel.github.io/xpumanager/2.0/xpu-smi/overview.html)
for the system tool's own compatibility requirements.

Missing tools, WSL and unvalidated output are nonfatal provider statuses. WSL is
not treated as native Windows support. AMD/Intel verified physical isolation and
new non-CUDA Calculated planning remain unavailable; existing llama.cpp selection
and native fitting behavior are preserved. Source-derived parser fixtures do not establish AMD/Intel host compatibility.

## Linux Docker images

Native executable builds remain supported. In **Manage builds**, click
**Add Docker Images** immediately left of Close. The view switches to two fields:
**Build alias** and **Build image**. Enter an image reference such as
`scitrera/dgx-spark-llama-cpp:latest`, not a complete `docker run` command. The
same button switches back to native builds. Docker entries are Linux-only.

One saved native or Docker alias satisfies initial setup; no discovery root is
required. Deleting the last unreferenced alias reopens setup and disables starts.
Stop any managed runtime using the build before removal. The last alias also
requires all managed serving to be stopped. A build used by saved model presets
cannot be removed: reassign or delete those
model presets first. Renaming a build updates their saved alias references.
Removing an alias does not delete the Docker image from the host image cache.

Docker must use a local Unix-socket Linux daemon and be accessible to the account
running VisLlama. For NVIDIA hardware, configure the NVIDIA container runtime;
VisLlama supplies GPU access when the host NVIDIA device is present.
VisLlama does not invoke sudo itself.

### Docker access on Ubuntu

Before starting VisLlama, check Docker access from the same user account:

```bash
docker ps
```

If this reports permission denied for `/var/run/docker.sock`, but
`sudo docker ps` works, add your intended VisLlama user to the Docker group:

```bash
sudo usermod -aG docker "$USER"
```

Run this from that user's terminal; for a different account, replace `"$USER"`
with its username. If the `docker` group does not exist, create it first with
`sudo groupadd docker`. Log out and back in, then confirm `docker ps` works
without sudo. Restart VisLlama from the new login session and refresh devices.
An already-running controller does not acquire the new group membership.

Docker group membership grants root-level Docker privileges. See Docker's
[official Linux post-installation guide](https://docs.docker.com/engine/install/linux-postinstall/).
Keep using a consistent account so configuration and logs remain writable.

### Image behavior and GPU placement

The image must contain llama-server with native Router support. Missing images
are pulled with a bounded wait; an initial download can take time. Build Details
runs version/help/device probes, preserving the startup banner in raw output and
showing parsed device rows. Image metadata determines whether flags go directly
to a server entrypoint or follow an explicit llama-server command through a
wrapper. Image IDs pin probes and serving to a resolved runtime.

VisLlama creates one Router container per build/ordered GPU group. It uses Linux
host networking so native child-server loopback connections behave consistently.
The public Perl proxy stays on the host. Models, presets, referenced files and
logs are mounted automatically at the same absolute host paths: no container
models path is entered. Models/presets are read-only mounts; logs/cache are writable.
A new external-file directory or image change can require a Router restart.

Explicit GPU selection uses the existing UUID verification, but traces the image's
CUDA runtime and runs the identity helper inside it. This needs the existing host
C compiler/helper prerequisites and compatible host/image Linux architecture and
libc ABI. Unsupported linkage/ABI fails with a diagnostic reference; host CUDA
ordinals are not substituted for container IDs. Keep no explicit device selection
for an initial native-fitting test if isolation prerequisites are not met.

Integrated Docker startup/loading/reload/cleanup and real container UUID placement
require host-specific validation. Shared-memory systems can report total/free
memory differently from discrete GPUs; no UMA-specific planner is provided.

## First setup on either platform

1. In Initial setup or Settings, register a named engine build and installation.
   llama.cpp discovery proposes builds; saving an entry makes it configured.
2. For llama.cpp presets, set the GGUF root folder in Settings. This global root
   is optional for extension engines, which use their own prepared paths.
3. Configure the Router service host and port. Its saved service settings are
   separate from model settings.
4. In Manage Models, add a named preset and choose its engine build. Select the
   GGUF for llama.cpp, or import/configure the extension engine inputs. Configure
   model settings and review the preview.
5. Save the preset. Enable startup loading if desired; reorder the single catalog
   table to determine startup order across all builds/groups.
6. Start Router, check readiness and load the desired model before opening Chat.

File pickers browse the machine running VisLlama, not the browser's computer.
Moving Windows presets to Linux does not translate drive paths automatically.
Configure the new host's locations and revalidate GPU selections.

## Management URL and inference URL

The default management UI is `http://127.0.0.1:9090/`. Inference clients use the
public Router endpoint displayed by VisLlama, which is a separate address/port.
OpenAI-compatible client base URLs generally include `/v1`; Chat Completions is
`/v1/chat/completions` and the model listing is `/v1/models`. Follow a client's
base-URL convention rather than appending `/v1` twice. Use the public endpoint,
not a child engine's temporary loopback port.

A remote browser must be able to reach the configured inference host/port; its
`127.0.0.1` refers to the browser's machine. HTTPS pages can block HTTP inference
as mixed content. The management interface has no authentication: do not expose
it to untrusted networks. Router CORS support does not supply authentication.

## Upgrades and backups

Stop VisLlama and its managed serving processes before replacing files. Back up
`presets/` and `logs/`, then replace the entry scripts and the complete runtime
directories from the new package, retaining the backed-up state. Replace bundled
assets together with their third-party notices. Restart and refresh the browser.
Configuration formats and saved UI values are preserved in this release.

Chat history lives in the browser's local storage, not `presets/`. Export it from
Chat before clearing browser data or changing the management URL's origin.

## Additional native engines (experimental)

Prepared engines can be registered by explicit engine type using **Register
another engine type** in the build dialog. One definition covers compatible
versions at multiple installation paths. No engine installation/setup is run.
Read [ENGINES.md](ENGINES.md) before importing a native config. Preserve local
definitions under `presets/engines/` during upgrades; replace bundled `engines/`
with the application files. Edit retained definitions through Manage builds;
`presets/engines/` holds local bases and build-specific additive files. Strata
compatibility depends on the prepared installation and model. Registration does
not verify GPU placement or concurrent mixed-engine fitting.

Maya GLM installations use a bundled definition; see [Maya](MAYA.md). Prepare and
verify Maya externally, then register its interpreter and native GLM binary.
