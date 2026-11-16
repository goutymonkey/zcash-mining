# Zcash mining software and experimental ASIC designs

This repository contains a reference CPU miner for Zcash's Equihash
proof-of-work, experimental ZEQ-200 chip and ZEQ-HB4 board designs, and
tools for checking their correctness. The Zig miner solves Equihash,
verifies solutions, and connects to Stratum pools. The chip has not been
fabricated; the board is a demonstrator design.

Start with [project status and reproducibility](docs/STATUS.md),
[contribution instructions](CONTRIBUTING.md), [licensing](LICENSING.md),
or [security reporting](SECURITY.md).

For a prebuilt candidate, follow the [portable Linux installation guide](docs/INSTALL.md).
Build reproduction and artifact checks are documented in [release packaging](docs/RELEASING.md).

| Directory | Contents |
| --- | --- |
| `src/` | Mining host, CPU solver, RTL/serial backends, verifier and pool client |
| `asic/chip/rtl/` | Synthesizable mining chip designs |
| `asic/chip/{model,tb,formal,pd}/` | Reference models, simulations, proofs and physical-design tools |
| `asic/` | Four-chip board sources in tscircuit |
| `gpu/` | Accelerator interface and CPU reference kernels |

Version **0.6.0** is an ASIC engineering development release. It adds
experimental solver options, all disabled by default: discarding all-zero
intermediate rows, a linear-time distinct-leaf check, several Blake2b units
per engine, write-time key chains in place of the counting sort, a queued
crossbar, a third group buffer and a second pair emitter. On two mainnet
headers at 16 engines the combined candidate retains every reference
solution and takes 58% fewer simulated cycles per attempt than the starting
candidate, for an estimated 26% more area; that estimate is rough and no
timing analysis was run. Zero-row discard with the leaf check retains all 33
reference solutions on 16 headers. The release also fixes a link race that
could corrupt a solution packet when a job abort coincided with it. None of
the new options has synthesis, equivalence or integrated-core qualification
at mainnet parameters. With the options off the solver is cycle-identical
to 0.5.0 on the (48,5) regression corpus.

Production tapeout readiness and competitive power/performance are not
established. Licensed production PDK and SRAM compiler access remain
unavailable. See `asic/chip/production/independent_engineering_review.json`
for the current evidence and the six remaining production priorities.

The exact Plan D demonstrator source snapshot is retained under
`asic/chip/build/plan-d-source/` because its physical-flow configuration
references those files. Other generated builds, physical runs, local PDKs,
and the generated Caravel packaging checkout are excluded from Git.

The CPU miner is intended for learning, experimentation and independent
verification. Use the small-parameter offline demo to get started. There is
no measured production mining performance or profitability claim.

Current development adds a shared CPU/RTL/serial mining interface, an actual
UART RTL simulator, and source-bound local pool acceptance tests. See the
[backend guide](docs/BACKENDS.md) for reproduction commands and limitations.

Consensus basis: `zcash/src/crypto/equihash.{h,cpp}`, `src/pow.cpp`
(`CheckEquihashSolution`), and `src/gtest/test_equihash.cpp` — the Wagner
loop, Blake2b personalization (`"ZcashPoW" || le32(n) || le32(k)`), packing
helpers, and golden test vectors are ported from those files. See
[third-party attribution](THIRD_PARTY_NOTICES.md) for the upstream notices.

## Build (Zig 0.15.2)

```sh
zig build                    # -> zig-out/bin/zcash-miner
zig build test               # solver, protocol and lifecycle unit tests
zig build -Doptimize=ReleaseFast   # optimized executable
./zig-out/bin/zcash-miner --demo --params 48,5
```

If the default Zig cache misbehaves in your environment, override it:

```sh
zig build --cache-dir /tmp/zc --global-cache-dir /tmp/zg
```

## Use

```sh
# Offline demo: solve + verify one instance (default 48,5, instant)
zcash-miner --demo [--params 96,5]

# Verified solve benchmarks (JSONL, default 48,5)
zcash-miner --bench --params 48,5 --iterations 4
zcash-miner --bench --params 200,9 --corpus headers.txt --solutions all

# Verify externally found solutions ("input_hex minimal_solution_hex" per line)
zcash-miner --verify FILE [--params 48,5]

# Pool mining (mainnet params 200,9)
zcash-miner --pool HOST:PORT --user ADDRESS[.worker] [--pass x] \
    [--threads N] [--params 200,9]
```

## Pool experiments

Use the endpoint, username or payout address, and worker format documented
by your chosen pool. Replace the placeholders below; no wallet spending key
or seed phrase is needed. Pool dialects vary, and the CPU reference solver
may take a long time to find a qualifying share.

```sh
./zig-out/bin/zcash-miner --pool HOST:PORT \
    --user ADDRESS.rig1 --threads 1
```

Mainnet parameters require substantial memory per worker. Start with one
thread (the default) and check the resource limits below. The default total
solver allocation budget is 3072 MiB; `--memory-limit-mb` divides that budget
among workers. Pool transport is plain TCP;
see [SECURITY.md](SECURITY.md).

