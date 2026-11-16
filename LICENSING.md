# Licensing

Copyright 2026 goutymonkey and contributors, except for the upstream material
identified below. This repository contains software, hardware designs and
third-party tools with different licenses. The path-specific grants below
take precedence over the default license.

| Material | License |
| --- | --- |
| Original software, Python models, scripts, configuration and documentation, unless excepted below | [Apache-2.0](LICENSE) |
| Original Verilog/SystemVerilog (`.v` and `.sv`) under `asic/chip/`, including RTL, testbenches, formal harnesses and the Plan D RTL snapshot | [CERN-OHL-W-2.0](LICENSES/CERN-OHL-W-2.0.txt) |
| Board sources `asic/index.circuit.tsx`, `asic/chip.circuit.tsx`, `asic/lib/`, and the board package's own configuration and documentation (`asic/package.json`, `asic/package-lock.json`, `asic/tsconfig.json`, `asic/README.md`) | [ISC](LICENSES/ISC.txt), preserving the existing board package license; dependency entries retain their own licenses |
| Zcash/Bitcoin-derived portions of `src/equihash.zig`, `src/pow.zig` and `asic/chip/model/equihash_ref.py`, including ported test vectors | [MIT and upstream notices](LICENSES/Zcash-MIT.txt); original additions are Apache-2.0 |
| Caravel-derived `asic/chip/pd/wrapper/src/` and `asic/chip/build/plan-d-source/wrapper-src/` | [Apache-2.0](LICENSE), including the Verilog wrappers; retain Efabless attribution |
| `gpu/thirdparty/` | Upstream choice of CC0, OpenSSL or Apache-2.0; this distribution uses the Apache-2.0 option and retains the original headers |
| `asic/chip/formal/tla/tla2tools.jar` | TLA+ Tools and bundled dependencies retain their upstream licenses; see [third-party notices](THIRD_PARTY_NOTICES.md) |
| Verilator runtime linked into generated `zeq-host-sim` executables | Upstream LGPL-3.0-only or Artistic-2.0; this distribution selects [Artistic-2.0](LICENSES/Artistic-2.0.txt), with [runtime notices](THIRD_PARTY_NOTICES.md#verilated-simulator-runtime) |
| Zig runtime and musl libc linked into portable Linux miner binaries | [Zig MIT](LICENSES/Zig-MIT.txt) and [musl notices](LICENSES/musl-COPYRIGHT.txt), with [runtime provenance](THIRD_PARTY_NOTICES.md#portable-miner-runtime) |

The board's earlier ISC grant is not replaced by a reciprocal hardware
license. The root Apache license does not relicense third-party material or
the hardware identified above. License texts themselves retain their own
copyright notices.

## Hardware notice

The original Verilog/SystemVerilog identified in the table is Covered Source
under CERN-OHL-W-2.0. Source location:
<https://github.com/goutymonkey/zcash-mining>.

You may redistribute and modify that Covered Source and make products using
it under CERN-OHL-W-2.0. It is provided without warranty, including warranties
of merchantability, satisfactory quality and fitness for a particular
purpose. Read the full license for the conditions governing modified source,
products, notices and source availability. This notice makes no claim that
the current designs are manufacturing-ready.

Some source files are bound to recorded verification hashes. Licensing and
attribution are supplied here and in [NOTICE](NOTICE) without changing those
source bytes. When redistributing such files, include the applicable license
texts, this scope document and the relevant third-party notices. New source
files should include an appropriate SPDX license identifier.

## External process data and contributions

These grants cover material in this repository. They do not grant rights to
external PDKs, SRAM compiler outputs, standard-cell libraries, EDA tools,
foundry data, or trademarks. Obtain external dependencies under their own
terms; do not add restricted material to this repository.

Contributions follow the license of the material being changed. Preserve
upstream notices and identify the source and license of imported material.
See [CONTRIBUTING.md](CONTRIBUTING.md).
