# Project status and reproducibility

This project combines a reference CPU miner, experimental Equihash ASIC
designs, a four-chip board design, and engineering verification tools.
The latest tagged release is **v0.6.0**. The chip has not been fabricated.
Current development adds ZIP 301 protocol corrections, bounded mining workers,
acknowledged share accounting, all-solution enumeration and benchmark tooling.
See the [launch deliverables](LAUNCH_PLAN.md) and [mining guide](MINING.md).

| Area | What is available | What remains open |
| --- | --- | --- |
| CPU miner | Zig solver/verifier, independent local share acceptance, ZIP 301 client, measured solution enumeration | Account-based public-pool validation, long soak, competitive performance |
| Device host | Common CPU/RTL/serial interface, bounded framing, independent host verification, actual UART RTL integration and pseudo-terminal serial tests | Broader hardware qualification, physical serial adapter and fabricated chip testing |
| ASIC logic | Synthesizable Verilog, mainnet-parameter simulation records, independent reference models | Complete full-chip equivalence and production implementation |
| Synthesis | Recorded full mainnet generic synthesis with 288 logical SRAMs | Mapping to production SRAMs and standard cells; measured physical area, timing and power |
| Formal verification | Component proofs and scoped N48 coverage of 1,342/1,343 recorded obligations | The remaining obligation and a complete qualifying full-design proof |
| Board | tscircuit sources for a four-chip demonstrator | Domain balancing, characterized power/cooling, validated production parts and controller integration |
| GPU | C ABI and CPU reference kernels | CUDA/OpenCL device kernels |

The recorded sixteen-header baseline and eight-hash-engine variant retain all
33 reference solutions. This is a finite simulation corpus. The 512-engine
architecture and production throughput/power figures are projections or
targets, not measurements of fabricated hardware.

## What a fresh clone can reproduce

The [contribution checks](../CONTRIBUTING.md#local-checks) build the CPU miner,
run its unit tests and exercise the Python verification tooling. CI uses
Zig 0.15.2 and Python 3.11. Hardware simulations and proofs have additional
tools and longer runtimes documented in the [chip README](../asic/chip/README.md)
and [formal README](../asic/chip/formal/README.md).

Most `asic/chip/build/` results, logs, solver traces, generated netlists,
physical runs and local process libraries are **not distributed in Git**.
References to those paths in documentation and `production/*.json` are
historical evidence references, not downloadable artifacts or a promise that
the path exists in a fresh clone. A hash identifies an artifact; it does not
make the artifact available or independently establish its result.

The exception is `asic/chip/build/plan-d-source/`, a source snapshot retained
because a physical-flow configuration references it. Its manifest binds the
original bytes. Licensing notices are supplied separately to preserve those
hashes. The snapshot alone is not a completed physical implementation.

Reproduce an experiment in a new build directory with its stated source,
toolchain, parameters and workload. Report a new result instead of editing
historical records. Board Gerbers, rendered images and KiCad exports must
also be generated locally; they are excluded from the source repository.

## Path to production

The [tapeout record](../asic/chip/TAPEOUT.md) and a private readiness review
track the remaining gates: licensed PDK/SRAM access, complete equivalence,
production test/repair, physical signoff, packaging, power delivery and
thermal validation. Publishing the source or passing CI does not close
those gates. No foundry submission or manufacturing release is included.
