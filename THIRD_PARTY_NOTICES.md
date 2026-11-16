# Third-party provenance and notices

The original project license does not replace the licenses listed here.
Keep these notices and the corresponding license texts when redistributing
the affected material. Dependency license metadata in the npm lockfile is
also retained.

## Zcash and Bitcoin

`src/equihash.zig` ports the Zcash Equihash solver, verifier, packing helpers
and test vectors. `src/pow.zig` ports proof-of-work and compact-target
behavior. `asic/chip/model/equihash_ref.py` ports the independent solution
verifier and packing helpers. These ports contain upstream MIT-licensed
material; project additions use Apache-2.0.

The upstream references include `src/crypto/equihash.cpp`,
`src/crypto/equihash.h`, `src/gtest/test_equihash.cpp`, `src/pow.cpp` and
`src/arith_uint256.cpp` in [zcash/zcash](https://github.com/zcash/zcash).
Copyright holders include Jack Grigg, the Zcash developers, Satoshi Nakamoto
and the Bitcoin/Bitcoin Core developers; the notices are reproduced in
[NOTICE](NOTICE) and [the upstream MIT license](LICENSES/Zcash-MIT.txt).

The original port did not record an exact upstream revision. For this
publication review, headers and the license were checked against
[`558f686599586f55def3db86955d74d3be44605e`](https://github.com/zcash/zcash/tree/558f686599586f55def3db86955d74d3be44605e).
That is an attribution reference, not a claim about the port's source commit.

## BLAKE2 reference implementation

`gpu/thirdparty/blake2b-ref.c`, `blake2.h` and `blake2-impl.h` contain
Samuel Neves's reference implementation, copyright 2012. Each header offers
a choice of CC0, the OpenSSL license, or Apache-2.0. This distribution uses
the [Apache-2.0](LICENSE) option; the original multi-license grant is preserved.
Upstream: [BLAKE2](https://github.com/BLAKE2/BLAKE2).

## Caravel integration

The wrapper sources and constraints under `asic/chip/pd/wrapper/src/`, and
their immutable copies in `asic/chip/build/plan-d-source/wrapper-src/`, use
materials from [caravel_user_project](https://github.com/efabless/caravel_user_project).
The original Verilog headers credit Efabless Corporation, copyright 2020,
under Apache-2.0. The project modifies the wrapper to instantiate ZEQ-200 and
adapts timing constraints for its asynchronous interfaces. These files remain
Apache-2.0 even though other project Verilog uses CERN-OHL-W-2.0.

## Bundled TLA+ Tools

`asic/chip/formal/tla/tla2tools.jar` is an upstream TLA+ Tools build. Its
manifest records version `2.0 2026-09-25` and revision
[`8f4bc8b73ad1202774a6bf70143436f8ba50aab0`](https://github.com/tlaplus/tlaplus/tree/8f4bc8b73ad1202774a6bf70143436f8ba50aab0).
Its SHA-256 is
`ab4694601923fd5ac06452abbf847c366a5054a3d739552085edd6ed986c29ec`.
The JAR has not been modified for this publication preparation.

The distribution preserves the legal files inside the JAR and provides
byte-identical copies of its top-level notices in [LICENSES/tla2tools/](LICENSES/tla2tools/):

| Embedded notice | Copy in this repository |
| --- | --- |
| `License.txt` — Microsoft Research, MIT | [MIT.txt](LICENSES/tla2tools/MIT.txt) |
| `META-INF/LICENSE.md` — Eclipse Public License 2.0 | [EPL-2.0.txt](LICENSES/tla2tools/EPL-2.0.txt) |
| `jline-LICENSE.txt` — JLine, BSD-3-Clause | [JLine-BSD-3-Clause.txt](LICENSES/tla2tools/JLine-BSD-3-Clause.txt) |
| `CommonsMath-LICENSE.txt` — Apache-2.0 | [CommonsMath-LICENSE.txt](LICENSES/tla2tools/CommonsMath-LICENSE.txt) |
| `CommonsMath-NOTICE.txt` | [CommonsMath-NOTICE.txt](LICENSES/tla2tools/CommonsMath-NOTICE.txt) |

TLA+ source and build instructions are available at the revision above.
Sources for bundled Eclipse components are available from
[LSP4J](https://github.com/eclipse-lsp4j/lsp4j) and
[Xtext](https://github.com/eclipse-xtext/xtext). These components retain their
own terms; the repository-wide Apache grant does not apply to the JAR.

The upstream build's
[dependency list](https://github.com/tlaplus/tlaplus/blob/8f4bc8b73ad1202774a6bf70143436f8ba50aab0/tlatools/org.lamport.tlatools/.classpath)
also identifies the following bundled libraries:

- Jakarta Mail API 1.6.8: [source](https://github.com/eclipse-ee4j/mail),
  [license](LICENSES/tla2tools/mailapi-LICENSE.md) and
  [notices](LICENSES/tla2tools/mailapi-NOTICE.md). The copied notices and
  [specification notice](LICENSES/tla2tools/mailapi-speclicense.html) were
  extracted from the dependency JAR at the recorded TLA+ revision. The
  distribution uses its EPL-2.0 option; source availability and the
  conditional secondary-license terms are described in those notices.
- Gson 2.14.0: [source](https://github.com/google/gson), Apache-2.0.
- prettier4j 0.3.2: [source and license](https://github.com/opencastsoftware/prettier4j/tree/v0.3.2),
  Apache-2.0.

The TLA+ source revision links its dependency JARs, and those dependencies'
source repositories provide their corresponding source and build history.
Use the dependency versions recorded there when rebuilding this artifact.

## Verilated simulator runtime

Generated `zeq-host-sim` executables link the unmodified Verilator runtime,
including `verilated.cpp` and `verilated_threads.cpp`, from
[Verilator v5.052](https://github.com/verilator/verilator/tree/v5.052/include).
Runtime headers credit Wilson Snyder and contributors (2003–2026) and offer
`LGPL-3.0-only OR Artistic-2.0`. This distribution selects the
[Artistic-2.0 option](LICENSES/Artistic-2.0.txt) for that runtime. The license
text is copied from the pinned upstream release. Runtime source is available
at the versioned link above and in the separately obtained pinned build image.
Retain this notice and license with simulator artifacts. This does not change
the Apache-2.0 bridge software or CERN-OHL-W-2.0 RTL licenses.

## Portable miner runtime

Portable Linux miner builds include Zig 0.15.2 standard-library/compiler
runtime code under [Zig's MIT license](LICENSES/Zig-MIT.txt), and musl libc
from that Zig toolchain under the notices in
[musl-COPYRIGHT.txt](LICENSES/musl-COPYRIGHT.txt). These files are copied from
the pinned Zig distribution. Upstream sources are available from
[Zig 0.15.2](https://github.com/ziglang/zig/tree/0.15.2) and its
[bundled musl tree](https://github.com/ziglang/zig/tree/0.15.2/lib/libc/musl).
Keep these notices with the statically linked executable.

## Dependencies obtained separately

Zig, NumPy, tscircuit and its npm dependencies, Docker images, Verilator,
Yosys, EQY, SymbiYosys, Lean, LibreLane, Caravel and process libraries are
separate projects with their own licenses. Installation or build scripts
do not relicense them. Generated artifacts may have additional license or
redistribution requirements inherited from those inputs.

No production PDK, proprietary SRAM compiler, foundry signoff deck or
supplier quote is supplied by the project license.
