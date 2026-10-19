# GPU provider parser fixtures

These are synthetic, source-derived records with invented names/identifiers,
not captures from AMD/Intel hardware. No sensor or placement validation is implied.

Schema provenance reviewed 2026-10-15:

- AMD `amdsmi_cli/amdsmi_commands.py`, file SHA
  `9669683891e5c4bec8b12db5b7b5af028bc7b61f`, and logger file SHA
  `eaddb81e77ee116c3289dbde78ffd87623ee2db6`:
  <https://github.com/ROCm/amdsmi/tree/amd-mainline/amdsmi_cli>.
  JSON arrays use lowercase fields and `{value,unit}` measurements. `mem_usage`
  divides bytes by 1024*1024 before labeling values MB. Fan `usage` is percentage;
  `speed` and `rpm` are not. Active `limit.ppt0.socket_power_limit` is distinct
  from maximum power. `power.socket_power` is the supported current schema.
- ROCm `python_smi_tools/rocm_smi.py`, file SHA
  `be1da99de97cda0040ddac6d1b93d3f5c18d2b05`:
  <https://github.com/ROCm/rocm_smi_lib/tree/amd-staging_deprecated/python_smi_tools>.
  JSON `cardN` keys carry explicitly labeled bytes, percentages, C and W.
  Unique ID is a hexadecimal value, not an AMD-SMI UUID. Maximum package power
  is deliberately omitted from the canonical active-cap field.
- Intel `ial/cmn/cmd_discovery.cpp`, file SHA
  `1b784ee75bca365d8803e5a6c65ece44a28d5296`, `cmd_stats.cpp`, file SHA
  `26819268d0ce6a76c6beb138922e34c79efdec95`, and `metrics/memory.cpp`, file SHA
  `013d1baf3cb4b959e467c7dc5805b782a057997e`:
  <https://github.com/intel/xpumanager/tree/main/ial/cmn>.
  Discovery uses `device_list`, including null on no devices, and GPU types
  `Discrete GPU`/`Integrated GPU`. Detailed properties include byte capacity
  and tile count. Stats uses `device_index`, `pci_bdf`, and per-tile metrics;
  only proven single-tile readings become device measurements. Unvalidated
  older XPUM_STATS JSON families fail closed.
- Intel field-query CSV syntax, units and semantics:
  <https://intel.github.io/xpumanager/2.0/xpu-smi/overview.html>.

Full upstream source was inspected as development evidence, not copied into
the application. New vendor parsers are independent Perl implementations.
`nvidia-baseline.json` pins the existing collector, isolation and planner bytes.

Fixtures exercise the documented/source-derived families. Real normal-user
outputs for exact OS/tool/driver/device combinations remain required acceptance
evidence and may reveal additional schemas that must not be guessed at runtime.