The current development client implements [Zcash ZIP 301](https://zips.z.cash/zip-0301).
Its independent local acceptance tests cover message encoding, header bytes,
proof verification and connection failures. Account-based public-pool testing
is pending. Use `--probe` to check authorization and job parsing without mining.
See [mining operation and verification](docs/MINING.md) for controls, metrics,
benchmarks and the qualification commands.

## How it works

- `src/equihash.zig` — Equihash params, Blake2b hashing with Zcash
  personalization, `BasicSolve` Wagner solver, solution verifier.
- `src/pow.zig` — SHA256d block hash, compact-`nBits` target decoding,
  140-byte header assembly, coinbase merkle root.
- `src/stratum.zig` — pool protocol: subscribe / authorize / notify /
  `set_target` / submit over newline-delimited JSON-RPC.
- `src/mining.zig` — threaded mining, nonce allocation, job-bound targets,
  bounded share queues, reconnects and acknowledged share accounting.
- `src/benchmark.zig` — complete solution-set benchmarks and cancellation
  measurements; `src/budget.zig` enforces worker allocation limits.
- `src/main.zig` — command-line interface.

## Hardware (`asic/`)

- `asic/`: ZEQ-HB4, a 4-chip series-stacked Equihash hashboard in
  tscircuit. Four-layer PCB design; Gerbers and KiCad outputs are generated
  locally and excluded from Git. Series stacking, per-domain power, clocks,
  isolation and the known gaps (no per-domain balancing yet) are covered in
  `asic/README.md`.
- `asic/chip/`: ZEQ-200, the mining ASIC as synthesizable Verilog:
  Blake2b core, hardware Wagner solver(s), share filter, chain protocol,
  memory BIST, and SRAM repair bank. Three configurations of the same
  RTL: ZEQ-200-TC test chip (`(48,5)`, SKY130), ZEQ-200M DRAM die
  (`(200,9)`, external DRAM ports), and ZEQ-200X competitive die
  (`(200,9)`, bucket-parallel projection, up to 512 engines).
  RTL output is checked bit for bit against a Python reference model,
  and every RTL solution also passes `zcash-miner --verify`
  (plus TLA+/Lean/SAT proofs — see `asic/chip/README.md` and
  `asic/chip/formal/README.md`).

Status: recorded RTL checks include mainnet `(200,9)` simulations; full-chip
physical signoff and foundry SRAM mapping are still open, tracked in
`asic/chip/TAPEOUT.md`. The detailed production workstreams are maintained
privately and are not part of this public snapshot.
The October 2 review records a complete 1,486-partition SKY130 Plan H
synthesis-equivalence PASS, which remains ineligible for release packaging.
The current-source 16-header packed mainnet baseline and eight-hash variant
both retain all 33 reference solutions under independent comparison.
Full mainnet generic synthesis completes all 24 mapping batches and retains
288 logical SRAMs with 1,126,852,480 bits. This does not establish production
PPA or full-chip equivalence. The next production milestone is actual SRAM
mapping and a routed compute/memory/network tile with extracted timing,
area and workload power. Ordered decision gates and supplier requirements are in
the private production workstreams and memory-compiler request materials.
The 512-engine die is a model projection, not a measured result, and
the older energy/area scenarios in the chip README are historical —
they do not describe the current RTL. Competitive performance remains
unestablished. Most referenced build evidence is stored outside Git; see
[what a fresh clone can reproduce](docs/STATUS.md#what-a-fresh-clone-can-reproduce).

## GPU path (`gpu/`)

The Wagner-table kernels live behind a C ABI (`gpu/equihash_gpu.h`):
`eq_gen_rows`, `eq_sort_order`, `eq_permute_rows`, `eq_find_buckets`,
`eq_count_pairs`, `eq_combine_bucket`. CPU references in
`gpu/equihash_cpu_ref.c` implement it today (compiled into the Zig
binary by `build.zig`, with Zig↔C byte-identical cross-checks in the
test suite). CUDA/OpenCL device kernels are not implemented yet. The
interface allows them to share the Zig host's protocol and verification code.
Third-party: `gpu/thirdparty/` holds Samuel Neves's BLAKE2 reference under
its original license choices; this distribution uses Apache-2.0.

## Notes and limits

- This is a **reference** CPU solver (like `zcashd`'s `BasicSolve`), not a
  competitive miner. `(200,9)` needs ~2.2 GB RAM per thread and minutes
  per solution attempt; `(96,5)` solves in <1 s; `(48,5)` in ~1 ms.
- Pool dialect follows the nheqminer/flypool convention
  (`mining.submit` = `[user, job, time_hex, nonce_hex, solution_hex]`,
  prevhash/branches byte-reversed from display order). It was verified
  against a mock pool plus a live end-to-end submit test; real pools
  vary, so report issues.
- The pool `set_target` (share difficulty) is kept across jobs; the
  `bits`-derived network target is only a fallback.
- Verification: 22 unit tests (`zig build test`), including zcashd's
  golden vectors for array packing and minimal-solution encoding, a
  Python-`hashlib` cross-check of the Blake2b personalization,
  solver→verifier roundtrips with tamper rejection, Zig↔C ABI
  byte-identical checks (`eq_gen_rows`, sort/permute, buckets, Phase-A
  solve), SHA256d/compact-target/header-layout checks, and
  stratum notify/subscribe/`set_target`/submit plus a mock-pool
  handshake test — plus an end-to-end run of the real binary submitting
  a valid share.

## License

Original software and documentation use [Apache-2.0](LICENSE). Original
chip Verilog/SystemVerilog uses [CERN-OHL-W-2.0](LICENSES/CERN-OHL-W-2.0.txt).
The board package retains [ISC](LICENSES/ISC.txt). Upstream code and tools
keep their own terms. Read [LICENSING.md](LICENSING.md) for the exact scope
and exceptions, and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for
attribution. External foundry and process libraries are not included in
these grants.
