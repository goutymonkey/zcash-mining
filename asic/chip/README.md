# ZEQ-200: Equihash mining ASIC (RTL)

The logic of the ZEQ-200, the chip on the ZEQ-HB4 hashboard
(`../index.circuit.tsx`). It's synthesizable Verilog that solves Zcash's
Equihash proof of work (**mainnet (200,9) included**) and speaks the
daisy-chain protocol the board wires up.

This is an experimental design; no ZEQ-200 chip has been fabricated.
See [current status and evidence availability](../../docs/STATUS.md) before
using historical figures below. Most referenced `build/` artifacts are
outside Git. Original RTL and HDL test/formal sources use CERN-OHL-W-2.0;
software and upstream exceptions are covered by the
[license map](../../LICENSING.md).

There are three configurations of the same RTL:

| | ZEQ-200-TC (test chip) | ZEQ-200M (DRAM die) | ZEQ-200X (competitive die) |
|---|---|---|---|
| Top | `rtl/zeq200_tc.v` (pins: `rtl/zeq200.v`, same as `../lib/ZeqAsic.tsx`); shuttle wrapper `rtl/zeq_caravel_wrapper.v` | `rtl/zeq200m.v` | `zeq_eh_par` with P = 512, one instance per die |
| Equihash | (48,5) | **(200,9)** | **(200,9)** |
| Solver | bucket-parallel `zeq_eh_par`, 2 engines, 8 banks | streaming `zeq_eh_solver3` | bucket-parallel, 512 engines, 4096 banks |
| Tables | on die: 18 SKY130 SRAM macros + flops | external DRAM ports (~0.4 GiB per lane) | on die: 217.3 MB logical SRAM (640-slot compact configuration) |
| Process | SKY130, open PDK: see [TAPEOUT.md](TAPEOUT.md) | advanced node + DRAM IP | advanced node (projection) |
| Status | Digital and synthesis evidence; historical routing stopped, physical signoff open | RTL verified at (200,9) | RTL evidence at P = 16; production mapping, PPA and release qualification open |

## Blocks

| File | Block | What it does |
|---|---|---|
| `rtl/zeq_blake2b.v` | Blake2b | RFC 7693 compression, 4 G units in parallel. `SPLIT` = 1/2/4 sets how much of G runs per cycle (24/48/96 cycles per block); SPLIT=4 fits a 130 nm cycle. |
| `rtl/zeq_eh_hash.v` | Leaf hash | Zcash personalization. Block 0 of the 144-byte message is compressed once per job (midstate). Abortable. |
| `rtl/zeq_eh_solver3.v` | **Streaming Wagner solver** | Table reads streamed with up to D in flight per port; no histogram pass (fused into row creation, two on-chip banks); pipelined sort walk; early repeat rejection; drains in-flight reads on cancel |
| `rtl/zeq_eh_par.v` | **Bucket-parallel solver (ZEQ-200X)** | P engines, each with its own table banks. Rows are scattered by the top BB key bits over a P×P crossbar (`rtl/zeq_xbar_arb.v`, round-robin, proven fair), so each engine sorts and pairs only its own buckets. Write-time histograms, pipelined phases, double-buffered groups, a shared expansion unit. |
| `rtl/zeq_ram.v`, `rtl/tech/sky130/zeq_ram.v` | Memories | Generic 1W1R RAM, and its SKY130 version tiled from OpenRAM macros (flops when ≤ 4 kbit); each has a March C− BIST port |
| `rtl/zeq_mbist.v` | Memory BIST | March C− (10N): detects stuck-at, transition, address-decoder and coupling faults (`./run.sh mbist` injects each class) |
| `rtl/zeq_sha256.v`, `rtl/zeq_share.v` | Share filter | SHA256d of header + solution, compared against the pool target: only shares go up the chain |
| `rtl/zeq_eh_solver2.v`, `rtl/zeq_eh_solver.v` | Reference solvers | The same algorithm with one access at a time (v2: port-based, v1: plain arrays). Kept as simple, independently verified references. |
| `rtl/zeq_sfifo.v`, `rtl/zeq_fifo.v` | FIFOs | Solver stream buffers; the RI packet buffer (synchronous read, maps to SRAM) |
| `rtl/zeq_uart.v` | UART | 8N1, resynchronizes on every start bit (each chip has its own oscillator) |
| `rtl/zeq_link.v` | Chain link | Protocol, job IDs, lane dispatch, CI→CO re-drive, RI→RO forwarding with round-robin and flow control, busy chain, over-temperature |
| `rtl/zeq200_core.v` | Core | Link + LANES × (hash + solver + share filter); `ARCH` 0 = streaming solver (tables on chip or on ports, `EXT_MEM`), 1 = bucket-parallel |
| `rtl/tech/sky130/zeq_sram_port.v` | SKY130 memories | Tiles OpenRAM `sky130_sram_2kbyte_1rw1r_32x512_8` macros behind the same port |

### How the solver works

Each attempt (one nonce) runs Wagner's algorithm over K rounds. Rows never
carry index lists. A level-r row stores its remaining hash bits plus two
pointers to its level r−1 parents, so the tables are:

```
VAL  2 banks x CAP x N bits    (ping-pong: level r-1 read, level r written)
PTR  (K-1) x CAP x 2*RW bits   (parent pointers)
ORD  CAP x RW bits             (this round's sort order)
HIST 2 banks x 2^CB x CW bits  (on die: this round's counts / next round's)
```

A round is a stable counting sort by the next collision chunk (prefix sum
over HIST, then a scatter into ORD), then a walk in sorted order that pairs
rows within each collision group. Each new row's next-round key is known
the moment it's created, so the next histogram is accumulated right then
instead of in a separate pass. Final-round collisions are expanded down
the pointer tree to 2^K leaf indices, put in zcash canonical order, and
checked for repeats.

Three measured design decisions:

- **Group cap GMAX = 16.** Solutions come disproportionately from large
  collision groups. With GMAX = 8 the chip found only **41%** of the
  solutions a near-complete solver finds at (200,9) (7 vs 17 over 12
  nonces). GMAX ≥ 12 recovered all of them on the nonces tested.
  (`model/yield_check.py`)
- **Early repeat rejection.** At (200,9), 1,399 of 1,400 final-round
  candidates repeat a row within the top two expansion levels (1,383 at the
  very first). Checking 4 and then 8 rows before the full 510-pointer walk
  removes almost all of that work, with identical output.
- **Fused histogram.** It removes a full read of every level: −33% VAL
  reads.

## Chain protocol

```
down  A5 | type | addr | len (LE16) | payload | crc8      addr FF = broadcast
up    5A | type | addr | len (LE16) | payload | crc8      crc8 poly 0x07 over type..payload

01 JOB     job id + 140-byte input       81 SOLUTION  job id, attempt (LE24), 2^K indices (BE32)
02 STOP                                  84 PONG      version, status, sensor code, lanes
03 SET_OT  over-temp threshold           85 DONE      job id, attempt (LE24), solution count
04 PING
05 SET_TARGET  32-byte share target (BE)
06 BIST        memory self-test; result in PONG status {bist_fail, bist_done, busy, temp}
```

- **Delivery.** Every chip re-drives CI onto CO. Replies travel up RO→RI
  whole: forwarded and own packets alternate packet by packet.
- **Command timing.** Command lengths must exactly match their type. While
  receiving a command, Plan H abandons it after `32 * (10 * DIV + 8)` core
  clocks without a decoded byte. At 40 MHz and `DIV=16`, that is 134.4 us.
  A controller should queue each complete frame to a buffered UART (the
  largest command, JOB, is 147 bytes including framing and CRC), keeping
  decoded-byte intervals comfortably below that limit. After an interrupted
  frame, allow at least the timeout plus clock/synchronizer margin before
  retrying. Framing-like bytes in a valid payload do not restart the parser.
  Cycle-level timeout boundaries are tested; a physical controller transport
  and its worst-case inter-byte gaps have not been qualified.
- **Flow control.** The RI buffer holds two maximum-size packets, and a
  chip starts its own packet only while that buffer is at most half full.
  The four-chip chain must strap addresses 0,1,2,3 from controller to tail.
  Aggregate byte pacing reserves capacity for preceding chips: address 0
  uses the full line, and 1/2/3 use approximately 3/4, 1/2, 1/4 respectively.
  Both local and forwarded bytes consume the quota. These static quotas also
  cap a lone tail chip when the other chips are idle. Packet format and bit
  rate are unchanged; gaps between bytes grow. Simulation asserts FIFO
  safety and progress for the tested clocks; arbitrary clock drift is not
  qualified. Headroom alone previously allowed starvation and overflow.
- **Nonces.** Input bytes 136..139 become `{ADDR straps, 24-bit attempt}`.
  Lanes take attempts as they go idle, so every chip and lane works its own
  nonce range from one broadcast JOB.
- **Jobs.** A new JOB drops unsent DONEs of the old job. Every report
  carries the job ID captured when its attempt started (a TLA+ model found
  the race where it was stamped at send time), and solutions already on
  the wire finish.
- **Shares.** The SKY130 test chip bypasses share filtering to reduce routing
  demand; its host must apply the target. Other configurations default to
  filtering enabled (`SHARE_FILTER=1`). Each enabled lane checks its solutions against the SET_TARGET target
  on chip, so only shares use the chain (a (200,9) solution is a 2 KB
  packet). The default target passes everything.
- **Pins.** BO = BI AND idle; TEMP is open-drain.

## Run it

Needs `docker` (Verilator 5 image) and `python3` with numpy. Synthesis and
gate-level simulation need `pip install --user yowasp-yosys`; physical
design needs the LibreLane image (`pd/run_flow.sh`).

```sh
./run.sh all                          # lint, SAT proofs, every simulation, TLA+, Lean (~10 min)
./run.sh lint                         # Verilator -Wall + Yosys structural check
./run.sh hash                         # Blake2b vs hashlib (SPLIT=4 via SPLIT=4 ./run.sh hash)
./run.sh solver3                      # streaming solver vs model (LAT, STALL, D, N, K, NH)
./run.sh chain                        # 4-chip board, 2 lanes, two jobs
./run.sh chain_sky130                 # the exact test-chip config, SRAM macro models
./run.sh chain_par                    # the board test with the bucket-parallel solver
./run.sh chain_gl                     # the board test on the Yosys gate-level netlist
./run.sh tla / lean / formal          # TLA+, Lean 4, Yosys SAT proofs (formal/README.md)
./run.sh signoff                      # scan insertion + shift test, LEC, gate-level board test
HDRS=0:0 N=200 K=9 NH=1 LAT=20 D=16 ./run.sh solver3   # mainnet, ~20 min
python3 model/perf_model.py build/mainnet_solver3_final_profile.txt
```

## Verification

`model/equihash_ref.py` holds two independent pieces:

- **`hw_solve`** (vectorized as `model/equihash_np.py` for mainnet, and
  `model/par_model.py` for the bucket-parallel solver) mirrors the RTL
  algorithm step for step. The testbenches require the RTL to match it
  **bit for bit**.
- **`zcash_verify`** is a port of zcashd's `IsValidSolution` that shares no
  code with `hw_solve`.

Every solution the RTL produces also goes through `zcash-miner --verify`,
the consensus-ported Zig verifier in `../../src/`. Formal proofs cover what
simulation can't enumerate. See [formal/README.md](formal/README.md) for
what each proves and what it doesn't.

| Test | Result |
|---|---|
| Blake2b leaf hash vs hashlib, SPLIT 1/2/4 | 64/64 at (48,5), (96,5), (200,9) |
| Solvers v1/v2/v3 vs model, random stalls, 1–20 cycle latency, 2–16 reads in flight | bit-exact |
| **Mainnet (200,9) in RTL**, streaming solver and bucket-parallel (P = 16) | solutions match the model and pass `zcash-miner --verify --params 200,9` |
| Share filter (SHA256d vs hashlib, target compare) | pass |
| Memory BIST, 5 injected fault classes | 5/5 detected |
| 4-chip board, 2 lanes, two jobs, over-temp, STOP, share targets | pass; no duplicate DONE, every job ID correct |
| Exact test-chip config with SKY130 SRAM macro models | pass |
| Gate-level netlist of the test chip on the board test | pass, same shares as RTL |
| Scan-inserted Blake2b netlist: shift and capture | 2125 flops, 0 errors |
| **Lean 4**: soundness of the solution construction, canonical ordering, bucketing, FIFO sizing at the real parameters | proved, no `sorry` |
| **TLA+**: chain protocol, crossbar round, job tags (plus 3 mutants that must fail) | pass; mutants caught |
| **Yosys SAT**: arbiter fairness (induction), UART delivery, FIFO integrity | proved |
| **Equivalence** (Blake2b block): RTL ≡ routed netlist, synthesis ≡ routed, netlist ≡ scan netlist with scan off | proved (ABC sequential equivalence) |

Real bugs caught by these checks:
- a duplicate DONE packet (a one-cycle race)
- counter widths that broke larger parameter sets
- a loop variable shared by three processes: multiple drivers in
  synthesis, a race in simulation
- the upstream buffer overflowing under load, fixed with flow control
- 41% solution yield from the original GMAX = 8
- a candidate pair advancing before its expansion finished
  (bucket-parallel solver)
- reports stamped with the *current* job ID instead of their attempt's,
  found by the TLA+ `JobTags` model and then reproduced in simulation

and by review before they could bite: a stale-hash race on cancel, and a
lost histogram count on the last leaf.

## Performance

Streaming solver, per lane, (200,9), 20-cycle memory latency
(`build/mainnet_solver3_final_profile.txt`):

| | solver2 | solver3, first version | **solver3, final** |
|---|---|---|---|
| Group cap / histogram | GMAX 8, separate pass | GMAX 8, separate pass | **GMAX 16, fused** |
| Cycles per attempt | 508.7 M | 206.1 M | **169.8 M** |
| Yield (vs near-complete solver) | 41% | 41% | ~100% |
| Solutions per second at 1 GHz | 1.14 | 2.81 | **8.36** |
| Traffic per solution | n/a | 3.4 GB | **1.14 GB** |

Bucket-parallel solver (`zeq_eh_par`), (200,9), measured in RTL:

| Engines P | Cycles per attempt | Cycles per row per engine | Sol/s at 1 GHz |
|---|---|---|---|
| 16 | **5.745 M** (arch model: within 0.6%) | 2.65 | 247 |
| 512 (projected from the same per-row cost) | 0.17 M | 2.65 | ~8,400 |

Rows the buckets can't hold are dropped and counted. At 640 slots per
bucket (1.25× the average) the bucketed solver found all 15 solutions the
near-complete solver finds over 8 nonces (`build/yield_par.txt`).

## Production target

The requested product is a **competitive mainnet (200,9) ASIC**. Targets
include a system delivering 1 MSol/s at no more than 2 kW at the wall
(2 mJ/solution). These are targets, not measured capabilities. Process/IP
access, compiler views, packaging and commercial quotes are not provisioned
here. The detailed production handoff package (targets, requests, reviews)
is maintained privately and is not part of this public snapshot.

`rtl/zeq200x.v` integrates the mainnet bucket-parallel solver and share
filter. Its default 16 engines match the simulation scale; 64–512 engines
are candidates that require physical evaluation. `./run.sh lint_mainnet`
checks the top. No production PDK mapping or signoff has been performed.

The new optional `COMPACT_VALUES=1` solver parameter omits the first
collision chunk from stored row payloads, group buffers and the crossbar.
Bucket and local-key fields retain the information required for sorting;
pairing discards the omitted bits in every round. The production top
uses this option; the SKY130 test-chip default remains uncompressed.

`python3 model/production_budget.py` inventories the **implemented** logical
RAM at 512 engines and 4096 buckets: 366.87 MB for the original 1024-slot
layout, 345.90 MB with compact values alone, and 217.27 MB with compact
values plus 640-slot physical banks (149.60 MB saved overall). Crossbar row payload falls
from 252 to 232 bits. These are decimal MB before macro rounding, repair,
ECC and physical overhead. The current full crossbar has 262,144 possible
source/destination pairs; a scalable physical network is still required.

The 134 MB storage and multistage-network assumptions in the older
projection below are **not implemented**. Its energy, area and cost
figures cannot substantiate a competitiveness claim for the current RTL.
The `SLOTS` parameter now implements non-power-of-two bucket capacities.
Physical row addresses pack buckets contiguously; logical parent IDs keep
separate bucket and slot fields. The production top selects 640 slots,
while existing configurations default to `1 << SB`. SRAM compiler depth
restrictions and any resulting padding must be accounted for at mapping.
`arch_model.py` now prints this limitation before its exploratory results.

Compaction regression commands (independent output directories):

```sh
COMPACT_VALUES=1 BUILD=build/compact48_verified SB=8 ./run.sh par
COMPACT_VALUES=1 BUILD=build/compact96 N=96 K=5 NH=2 BB=8 PB=2 SB=10 ./run.sh par
COMPACT_VALUES=1 BUILD=build/compact200 N=200 K=9 NH=1 BB=12 PB=4 SB=10 HDRS=0:0 ./run.sh par
```

Additional verification commands:

```sh
COMPACT_VALUES=1 SLOTS=80 BIST_FIRST=1 BUILD=build/compact48_bounds SB=7 ./run.sh par
COMPACT_VALUES=1 SLOTS=640 BUILD=build/compact200_cap640 N=200 K=9 NH=1 BB=12 PB=4 SB=10 HDRS=0:0 ./run.sh par
```

The testbench can run March C− before solving (`BIST_FIRST=1`), and the
generic RAM model fails on out-of-range reads/writes. Small-capacity tests
exercise row drops. When drops occur, the existing solver checker verifies
each solution but skips exact set equality because arbitration changes
which rows survive. Such a pass does not establish population-wide yield.

Verification completed on September 29:

| Check | Evidence |
|---|---|
| Compact rows, (48,5), 8 attempts | 8 solutions verified; identical solutions and cycles to baseline |
| Compact rows, (96,5), 2 attempts | 8 solutions verified |
| Compact rows, mainnet (200,9), 16 engines, 1024 slots | 1 nonce, 1 valid solution, 5,745,299 cycles; 249 rows dropped |
| Compact rows, mainnet (200,9), 16 engines, 640 slots | Same solution, 5,743,348 cycles; 1,104 rows dropped |
| Packed 80-slot memories, (48,5), 8 attempts | March C− passed; bounds checks passed; same 8 solutions as baseline |
| Integrated mainnet top | Verilator lint passed at 16 engines |
| Existing SKY130 board configuration | 30/30 solutions verified; 23/23 expected on completed attempts |

Logs are `build/compact48_verified.log`, `build/compact96.log`,
`build/compact200.log`, `build/compact200_cap640.log`,
`build/compact48_bounds.log`, `build/production-lint.log`, and
`build/production-default-regression.log`. The original 1024-slot mainnet
runner encountered a shell read-offset error after its verifier completed
because the script was edited while running; the independent 640-slot
run completed with exit code zero. RTL output and verifier results from
both runs were compared directly. One mainnet nonce is insufficient to
qualify yield, cancellation behavior, or long-run reliability. The full
production top has been linted, not subjected to full-chip mainnet board
simulation or netlist equivalence.

The production top now defaults to `SPLIT_KEYS=1`: separate key SRAMs
serve scatter reads while the value SRAM stays idle. Combined storage
remains the default in existing configurations (`PAR_SPLIT_KEYS=0`), and
its value macro instance paths are preserved. Both key SRAMs participate
in March C−. In a matched eight-attempt (48,5) test, engine-0 value reads
fell from 15,352 to 9,951 with identical complete solver output (including
cycles and drops). This is read-activity evidence, not characterized power.
The four-nonce mainnet regression completed in `build/splitkeys200.log`.
Its original checker skipped set comparison on overflowing attempts; the
later strict audit in `build/yield-study-rtl200-split/summary.json` retains
9/9 independent reference solutions on that corpus.

The round-robin arbiter now uses balanced priority trees with static bank
comparisons. Inductive equivalence to the saved reference passed at
2, 4, 8 and 16 requesters for bank 0 and the last bank. Generic synthesis
without technology mapping reports 304 versus 527 cells at 16 requesters,
and 1,394 versus 3,806 at 64. These are structural counts, not physical
area/timing results, and the full crossbar still requires replacement or
physical scalability evidence. See `formal/arb_equiv.sh` and
`build/arb-equivalence.log`.

The exact logical memory shapes and any compiler-facing requirements are
tracked in the private production package (not included here).

Priority after these reductions: implement lifetime-based table packing,
replace the global crossbar with a verified hierarchy, integrate the licensed SRAM/compiler interfaces and
repair/DFT, then measure extracted power and timing. Wall-power comparison
must include VRM/PSU losses, cooling and controller consumption. A physical
result meeting the target is required before production release.

## Notes on projections

Some archived models project cycle counts and energy splits using assumed
advanced-node parameters. These projections are exploratory and not
fabricated-silicon measurements. They are retained for context, but
competitive comparisons and specific third-party product names have been
removed in this public snapshot.

Implemented: compact row payloads, non-power-of-two bucket capacities,
banked on-die tables, multiple engines, and on-chip share filtering.
Lifetime-based table reuse and further index compression remain open.

**These are projections.** The RTL and cycle counts are measured. The
energy, area and cost numbers are 7 nm assumptions, and only silicon
settles them.

## Lifetime-packed memory candidate

`PACKED_TABLES=1` (requires compact values and split keys) reuses shrinking
row-value storage for retained parent pointers. Each parity is divided
into independently addressed PW-bit SRAM slices. Values occupy low slices;
pointers are retained in high slices as rounds progress. During final-round
expansion, value and parent reads access disjoint slices, preserving one
registered read cycle without requiring a second read port per SRAM.

At the 512-engine / 640-slot mainnet configuration, the candidate uses
**141.246464 MB of logical table SRAM**, versus 217.268224 MB for the compact
separate-table implementation: a further 76.02176 MB reduction. This is
implemented RTL inventory, not characterized macro area or power. Slice
periphery, compiler padding, repair and physical routing remain unmeasured.
The production top keeps this option disabled pending mainnet qualification.

Validation so far: packed-memory unit tests at (48,5) and (200,9), all
rounds, retained parents, concurrent read addresses, repeated attempts,
non-power-of-two depths and BIST pass. Eight integrated small attempts
produce identical solutions, cycles and drops to the separate tables.
Flattened synthesis has no retained legacy value/pointer RAMs; the table
shapes and 166,336 bits match the small-case inventory exactly
(`build/packed48-memory-inventory.json`). Mainnet top lint passes with
packing enabled. The four-header mainnet regression passes and exactly
matches the prior solution, cycle and drop log. Its inputs and log match
the independently audited corpus retaining 9/9 reference solutions
(`build/packed200-ram-v2/reference-audit.json`). Whole-word induction now
passes at (48,5)/PW18 and (200,9)/PW32, each with depths 2 and 3, including
reset and cancellation/restart. This supersedes the earlier bounded-proof
timeouts for those concrete configurations. It does not establish arbitrary
depth, active BIST, compiler-macro behavior or full-solver equivalence;
packing remains opt-in. Run `BUILD=build/packed-review ./run.sh packed_formal`
for the source-bound proof and mutation regression
([formal scope](formal/README.md#packed-sram-qualify_packedpy)).
The September 30 qualification passes all four induction cases and detects
all three injected value/parent/address faults with reachable counterexamples
(`build/packed-qualification-v2/result.json`).

`tb/run_packed_mainnet.sh` archives exact sources/configuration and compiles
in a bounded container tmpfs, retaining logs and results on disk. This
supports RTL work while the shared persistent volume lacks sufficient
headroom for physical design; it does not change the physical-flow guard.

## Paired yield and activity evidence

`model/yield_study.py` compares capacities on identical deterministic diverse
headers, or imports an exact RTL header/output log with `--rtl-build`.
It records source/verifier hashes and inputs, resumes matching studies,
verifies solutions with Python and Zig, rejects duplicates, and counts
missing reference solutions even when the RTL reports bucket overflow.
Its reference rejects partial trees containing repeated leaf indices;
these can never become valid solutions. Any reference group or row-cap
truncation stops qualification. `model/test_distinct_reference.py` compares
this reference against a scalar explicit-tree solver on 24 small cases.
Nine evidence tests pass (`build/yield-reference-tests.log`).

The four-header mainnet RTL regression retains 9/9 reference solutions
(`build/yield-study-rtl200-split/summary.json`). The separate 16-header diverse
mainnet **capacity-model** study completed: 640, 768 and 1024 slots each retain
33/33 reference solutions (`build/yield-study200-distinct-v1/summary.json`).
This does not establish production yield or physical efficiency.
The eight-header small RTL regression retains 8/8 reference solutions
(`build/yield-study-rtl48/summary.json`). A separate eight-header diverse
small model corpus retains 4/6 at 64 slots and 0/6 at 16 or 32 slots,
demonstrating that the checker detects lost yield. Neither result qualifies
mainnet yield. Paired bootstrap intervals resample headers; a degenerate
100% interval on a small corpus does not prove population losslessness.

The solver bench also emits `memory_accesses.csv` (all engines, logical
word width and per-table reads/writes) and `network_activity.csv` (requests,
grants and stalls). These cover the busy window, excluding BIST, and are
activity measurements rather than power estimates. The instrumented small
regression exactly matches its prior solver output, and its port/network
accounting reconciles. SRAM compiler energy, routing, leakage and complete
system overhead remain necessary for a solutions-per-joule result.

## Staged row-network candidate

`STAGED_NETWORK=1` selects two-stage transport through independently
buffered source-group/destination-group links. Each bank still consumes at
most one row per cycle. Producer grants acknowledge enqueue; the round
barrier drains every accepted row before switching memory parity. Reset
and cancellation flush buffered rows. The default remains the flat fabric.

At 512 ports and a 232-bit row payload, structural counts fall from
60,698,624 to 7,245,824 payload mux bits (2:1 mux equivalents), with 1,024
elastic links adding 242,688 data/target/valid register bits. Arbitration
logic, clock load, physical wires and power are excluded from these counts.
See `model/production_budget.py`; this is not a mapped-area claim.

Standalone tests at 4/8/16/32/64 ports check 232-bit payload integrity,
destination, uniqueness, cancellation and bounded waiting under hotspot,
permutation and random traffic. The integrated eight-attempt small solver
retains 8/8 independent reference solutions, including overflowing attempts,
and uses 157,058 cycles versus 160,755 with the flat network. This 2.30%
small-corpus reduction does not predict mainnet throughput. The four-attempt
mainnet regression completed and preserves the flat fabric's exact nine
solution sets and per-attempt drop counts. It takes **23,968,459 cycles vs
23,563,768** for flat transport, a **1.72% increase**. Both sets pass Python
and Zig verification (`build/staged200/comparison-v2.json`). The flat fabric
remains the default. `model/compare_rtl.py` makes this paired comparison
reproducible and rejects incomplete logs, duplicates and changed solution
sets even when total counts match. Formal checks cover an
arbitrary accepted transaction; four-port bounded checks pass, while larger
checks timed out or remain incomplete. Physical implementation and energy remain open.

## Zero-row discard and linear distinct-leaf check (November 11, 2026)

Two opt-in solver parameters, both default 0 in every configuration:

- `DROP_ZERO=1` discards an intermediate row whose remaining bits are all
  zero. Such a row is the XOR of two equal-valued parents; before the last
  round it descends from shared leaves unless a 2^-(remaining bits)
  coincidence occurs. Both parents stay stored (this is not value
  deduplication). Every such row lands in bucket zero, key zero, which is
  what filled bucket zero and motivated `BUCKET0_SLOTS`.
- `LEAF_SET=1` replaces the pairwise distinct-index check after canonical
  ordering (NSOL^2/2 cycles, about 131k at (200,9)) with an open-addressed
  set of 2*NSOL slots filled while the leaves are read. Accepted and
  rejected candidates are unchanged.

`tb_par` now writes `zero_rows.csv` and `expansion_profile.csv` per attempt.
`./run.sh par` and `solver_yield` accept `DROP_ZERO` and `LEAF_SET`;
`model/par_model.py` takes `drop_zero` (`model/test_zero_rows.py`).

| Corpus | Configuration | Solutions (reference) | Cycles | Rows dropped |
|---|---|---|---|---|
| (48,5), 16 headers, `./run.sh par` | default | 11 (11) | 325,525 | 0 |
| | `LEAF_SET` | 11 (11) | 220,285 | 0 |
| | `DROP_ZERO` | 11 (11) | 110,920 | 0 |
| | both | 11 (11) | 88,575 | 0 |
| (200,9), 4 headers, 16 engines, 640 slots | earlier baseline, `BUCKET0_SLOTS=768` (`build/a-mainnet16-persistent-v1`, first four headers) | 11 (11) | 23,405,085 | 1,082 + 541 on two headers |
| | `DROP_ZERO`, no bucket-zero extension (`build/dz-mainnet200-v1`) | 11 (11) | 23,384,275 | 0 |
| | `DROP_ZERO` + `LEAF_SET` (`build/dz-ls-mainnet200-v1`) | 11 (11) | 21,784,133 | 0 |

The mainnet runs are source-frozen `tb/qualify_par.py` qualifications with
the strict untruncated reference audit and Python/Zig verification. With
both options the shared expansion unit is busy 15,062 to 53,158 cycles per
attempt. Disabling the set's reject makes the (48,5) regression fail with
304 invalid solutions. The `dz-ls` archive predates moving the set into a
generate block; the (48,5) results are cycle-identical before and after.

The expansion unit is serial, so its cost does not shrink with engines.
The 6.9% saving at 16 engines is about 405k cycles per attempt on this
corpus. `model/arch_model.py --expansion-cycles` now includes that term: at
512 engines the typical projection is about 2,400 Sol/s per die with the
default checks (roughly 440k busy cycles, inferred from the saving rather
than profiled), not 8,440, and about 7,300 with both options (36k measured). These remain projections with assumed 7 nm parameters.

Four headers do not establish population yield, and neither option is
enabled in `zeq200x`. A wider paired corpus, integrated core qualification
and new synthesis/equivalence evidence are required before changing the
production default or removing `BUCKET0_SLOTS`.

The same change set fixes a link race present before it: `./run.sh chain`
and `chain_par` failed with one corrupted SOLUTION packet when a JOB abort
fired in the cycle the packet builder committed to a solution
(`sending_sol` rises one cycle later). `zeq_link` now starts no new
SOLUTION packet while a JOB/STOP abort is pending. Both chain tests, the
SKY130 chain configuration, core control and link BIST pass. This changes
default link RTL, so earlier netlist equivalence does not cover it.

## Several Blake2b units per engine (November 12, 2026)

Leaf generation is hash-bound at (200,9): a digest yields only two leaves,
so an engine spends about 29 cycles per group waiting for its single
Blake2b unit, a third of the attempt at 16 engines. `HASH_UNITS` (default
1) gives each hashing engine several units. Groups go to the units in
rotation and are consumed in the same rotation, so the leaf order an engine
emits is unchanged; only the wait shrinks. With `HASH_UNITS=1` the RTL is
cycle-identical to before (325,525 cycles on the 16-header (48,5) corpus).

Mainnet (200,9), same four headers, 16 engines, 640 slots, `DROP_ZERO=1`,
`LEAF_SET=1`, through `tb/qualify_par.py`:

| `HASH_UNITS` | Build | Reference solutions | Total cycles | Engine-0 cycles per leaf group | Rows dropped |
|---|---|---|---|---|---|
| 1 | `build/dz-ls-mainnet200-v1` | 11 of 11 | 21,784,133 | 29.0 | 0 |
| 2 | `build/dz-ls-hu2-mainnet200-v1` | 11 of 11 | 17,975,983 (-17.5%) | 14.5 | 0 |
| 4 | `build/dz-ls-hu4-mainnet200-v1` | 11 of 11 | 16,087,383 (-26.2%) | 7.25 | 0 |

Generation still scales linearly at four units, so the send path is not
yet the limit; its floor without contention is about four cycles per group.
This reverses the direction of the earlier 8-versus-16 hash-engine
experiment: fewer hash units cost cycles, more recover them.

The cost is area and is not measured. `model/arch_model.py --hash-units`
charges an assumed 0.015 mm2 (typical) per extra unit; with that guess the
512-engine typical projection moves from about 7,250 Sol/s on 96 mm2 to
8,540 on 104 mm2 (two units) and 9,380 on 122 mm2 (four), so two units
improve throughput per area and four roughly break even. Energy per
solution is unchanged in the model because the hash count is the same. A
synthesized Blake2b area is needed before choosing.

`HASH_UNITS` is off (1) in `zeq200x`. `tb/qualify_core_control.py` and
`run.sh core_control` now accept `DROP_ZERO`, `LEAF_SET` and `HASH_UNITS`;
the (48,5) integrated run with all three (`build/cc-opts48-v1-core-control`)
passes. `tb/audit_par_archive.py` now accepts archives recording `GMAX`,
`GROUP_REPLAY` and the three options.

## Sixteen-header check and autoresearch loop (November 12, 2026)

**Sixteen headers, `DROP_ZERO=1`, `LEAF_SET=1`, 640 slots, no bucket-zero
extension** (`build/dz-ls-mainnet200-16h-v1`, final source): PASS, 33 of 33
reference solutions, 88,260,556 cycles against 92,959,466 for
`build/a-mainnet16-persistent-v1` (-5.1%). Rows were still dropped on three
headers (2,004, 224 and 4; 2,232 in total against 17,926 with the 768-slot
extension). The four-header result above therefore overstated the case:
zero-row discard removes most bucket overflow, not all of it, and
`BUCKET0_SLOTS` must stay until the remaining drops are traced.

**Autoresearch loop.** Branch `autoresearch/nov12-zeq` was driven by an
external keep/discard runner. Each experiment is one commit scored on
`zeq_cost` = mainnet cycles per attempt (two headers, 16 engines,
`tb/qualify_par.py`, every reference solution required) times an area
proxy: 0.50 x SRAM bits (exact; `zeq_ram` reports its size under
`+ram_inventory`) + 0.37 x Yosys generic cells at (48,5) with four engines
+ 0.13, each relative to the baseline. Lint and (48,5) regressions gate
every run. The candidate configuration is `tb/candidate.env`.

The first four experiments were scored with a logic term counted at (48,5)
widths (generic cells, four engines). That count was almost entirely
Blake2b and missed mainnet-width buffers, so it was replaced by a rough
gate-equivalent estimate per engine at (200,9) datapath widths (Yosys
word-level cells, RAMs black-boxed, two- and four-engine builds
differenced). The table uses the second metric throughout; cycles are
measured, and the first five area figures are recomputed from the same
logic estimate.

| Experiment | Cycles per attempt | Area proxy | `zeq_cost` | Result |
|---|---|---|---|---|
| Baseline: `DROP_ZERO`, `LEAF_SET`, `HASH_UNITS=2` | 4,514,249 | 1.000 | 4,514,249 | baseline |
| `CHAIN=1`: write-time key chains replace the counting sort | 3,021,658 | 1.003 | 3.03M | keep |
| `STAGED_NETWORK=2`: queued crossbar, two accepts per bank per cycle | 2,738,819 | 1.007 | 2.76M | keep |
| `GBUF=3`: third group buffer per engine | 2,620,958 | 1.043 | 2,733,426 | keep (about -1%, within the estimate's error) |
| `HASH_UNITS=4` | 2,146,174 | 1.213 | 2,604,098 | keep |
| `QDEPTH=8`: eight-row bank queues | 2,028,652 | 1.221 | 2,477,557 | keep |
| `EMIT=2`: second pair emitter per engine | 1,882,293 | 1.257 | 2,365,190 | keep |

Every run kept 5 of 5 reference solutions with no dropped rows. The kept
configuration takes 58% fewer cycles than the baseline at 16 engines for an
estimated 26% more area (cost -48%). Under the first metric `HASH_UNITS=4`
had been discarded (area proxy 1.34) and `GBUF=3` looked clearly positive;
both verdicts depended on the logic term. Per engine the estimate puts one
Blake2b unit at about 24% of baseline engine logic, the third buffer at
about 10% and the queue at about 1% (four rows) to 2% (eight).

- `CHAIN`: each per-key table entry holds the newest slot instead of a
  count, and each row links to the previous row with its key (one link RAM
  per parity, written beside the head update). The walker follows chains at
  one row per cycle and a prefetcher reads and clears heads ahead of it, so
  the prefix-sum pass, the scatter pass, the background clear and the
  per-row key RAMs go away. Rows of a key are visited newest first.
  Group replay is not supported with chains.
- `STAGED_NETWORK=2` (`zeq_row_queue` in `rtl/zeq_row_network.v`): with
  chains every engine emits for most of the attempt and a one-grant-per-bank
  crossbar stalled 35% of request cycles. A four-entry queue per bank that
  accepts two rows per cycle cut that to 14%. The two-stage network
  (`STAGED_NETWORK=1`) was slower than the plain crossbar with chains
  (3.29M against 3.02M cycles per attempt).
  Deeper queues cut stalls further once the third buffer was in: 19% of
  request cycles at four rows, 9% at eight, 7% at sixteen (`QDEPTH`).
- `GBUF=3`: a finished group can wait while another is paired.
- `EMIT=2`: outside the last round the waiting group is paired where it
  sits, through a second request register, and the bank queues arbitrate
  over both emitters of every engine. The walk fell to about 1.17 cycles
  per row; a model of the walker predicted about 1.05, and the difference
  is bank-queue backpressure (a bank still writes one row per cycle).

Limits of this evidence:

- The metric has no timing, energy or wire term. `CHAIN` puts a RAM output
  on a RAM address path in the same cycle (link read to value/link read);
  that path is unverified and may cost clock rate or a pipeline stage.
- Mapped synthesis of the engine was attempted with the WebAssembly Yosys
  build and failed (netlist too large); `pd/qualify_solver_synthesis.py`
  was not run because the Librelane image is absent and the disk is nearly
  full. A Blake2b unit alone maps to about 69k gate equivalents.
- The logic estimate is word-level cells with hand weights, not a mapped
  netlist. Absolute values may be off by a factor of two; only ratios are
  used. A standalone Blake2b unit estimates at about 71k gate equivalents
  against about 160k to 190k inside the engine difference, which is
  unexplained. `HASH_UNITS=4` and `GBUF=3` need mapped mainnet-width
  synthesis before either is adopted.
- With `CHAIN` the read address is link-RAM output, a 2:1 mux and the
  base-plus-slot add. Storing the full row address in the link would remove
  the add for about 1.3% more SRAM. No timing analysis was run.
- The queued crossbar is a full crossbar with a second P-to-1 selection per
  bank. It was scored at 16 engines; it is not a 512-engine network design.
- Two headers per run. None of these options is enabled in `zeq200x`
  (`GBUF`, `QDEPTH`, `EMIT` and `STAGED_NETWORK=2` are plumbed only as far as
  `tb_par`, `CHAIN` also through the tops), none has integrated-core, synthesis or equivalence evidence,
  and `model/arch_model.py` does not model them.

## Production priorities and decision gates

The production `zeq200x` top now defaults to `BOOT_BIST=1`: every reset
starts memory BIST and holds mining until a fresh successful completion.
The latest queued JOB can start after qualification; STOP cancels it, a failed
test quarantines mining, and another reset requires qualification again.
The generic core/link retain `BOOT_BIST=0` for existing test configurations;
configurations without BIST ignore the setting.

`BUILD=build/startup-review ./run.sh startup_bist` freezes its inputs and runs
ten actual-UART startup/compatibility/mutation checks at N48 and N200 plus
ownership induction and three reachable fault checks. All pass in
`build/startup-bist-v2` and `build/startup-bist-formal-v1`. Integrated small-core
qualification also passes in `build/core-control48-startup-bist-v2`, with two
independently verified solutions, four forwarded packets and reset
requalification coverage. Mainnet packed production-top qualification in
`build/core-control200-startup-bist-v1` now passes with one independently
verified solution, four forwarded packets, 124,627 backpressure cycles and
all required startup/reset/control/BIST coverage. Its archived generic RTL
matches the source before independent hash controls were exposed in the top.
The integration runner accepts `--packed-tables 0` to qualify the production
default separate tables as well as the packed candidate. The equivalent
entry point is `PACKED_TABLES=0 N=200 BUILD=build/startup-separate-review
./run.sh core_control`. Separate-table N48 integration passes in
`build/core-control48-startup-separate-v1`, also with two verified solutions
and four forwarded packets. The N200 run also passes in
`build/core-control200-startup-separate-v1`, with one verified solution,
four forwarded packets and all required startup/reset/control/BIST coverage.
Its UART capture matches
the packed run byte for byte. These checks use behavioral RAM, not foundry
compiler models or physical IO.
The startup entry point also runs `tb/qualify_core_bist_faults.py`: a
small-core matrix injects stuck-at-zero faults at actual behavioral RAM read
registers, leaving March engines and result aggregation intact. It covers
first/last-engine leaf indices, both histograms, order, keys, separate
values/parents and all six small-core packed slices, then checks UART fault
status, quarantine, retest and reset. Broken failure aggregation and
quarantine must fail while their healthy controls pass. All 33 checks pass in
`build/core-bist-faults-v2`: six healthy controls, 23 RAM read-output fault
cases and four reachable mutation detections. Input, executable and log
hashes match. Compiler memory fault coverage and manufacturing qualification
remain open.
These source changes require new synthesis/netlist equivalence and physical
qualification. Plan H's existing proof covers its earlier archived source.

The current design has functional evidence, but neither competitive
wall efficiency nor production tapeout readiness is demonstrated.
The remaining production areas and acceptance criteria are tracked in the
private production workstreams (not included here). Their priorities apply
criterion; its priority numbers apply separately to the two tracks.
Its `decision_gates` now order evidence reconciliation, process/SRAM
feasibility, routed tile characterization, machine architecture selection,
production integration/test, and final signoff/release. Gate dependencies
apply to acceptance; independent verification and process-access preparation
can proceed concurrently. See [the ordered gates](TAPEOUT.md#ordered-production-decision-gates--october-2-2026).

| Priority | Competitiveness | Tapeout readiness |
|---|---|---|
| 1 | Reduce physical memory capacity through lifetime reuse and pointer packing; qualify the solution-yield tradeoff | Obtain licensed process and SRAM/compiler views and validate their interfaces |
| 2 | Reduce memory accesses and energy using narrow key storage and characterized SRAM | Route a representative tile and measure extracted timing, area and workload power |
| 3 | Scale the communication fabric without excessive contention, wires or buffers | Complete mainnet full-chip verification and final-netlist equivalence |
| 4 | Measure independently verified solutions per joule on paired diverse workloads | Integrate scan/ATPG, memory BIST/repair and manufacturing test |
| 5 | Balance hash/solver parallelism and choose voltage/frequency from measurements | Close package, cooling, power delivery, die count and quoted unit/NRE cost |
| 6 | | Complete foundry physical, PVT timing/electrical and EM/IR signoff |
| 7 | | Bind exact release artifacts to passing reports and submission acceptance |

The 1 MSol/s at <=2 kW wall target is a complete-machine engineering
objective, not a single-die result. In addition to efficiency, throughput
per die and cost per delivered kSol/s must be competitive. BITMAIN's cited
840 kSol/s reference contains 18 hash chips; our engine count is not a die
count and cannot be compared directly. Die count remains unqualified until
routed throughput and characterized power are available.

The October 2 inventory emphasizes the memory/throughput constraint:

| Engines | Packed logical SRAM (decimal MB) | Logical memories before compiler tiling |
|---|---|---|
| 16 | 140.849664 | 288 |
| 64 | 140.888064 | 1,152 |
| 128 | 140.939264 | 2,304 |
| 256 | 141.041664 | 4,608 |
| 512 | 141.246464 | 9,216 |

Reducing engine count barely reduces the fixed table capacity. Compiler
padding, slice periphery, redundancy and routing can change the physical
benefit of packing. The private production package records these inventories
and the required supplier response. Select the die only after
routed tile measurements and complete machine budgets. The historical
8,400 Sol/s/die projection would need about 120 dies for 1 MSol/s, leaving
roughly 16.7 W of wall allowance per die before system overhead; neither
that throughput nor the resulting machine is qualified.

The SKY130 demonstrator's historical Plan D run is stopped by the disk
guard with 2,069 routing violations remaining and is release-blocked by
the BIST/JOB ownership defect described below. Plan H has synthesis evidence
only; a corrected-source physical run is still required. Plan C
was stopped after the UART
integration test exposed a forwarding deadlock: idle arbitration could
reselect the last FIFO byte before its registered pop retired. The fix waits
one cycle for that pop. Small-core reset/cancel/BIST/backpressure/filter
coverage passes; the mainnet production-top test also passes, including
one independently verified solution, four forwarded packets, cancellation,
reset, BIST, UART backpressure and filtering
(`build/core-control200-fwd-fix/result.json`). This is a finite integration
test, not final-netlist equivalence.

Plan D uses the archived Plan C sources and constraints with only that link
fix. Its four-chip SKY130 SRAM-model regression passes 26 independently
verified shares (`build/plan-d-chain/check.log`). After a disk-guard stop,
detailed routing resumed September 30 from checkpoint 40 using verified
source/configuration hashes and the original EDA image. The new guard
reserves 20 GiB (`build/plan-d-resume.json`). The resumed run subsequently
stopped at that guard (`build/plan-d-resume-flow.exit`), with 2,069 violations
at the last completed iteration. Final reports are absent.
Plans C and D carry `RELEASE_BLOCKED.json`, which the signoff gate
rejects even if physical reports later pass. Neither this demonstrator nor
generic cell counts qualify production release.

A later UART test reproduced a second defect in Plan D's exact archived
link: a JOB could launch mining while BIST was still overwriting tables.
Current RTL acquires a BIST ownership lock, waits for a fresh low-to-high
DONE handshake, queues the latest JOB, and lets STOP discard queued work
without aborting BIST. Failed BIST discards queued work and blocks mining
until successful retest or reset. Busy/PONG status reflects this lock and
hides stale BIST results. Architectures without BIST ignore the command
and report no test result. BIST requires an empty payload.

`BUILD=build/link-bist-review ./run.sh link_bist` checks these behaviors
through UART, including corrupted/malformed BIST, retest and reset. The
old-source reproducer is `build/link-bist-baseline-v3`; corrected and
unsupported-architecture tests pass in `build/link-bist-fixed-v3` and
`build/link-bist-unsupported-v1`. Mainnet integration also passes in
`build/core-control200-bist-guard`: actual memory-test JOB deferral and STOP
cancellation, 124,627 backpressure cycles, filtering, four forwarded packets,
and one independently verified solution. The tested RTL hashes match current
sources. This remains a finite digital integration test.

Plan E freezes the corrected RTL and wrapper in `build/plan-e-source`.
Its four-chip regression instantiates the actual `user_project_wrapper`,
with SKY130 SRAM cycle models, and checks GPIO directions, LA readback,
temperature/IRQ behavior and chained traffic at the fixed divider of 16.
`build/plan-e-wrapper-chain-v3` passes with 350 independently verified
solutions. A stricter re-audit in `build/plan-e-chain-audit-v1` also passes,
rejecting duplicate solutions, invalid packets, reports after DONE and fewer
than four job-2 completions. Completed attempts retain 346 of 380 unbounded-model solutions;
the demonstrator's 128-slot capacity is deliberately lossy. Job 2 completion
counts are 4/97/156/222 by chip address: this test demonstrates progress but
also substantial unfairness under saturation, not a bounded-latency guarantee.
Plan E synthesis completed with 70,203 mapped instances and the expected
19 SRAM macros, but its transport is now release-blocked. A continuous
traffic test delivered only two packets each from chips 0/1/2 during 500 ms,
versus 2,216 from chip 3. With clock periods 10.06/10.04/10.02/10 ns,
its FIFO overflowed after about 194.6 ms (`build/link-saturation-v2`).
The explicit progress-deadline reproducer also fails on that archived RTL
(`build/link-starvation-baseline-v2`).

Current RTL adds the per-hop pacing described above. Matched-clock and
offset-clock stress cases pass at both N48K5 and N200K9, including CRC,
payload sequence, FIFO safety, bounded progress and full drain. The current
finite tests run for 100 ms (small packets) and 150 ms (mainnet packets),
with progress deadlines of 5 ms and 50 ms respectively. Observed maximum
gaps are under 2.05 ms and 27.24 ms. The one-second equal-clock extension passes in
`build/link-saturation-paced48-long-v1`. Its offset-clock case hit a
600-second wall timeout without a simulation verdict under heavy host load;
a hash-bound replay of the same executable passes in
`build/link-saturation-paced48-long-skew-replay-v1`. These runs predate
the subsequent upstream recovery change.
No unbounded guarantee is claimed.
Use `BUILD=build/transport-review ./run.sh transport` for both geometries.

Plan F freezes the paced source. Its exact-wrapper test passes with 32
independently verified solutions and job-2 DONE counts 6/7/4/6; completed
attempts retain 30/32 model solutions. This is a different completed-attempt
corpus from Plan E and is not evidence of improved algorithmic yield.
BIST UART and scoped formal requalification pass. The full mainnet core
regression passes on that archived source. Plan F synthesis passes with 70,188 mapped
instances and 19 SRAM macros matching the floorplan, with no unmapped cells
or synthesis check errors. Standard-cell area is 914,519.5968 um2, excluding
SRAM (about 0.09% above Plan E). This is not timing, power or route closure. Plans C/D/E/F have known defects and
their exact hashes remain release-blocked.

Plan G adds bounded upstream frame recovery. A malformed oversized length or
truncated upstream header/payload previously starved local replies indefinitely;
the actual-UART regression reproduces all three at all four addresses. The
current fix passes maximum-payload recovery matrices at both packet
geometries, including slow valid traffic. Both geometries pass all 20 prompt-rejection/maximum-payload cases, and
removing either guard is caught independently. Plan G exact-wrapper and
sustained-traffic checks pass. Synthesis passed with 70,346 mapped instances,
19 matching SRAMs and zero unmapped cells/check errors. Plan G's mainnet
integration and experimental equivalence runs use its archived source.
Forwarding abandons
payloads larger than SOL_LEN and times out an empty FIFO after 32 byte budgets.
The controller must resynchronize any already-forwarded damaged prefix using
length limits, CRC and an inter-byte timeout. Run `./run.sh link_recovery` for
both packet geometries. `tb/qualify_link_recovery.py --mutation no-length-guard`
and `--mutation no-gap-timeout` exercise the guards independently in archived
RTL copies (each requires a fresh `--build`). No arbitrary-malformed-stream
availability claim is made.

Plan H corrects downstream command recovery. Plan G's command parser swallowed
subsequent valid commands after an oversized length or truncated header/payload;
all three failures reproduce at all four addresses. The corrected parser checks
each command's payload length and returns to framing after 32 UART byte budgets
without a byte. Controllers must leave that idle gap after an interrupted frame.
Twenty cases at each packet geometry pass, including slow commands, framing-like
payload bytes, atomic target updates and subsequent command acceptance. Removing
either recovery guard is caught independently. Use `./run.sh command_recovery`;
`--downstream --mutation no-length-guard` and `--downstream --mutation no-gap-timeout`
select fault qualification in `tb/qualify_link_recovery.py`. Plan G is now also
source-hash blocked. Plan H synthesis passes with 70,778 mapped instances,
19 matching SRAM macros, no unmapped cells/check errors, and 918,792.4448 um2
standard-cell area excluding SRAM. This is not timing, power or routing closure.
Plan H wrapper, BIST and mainnet qualification are tracked
in private production tracking; no physical or arbitrary-malformed-stream
availability claim is made.
The frozen-input Plan H mainnet integration passes with one independently
verified solution, four forwarded packets and 124,627 backpressure cycles.
Required cancellation, filtering, BIST deferral and BIST cancellation coverage
all pass. The archived generic RTL matches Plan H and predates the startup
BIST changes in current source;
the simulation executable and all result evidence hashes were audited in
`build/plan-h-mainnet-and-smt-audit.json`. The later SKY130 synthesis proof
passes all 1,486 partitions in `build/plan-h-lec-bank-v1/result.json` with
the bank-selector driver retained. Recorded evidence hashes match. This
does not cover the mainnet production configuration or a final routed
netlist; the EQY proof flow remains ineligible for release packaging.

The extended command matrix passes 52 cases per geometry (104 total), adding
missing/bad CRC, short targets, invalid PING/thermal command lengths, and
received-byte intervals four clocks below and above the timeout. Invalid
commands must leave target and thermal state unchanged. Expanded fault runs
catch 12 length-guard and 20 timeout violations while all other cases pass.
`./run.sh command_recovery` now selects this matrix. Add `--extended` when
running the downstream mutation checks directly. These cycle-level boundary
tests do not qualify arbitrary controller delays or physical clock tolerances.

Digital-core integration now runs through `tb/qualify_core_control.py`.
Use `BUILD=build/core-review ./run.sh core_control` for N48, or set `N=200`
for mainnet geometry; each invocation requires a fresh build name. The runner
compiles archived RTL and runs archived Python models plus an archived Zig
verifier, with a pinned Verilator image ID. It checks the input hashes between
stages and binds the executable, logs and independent audit into the final
result. The checker's preliminary result stays in a separate directory, so a
checker failure cannot publish a qualification PASS. Python environment
settings cannot disable model assertions. Python and NumPy remain host
dependencies; their versions are recorded. Seven runner tests cover input
isolation, tampering, verifier location and fail-closed audit handling.
`build/core-control48-archived-v4/result.json` passes with two independently
verified solutions and four forwarded packets, even with `PYTHONOPTIMIZE=1`
in the caller's environment. A separate negative test at
`build/core-assertion-environment-v1/result.json` confirms that missing required
coverage is rejected by the protected invocation; the old invocation accepted
that same damaged evidence under optimization.
The older `tb/run_core_control.sh` archives inputs but executes working-tree
code; use the new runner for new qualifications. Neither runner establishes
physical IO, macro behavior or broad solution yield.

`BUILD=build/uart-review ./run.sh uart` runs archived digital UART qualification
at DIV 8 and 16. `build/uart-robustness-v2/result.json` passes on Plan H's UART:
each divider receives all 256 byte values in nine back-to-back streams spanning
three start phases and bit periods of 98%, 100% and 102% of nominal. Independent
TX decoding, reset during ten RX and ten TX bit phases, every bad-stop data
pattern, and short start glitches are checked. Across both dividers, 4,628
valid RX bytes and 532 TX bytes pass. Receive bit-order, stop-bit and active-state
reset mutants are detected at both dividers. The runner requires the specific
fault assertion, not a compile error or timeout. This is digital protocol and
reset evidence; it does not establish metastability margins or physical CDC/RDC.
The `all` target includes this regression; build names must be fresh.

`BUILD=build/parser-review ./run.sh parser_formal` adds command-parser induction
on frozen current RTL with `BOOT_BIST=1` (one lane, DIV 16). Set `N=200`
for mainnet packet geometry; the default is N48/K5. Arbitrary decoded bytes,
all four static addresses and repeated reset are covered. The proof checks
header sequencing and preservation, CRC recurrence, address/length guards,
command strobes and atomic target/thermal commits. Healthy induction and five
reachable mutation checks pass at each geometry in
`build/parser-startup48-v1/result.json` and
`build/parser-startup200-v1/result.json`; all frozen inputs match current
source. The earlier `build/link-parser-formal-v4/result.json` covers archived
Plan H with startup BIST disabled.
The `all` target includes it. UART sampling, payload byte order, timeout
duration, mining behavior and physical CDC/RDC remain outside this proof.

`N=200 NH=16 BUILD=build/yield-review ./run.sh solver_yield` runs the packed
solver on diverse headers using frozen RTL, bench, models and the independent
Zig verifier. It uses an untruncated reference and requires every reference
solution to be retained on the selected corpus; bucket overflow never waives
missing solutions. Each build name must be fresh. A four-header N48 workflow
check passes with its one reference solution retained, and a damaged log with
that solution removed is rejected even when it reports row drops. Twelve
archive/qualification unit checks pass. The simulation in
`build/par-diverse200-plan-h-v1` completed all 16 mainnet headers from the
earlier capacity-model study, producing 33 solutions over 92,955,773 cycles.
The October 2 review verifies all 53 archived input hashes and all outputs
using the archived Python and Zig checkers; per-header reference counts
match, and all 25 generic RTL files matched the worktree before the startup
BIST changes. The original
runner has no final qualification result or completed reference-set audit.
This post hoc audit is retained in `production/verification_snapshot.json`
with that limitation. Activity/cycle logs do not establish power
or achievable clock. Use this runner for new yield qualifications; the legacy
`check_solver.py` PAR mode skips set comparison when rows overflow.

The runner now exposes `--engines`, `--hash-engines` and `--hash-split 1|2|4`;
the entry point uses `ENGINES`, `HASH_ENGINES` and `HASH_SPLIT`. Defaults remain
four engines at N48, sixteen at N200, one hash per solver and split one.
Hash count cannot exceed solver count. The RTL requires at least two solver
engines and strictly fewer engines than buckets (`1 <= PB < BB`); unsupported
geometries are rejected before archiving. Four paired N48 workflow checks preserve the exact complete solution
sets (one solution over four headers): 42,623 baseline cycles, 47,085 with one
hash, 62,061 with one quarter-step hash, and 56,532 with two solvers/one hash
(`build/hash-balance48-comparison-v1.json`). These measurements do not select
the production architecture or predict mainnet PPA/energy. The production
top now exposes `HPB` and `HASH_SPLIT`, retaining defaults `HPB=PB` and split
one. N48 full-core integration passes with one hash and split four. The N200
eight-hash/split-two packed production-top run now passes with one independently
verified solution, four forwarded packets, 124,622 backpressure cycles and all
required startup/reset/cancel/filter/BIST coverage
(`build/core-control200-hash-half-v1/result.json`). Its UART capture is identical
to both earlier default-hash configurations; all 25 archived generic RTL files
matched source before the optional bucket-zero extension. This qualifies digital control integration for that
configuration, not broad solution retention, physical memories or PPA. A scoped elaboration
check confirms unchanged default boundary wiring; it black-boxes the core
and does not prove full-chip equivalence.

The fresh sixteen-header N200 qualification in
`build/par-diverse200-current-v1` was interrupted by SIGTERM and records FAIL.
The rerun at `build/par-diverse200-current-v2` now passes all 33/33 exact
untruncated references over 16 headers in 92,955,773 cycles, with verified
source/executable/evidence binding. Its frozen RTL predates the bucket-zero
extension and production-top hash controls. The paired
sixty-four-engine simulation at `build/par-scale64-current-v3` completed after v2
hit its fixed 900-second compile timeout. It uses `--output-groups 0` and
`--compile-timeout 3600`; the entry point exposes `OUTPUT_GROUPS` and
`COMPILE_TIMEOUT`. The separate-file build passes the complete N48 audit
with byte-identical headers/output and 42,623 cycles versus the grouped
baseline. The v3 compiled RTL/bench, image and first four headers match the
mainnet baseline. Its independent output comparison against the completed
archived baseline fails: 10 versus 11 verified solutions on four shared headers,
with one solution missing on attempt 1. The fresh source/executable-bound
untruncated reference audit now also records FAIL: 10/11 retained, with no
reference truncation. The lower cycle total (7,073,439 versus 23,406,212) does not qualify
scaling while a solution is lost. The diagnostic and missing-solution witness
are in `build/par-scale64-retention-diagnostic-v1.json` and
`build/par-scale64-missing-solution-v1.json`; the cause still needs tracing.
These runs are separate from the completed archival output audit.

`solver_yield` also accepts `SLOTS` and `TRACE_DROPS=1` (direct runner:
`--slots` and `--trace-drops 1`). Slot address width follows capacity; defaults
remain unchanged. The optional `dropped_rows.csv` records each capacity-discarded
row's attempt, round, bank, bucket, slot, key, payload and parent/leaf field.
The source-bound evidence includes this trace, and reference loss still fails
qualification. N48 validation preserves the healthy baseline output and 42,623
cycles exactly; a constrained 16-slot case records all 1,024 reported drops and
is correctly rejected for losing a reference solution
(`build/par-droptrace48-validation-v1.json`). The mainnet solution loss is
reproduced on the first two headers in `build/par-scale64-droptrace-v1`.
The completed simulation preserves both failed outputs and cycle counts; its
trace accounts for all 1,774 reported drops, exclusively in bucket zero. One
round-5 discard at slot 640 matches the missing solution's required intermediate
value/key (`build/par-scale64-capacity-diagnostic-v1.json`). The trace does not
establish exact parent-subtree identity. Its reference audit confirms FAIL (4/5 retained).
This diagnostic prefix does not replace the four-header scaling qualification.
A four-header 768-slot experiment at `build/par-scale64-cap768-v1` has completed
simulation and passes exact comparison against all 11 qualified baseline
solutions in Python/Zig. It uses 7,218,699 cycles versus 23,406,212 for the
paired 16-engine baseline; the fresh untruncated audit now passes all 11/11
with source/executable/evidence hashes verified
(`build/par-scale64-cap768-comparison-v1.json`). Uniform expansion adds 27.600896 MB logical
SRAM (140.888064 to 168.488960 MB), so production capacity remains unselected.
The solver now supports optional `BUCKET0_SLOTS` (runner `--bucket0-slots`),
defaulting to regular capacity and constrained to existing slot bits. Local
640/768 expansion adds only 6,896 logical bytes. N48 BIST/reference tests pass,
including a pressure test that writes 44 extra rows and reaches the final added
 slot; synthesized RAM depths match the model. Its four-header mainnet test
completed at `build/par-scale64-bucket0-768-v1` with `BIST_FIRST=1` and drop tracing and
passes the exact 11/11 reference-set audit
(`build/par-scale64-bucket0-768-v1/result.json`).
The option is forwarded through production top/core; N48 integrated
control/startup-BIST passes in `build/core-control48-bucket0-v1`. Mainnet
production integration and selection await qualification. Optional
`bucket0_capacity.csv` records accepted extra rows by round.
Separate-table N48 integration passes with the capacity-aware checker in
`build/core-control48-bucket0-separate-v2`; a mismatched checker capacity is
 rejected. Full 64-engine N200 production-top control/BIST qualification
completed at `build/core-control200-bucket0-scale64-v1` and passes with one independently
verified solution, four forwarded packets, BIST/reset coverage and backpressure
(`build/core-control200-bucket0-scale64-v1/result.json`).

After both runs complete and pass their source-bound reference audits,
`model/compare_rtl.py BASELINE/run CANDIDATE/run --headers 4 --output REPORT`
compares their first four headers with independent Python/Zig verification.
The explicit limit permits different total corpus sizes, records both sizes,
and restricts cycle totals and solution-set claims to the selected shared inputs.
Both entire logs must still be complete. Without `--headers`, full corpora must
match. Eleven comparison tests pass, including incomplete-tail rejection and
lost-solution detection with a selected prefix; this tool does not replace the
source/executable binding or untruncated-reference qualification.

`tb/audit_par_archive.py` separately audits an existing frozen simulation log.
It requires independently recorded input/output SHA-256 values, copies and
verifies the archived models, verifier and logs, and regenerates complete
untruncated reference sets. Matching counts are insufficient; every solution
must match, even when rows overflow. The original archive stays intact and
the new result explicitly excludes simulation replay and recovery of the
original executable's provenance. Fifteen audit tests pass, including
interruption cleanup and preservation of a failing verdict. A four-header
N48 audit passes, and an actual missing-solution mutation with 999 reported
row drops is rejected. The 16-header mainnet audit passes in
`build/par-diverse200-reference-audit-v1`: all 33/33 complete untruncated
reference solutions match the archived RTL outputs exactly.
An archival audit does not qualify the changed production RTL or its power.

Release preparation now binds packaging and equivalence to the selected
run's archived RTL and constraints. The packager requires matching physical
signoff and final-netlist equivalence, stages every required SDF/SPEF view,
and hashes installed files before and after precheck. The release/evidence
suite has 67 passing tests at the October 2 review; the earlier model suite
has 20 passing tests. The tracked
`production/blocked_sources.json` registry rejects known-defective source
hashes even when a run-directory marker is missing. A mapped-circuit
equivalence smoke test passes and its faulty counterpart is rejected.
Plan D partitioned synthesis equivalence timed out after 3600 seconds;
it is unproven and cannot qualify the defective source for release. The
macro timing gate also rejects the installed typical-only SRAM Liberty
being reused at slow/fast voltage and temperature corners. Reviewed,
characterized SRAM views remain necessary. Final routing,
corner-complete signoff and final-netlist equivalence remain pending.

## SRAM read gating and collision-group replay (October 7, 2026)

The normal pipelined walker now enables the value/key read port only when
stage B contains a valid row and the pipeline can advance. Idle pairing and
pipeline-drain cycles no longer issue unused reads. This does not change
row selection, arbitration, group capacity or the collision algorithm.

On the same 16 diverse (48,5) headers with 128 slots and packed tables,
the original and gated walkers both retain all 11 independent reference
solutions in exactly 288,524 cycles. All-engine SRAM read payload falls
from 4,329,354 to 3,187,378 bits (26.38%); write payload is unchanged at
3,433,446 bits. This is digital activity, not measured joules, mapped area
or a mainnet efficiency estimate. Evidence:
`build/read-gating48-comparison-final.json` and the source-frozen qualifications
`build/replay48-baseline` and `build/read-gated48`.

A controlled (200,9) comparison now uses the same two headers, 16 engines,
packed tables, 640 regular slots, bucket-zero capacity 768 and startup BIST.
Both versions retain all 5/5 independent reference solutions in exactly
11,759,882 solver cycles. All-engine read payload falls from
6,297,056,224 to 6,210,169,232 bits (1.38%); writes remain
7,275,812,072 bits. This is busy-window logical activity, not measured
energy or a population-yield estimate. See
`build/read-gating200-comparison.json` and
`production/read_gating_mainnet_review.json`.

`model/compare_read_gating.py` verifies source snapshots, executable and
artifact hashes, tool/geometry/header equality, independent solution sets,
cycle/drop equality and unchanged write payload. It permits only the gate
and the exact `oq` declaration relocation needed for Yosys width resolution.
The relocated RTL is independently source-frozen in
`build/read-gated200-synthfix`; the ungated baseline is `build/read-ungated200`.

The local synchronous-read contract proves that consumed words remain equal
under arbitrary upstream validity and stalls. Two deliberately broken gates
produce counterexamples. Six mapped read-enable cones (before/after at
5/25/100 fF) pass RTL equivalence. SKY130 typical-corner ABC results show an
isolated-cone area increase and no delay increase at those loads; upstream
paths, wiring and real SRAM loading remain uncharacterized. This is a local
contract and cone check, **not full-solver sequential equivalence or routed
STA**. Evidence and scripts are in `build/read-gating-formal`.

Full 16-engine coarse synthesis passed initial structural checks, but two
600-second attempts stopped in FSM analysis and memory-priority optimization.
Those historical attempts are retained in `build/read-gating-mainnet-synthesis`.
The counter-reset rewrite below addresses the memory-priority bottleneck;
production technology mapping and physical signoff remain open.

```sh
python3 model/compare_read_gating.py build/read-ungated200 build/read-gated200-synthfix \
  --output build/read-gating200-new-comparison.json
# Select the installed tools and a characterized Liberty file explicitly.
python3 formal/qualify_read_gating.py --build build/read-gating-new-formal \
  --yosys "$YOSYS" --mapping-yosys "$MAPPING_YOSYS" --abc "$ABC" --liberty "$LIBERTY"
```

`GROUP_REPLAY=1` is a separate experimental walker. `GMAX` becomes the
anchor-buffer size instead of a hard collision-group limit. It streams
later partners from the sorted source bucket, then rereads the remaining
suffix with the next anchor block. Every equal-key pair of retained rows
is enumerated exactly once. Equal hash values with different slots are
preserved. Slot IDs and parent pointers retain their existing format.
Bucket-capacity losses are still possible, and changed emission order can
change which rows survive overflow. This is not an early ancestry filter.

The first implementation serializes reads and pairs rather than overlapping
the legacy collector and emitter. On that same 16-header corpus, replay
with eight anchors retains 11/11 solutions but needs 3,712,473 cycles
(12.87 times the baseline) and more read traffic. It remains **disabled by
default** and is not a selected competitive architecture. Its role is an
exact bounded-buffer candidate and measurement baseline for future work.
Do not infer that a smaller buffer reduces total energy or that these
small-parameter results qualify (200,9) replay.

The pair unit tests cover buffers 2/8/16, all bucket lengths 0 through 64,
oversized and adjacent groups, equal values with distinct ancestry, variable
read latency, output stalls, and cancellation/reset followed by restart.
The integrated replay case additionally covers separate SRAM tables,
staged networking, startup/reset BIST, UART flow control and cancellation.

```sh
BUILD=build/replay-unit-review ./run.sh group_replay
N=48 NH=16 SLOTS=128 BUILD=build/replay-review GMAX=8 GROUP_REPLAY=1 ./run.sh solver_yield
# Both runs must use the same complete header corpus and SRAM geometry.
python3 model/compare_rtl.py build/replay48-baseline/run build/read-gated48/run \
  --n 48 --k 5 --activity --output build/new-activity-comparison.json
```

`solver_yield` binds GMAX and GROUP_REPLAY in its archived compile parameters;
its independent reference remains untruncated and does not inherit the
candidate's group cap. `core_control` also accepts these environment flags.
The legacy `par` command rejects nondefault GMAX/GROUP_REPLAY experiments;
its old checker can waive set comparison on overflowing attempts. Use
`solver_yield` for these experiments.
Activity comparison rejects incompatible/missing table records and cannot
be combined with a partial-header comparison because counters cover the
entire run. Parent-pointer recomputation and hash-only deduplication are
not introduced: the former does not reduce this layout's peak slice count,
and the latter can discard distinct valid ancestry.

## Physical design

See [TAPEOUT.md](TAPEOUT.md): LibreLane on SKY130, block and full-chip
results, and a readiness checklist.

`pd/screen_sram_slew.py` provides a reproducible SRAM address-driver/load
screen using the selected run's unchanged TT Liberty files. Run it inside
the pinned EDA container, with a fresh build directory:

```sh
python3 pd/screen_sram_slew.py --config pd/wrapper/runs/h/resolved.json \
  --build build/sram-slew-review \
  --image-id sha256:897f703b9de811e792eb22023fd0986418bbbd9ae5ff511eb74419008eac810f
```

The 192-case result in `build/sram-slew-screen-v3/result.json` shows narrow
margin: the best tested buffer meets 40 ps with zero wire capacitance, but
none meets it with 5 fF added. The tool archives libraries, fixture, script,
tool identity, net loads and measurements; seven evidence checks pass.
It is an ideal-wire diagnostic and cannot qualify physical timing or release.


## Counter-reset synthesis qualification (October 7, 2026)

The per-bucket fill counters now reset through constant array addresses,
with a parity condition on each row. This clears the same destination bank
as the previous variable-address loop, while avoiding its large inferred
write-priority network. The change targets synthesis tractability; it does
not change solver capacity, cycle count or the mining algorithm.

`formal/qualify_fill_reset.py` accepts only this exact source rewrite and
proves sequential equivalence for an arbitrary watched counter row, starting
from equal but otherwise unconstrained states. Five bank sizes, including
the mainnet configuration's 512 rows, pass induction; five wrong-parity
mutants produce reachable counterexamples. This is a local counter-state
proof, not full-solver or mapped-netlist equivalence.

`pd/qualify_solver_synthesis.py` archives and hashes the RTL, scripts and
RAM inventory model, resolves the Docker image to its content ID, and runs
bounded native Yosys stages. It retains table SRAMs, maps internal memories
and logic to generic gates, rejects unexpected remaining coarse cells, and
reconciles table shapes and capacity before and after logic mapping. Generic
gates and logical SRAMs do not establish foundry area, frequency or power.

The 16-header (48,5) regression retains all 11 reference solutions in
288,524 cycles. The two-header (200,9) regression retains all 5 in 11,759,882
cycles; its complete solver output and five header/activity/profile files
are byte-identical to the prior gated RTL. The new run includes startup BIST.

Source-frozen mainnet coarse synthesis and structural checks now complete,
with 288 table RAMs totaling 1,126,852,480 bits (140.85656 decimal MB).
Small-parameter generic mapping also passes. Full mainnet generic mapping
remains open: both the initial run and a retry with additional optimization
exit with code 137 during gate expansion under a 12 GB memory limit. The
failed logs are preserved; they do not qualify a complete mapped netlist.
The current synthesis runner maps deterministic batches, optimizes after each
batch, checks the SRAM count throughout, and records per-stage input hashes
and memory counters. Completed coarse synthesis can be reused only when its
source, parameters, tool image, script and artifact hashes match. Optional
lossless checkpoint compression includes restoration hashes.

The updated flow passes end to end on N48 in
`build/a-batched-synthesis48-v3`, including coarse-result reuse and compressed
checkpoints. All 65 evidence hashes and four restored checkpoints were
rechecked; 18 synthesis evidence tests pass. The full mainnet run and
equivalence remain open. See
`production/independent_engineering_review.json` for the active runs and
the remaining six production priorities. Licensed production PDK and SRAM
compiler access was confirmed unavailable on October 7.

The qualification results, regression comparisons and limitations are
recorded in `production/counter_reset_synthesis_review.json`.

```sh
python3 formal/qualify_fill_reset.py \
  --baseline build/read-gated200-synthfix/source/asic/chip/rtl/zeq_eh_par.v \
  --build build/fill-reset-new-proof --yosys "$YOSYS"
python3 pd/qualify_solver_synthesis.py --build build/solver-synthesis-new \
  --n 200 --engines 16 --slots 640 --bucket0-slots 768 --coarse-only
python3 -m unittest pd/test_solver_synthesis.py
```

To map an existing verified mainnet coarse result without repeating elaboration:

```sh
python3 pd/qualify_solver_synthesis.py --build build/solver-batched-new \
  --n 200 --engines 16 --slots 640 --bucket0-slots 768 \
  --reuse-coarse build/solver-synthesis200 --compress-checkpoints
```

The exact synthesized logical memory demand and any compiler-facing views are
tracked in the private production package (not included here).

The small-solver equivalence diagnostic now proves the complete `dropped`
and `sol_rdata` output partitions. Its former `dsum` failure came from an
internal correspondence that synthesis did not preserve. The producer logic
remains in the output proof when that internal match is removed. Deliberately
inverting either observable output's low bit produces a counterexample; both
unchanged controls pass. Evidence is in
`build/solver-equivalence48-controls-v1/result.json`. This is N48
coarse-to-generic partition evidence, not full-solver or mainnet equivalence.

`formal/cec/partitioned.py` now supports exact internal correspondence
exclusions through `--unmatch-net`; top/SRAM ports and their aliases are
rejected. This uses [EQY's matching rules](https://yosyshq.readthedocs.io/projects/eqy/en/latest/config.html#match-sections)
without deleting logic or output obligations. Acceptance also checks every
boundary output bit against the generated partition metadata, in addition to
requiring global and per-partition proof verdicts. The 49 equivalence-harness and boundary tests pass;
the complete small-solver proof remains in progress.

The scalarized proof path checks all 3,988 individual pins corresponding to
the 498 logical N48 proof ports. It preserves each Yosys scalar pin's index
metadata and rejects missing, extra, misdirected or misindexed pins.
Scalar state bits propagated to constants retain their actual producer in
consumer partitions, preventing impossible independent cut-point values.
The prior full diagnostic was stopped after exposing these partitioning
failures; its traces remain available. The corrected proof is still open.

Compiler-generated private wires and flattened function-local names are
excluded from correspondence rules while retaining their circuit logic.
The configuration rejects any boundary-port collision with that generated
namespace. This avoids unstable compiler temporaries becoming proof cut
points; it does not omit any top-level or exposed SRAM obligation.

The optional `--state-only` correspondence mode matches every scalar
boundary pin and common register state while keeping intermediate
combinational logic inside proof cones. Exact identity names are batched
in groups of 128 to avoid repeated whole-design name scans. Both matching
selection and batched syntax have real EQY setup checks; these are not
solver equivalence verdicts. The broad scalar partition diagnostic hit a
confirmed 6 GiB memory limit. The subsequent state-based run constructed
partitions at a 4.79 GiB peak, then stopped on preparation/proof timeouts.
Longer independent retries prove the arbiter and controller partitions;
the queue retry timed out during AIG preparation at 900 seconds, before
PDR returned a verdict. No counterexample or cgroup OOM was reported.

`build/solver-rtl-boundary48-v2/result.json` additionally checks an archived
RTL-elaborated reference against the coarse design: all 18 original ports
and 48 SRAM contracts match, including read registration and collision
semantics. This prepares the RTL-to-netlist proof but does not complete it.

The RTL-origin reference now also passes normalization and exact scalar
boundary auditing (`build/solver-rtl-normalize48-v1/result.json`): all 48
SRAM contracts and 3,988 pins are preserved. This is preparation evidence,
not a logic-equivalence verdict. The full RTL-to-generic diagnostic in
`build/solver-rtl-equivalence48-v1` was deliberately stopped after actual
partition counterexamples: 308 strategies passed and 20 failed at the stop
checkpoint. Full equivalence remains unproven; the failure traces are retained.
It uses `--strategy smt-pdr` to try SMT induction before PDR, with all
partition and output-coverage requirements unchanged. The controller retry
passed with SMT in 43 seconds after the earlier PDR timeout. All 49 harness
and boundary tests pass, including the additional strategy order and
wire-relative output indexing.

`tb/compare_architecture.py` compares completed source-frozen architecture
runs. Both must pass the complete reference-set audit. It requires identical
headers, RTL, testbench, reference models and native verifier, and rejects
any parameter change that was not explicitly declared. Different engine
counts are summed over complete per-engine activity profiles; these counts
are not physical energy. The verifier can be pinned with
`tb/qualify_par.py --verifier PATH` without replacing the default native build.
The paired-comparison and affected archive/model suite passes 52 tests.

The first paired 16-header mainnet variant completed in
`build/a-mainnet16-hash8-v1`: 16 solver engines, 8 hash engines, split 1,
640 regular rows and 768 bucket-zero rows, with startup BIST. Both it and
the 16/16 baseline retain all 33 complete reference solutions. The independent
comparison in `build/mainnet16-hash8-comparison-20261011.json` passes, including
archive/executable hashes and exact solution sets. All 25 archived generic
RTL files match the current worktree. Eight hash engines take 123,377,507
cycles versus 92,959,466 (32.72% more), with essentially unchanged logical
table-memory traffic. Physical power and architecture selection remain open.
To reproduce the comparison, use a fresh output path:

```sh
python3 tb/compare_architecture.py \
  build/a-mainnet16-persistent-v1 build/a-mainnet16-hash8-v1 \
  --vary HPB --output build/mainnet16-hash8-comparison-v1.json
```

The generated RTL-origin proof covers all 2,264 output bits across 1,343
partitions (`build/rtl-equivalence48-v1-output-coverage-v2.json`). The checker
now uses EQY's wire-relative output indices: a scalar pin named `q[7]` has
local bit 0 even when its declaration retains offset 7. Missing or misnamed
pins still fail. This fixes an acceptance-checker error; it does not resolve
the retained internal control/data counterexamples or establish equivalence.

`formal/cec/compose_partitions.py` now prepares source-bound diagnostic
compositions of complete archived partitions. Every selected output remains
asserted, and joined signals use each implementation's own producer. The
pointer option adds assertions for synthesis-created memory-address register
copies; it does not assume those copies are equal. Alias restoration accepts
only scalar identities verified in both original normalized netlists. The
original full-run FAIL remains intact; these scoped proofs cannot qualify
the complete solver or a release.

The N48 walker/SRAM-control composition passes induction with 100 assertions
(`build/equiv-walker-depth2-20261011/result.json`). The digest composition
passes all 1,472 outputs after restoring 480 verified aliases
(`build/equiv-hash-aliases-v2-20261011/result.json`). Intentionally inverted
pointer and digest outputs both produce counterexamples. A separate
sequential-circuit control proves when its producers are joined, rejects
the invalid isolated cut, and detects an injected logic fault
(`build/composition-controls-v2-20261011/result.json`). These diagnoses
address proof decomposition without changing solver RTL or mapped logic.
The candidate-queue composition also passes all 400 assertions at depth
three (`build/equiv-queue-depth3-20261011/result.json`), including pointer
copies from all four engines. Together these scoped compositions prove all
ten partition groups that originally produced counterexamples. They do not
establish a complete verdict across the original 1,343 partitions.
The same walker/SRAM-control composition also passes 100 assertions on each
of engines 1, 2 and 3 (`build/equiv-walker-matrix-20261011/result.json`).
Across the successful compositions, 110 distinct original partition groups
have scoped proofs. Digest proofs now pass on all four engines. Broader
walker-control and grow-table compositions also pass on all four engines,
with 212 and 244 assertions per engine respectively
(`build/equiv-walker-closure-matrix-20261011/result.json` and
`build/equiv-grow-closure-matrix-20261011/result.json`). The separate queue-valid composition passes its 236
assertions as well (`build/equiv-queue-valid-20261011/result.json`).
Value-table compositions pass all four engines with 342 assertions per
engine, including 180 additional address-copy assertions. Engines 1 and 2
pass in `build/equiv-value-closure-matrix-20261011`; engines 0 and 3 pass in
`build/equiv-value-closure-long-matrix-20261011`. The extended retries use
identical circuits and assertions with a longer timeout; the original
timeouts remain preserved.
To prepare the digest proof again, use a fresh directory:

```sh
python3 formal/cec/compose_partitions.py \
  --origin build/solver-rtl-equivalence48-v1 \
  --build build/equiv-hash-aliases-retry \
  --partition zeq_eh_par.g_eng.0.dig_r.0 \
  --partition zeq_eh_par.g_eng.0.g_h.u_hash.mid.0 \
  --restore-aliases --depth 2
```

Run the generated `proof.sby` with the pinned proof toolchain recorded in
the archived result. Depth two still requires both base-case and induction
proofs. Timeouts and unknown results remain failures to qualify. The
`--all-pointer-engines` option checks every discovered address-copy profile
within each selected partition; each profile must match the inspected
scalar representation exactly.

`formal/cec/cover_partitions.py` inventories all 1,343 original obligations
and prepares a continuation from actual completed proofs. Cached strategy
messages are not proof evidence. Reuse checks the original partition hashes,
complete inductive verdict, exact assertion-enabled proof configuration and
the circuit files actually copied into the proof. Changed or vacuous proofs
are rejected even if their report hashes have been regenerated.

Prepare a fresh continuation with `--origin`, `--composition-review`,
`--build` and optional repeated `--prior-coverage` arguments. Execute the
frozen runner inside the pinned tool image with the original run mounted
read-only at `/origin`. Its aggregate remains `PARTIAL` and ineligible for
release: individual partition passes do not manufacture a global EQY verdict.

The independently validated union in
[`production/partition_coverage_review.json`](production/partition_coverage_review.json)
covers 1,342 of 1,343 original N48 obligations across the original run,
both continuation sweeps and completed compositions. The remaining
obligation is `zeq_eh_par.q_v.0`. The original full-run FAIL remains intact;
this coverage does not qualify mainnet, full-chip equivalence or a release.
The queue-value composition in `build/equiv-queue-value-20261011-v3`
reaches SMT solving but times out at 1,800 seconds without a completed
proof or counterexample. Its recorded storage pause counts toward that
wall-clock limit. Earlier 3 GiB out-of-memory and 600-second timeout
attempts are preserved separately. The retry keeps all 6,000 assertions
and uses 8 GiB; no timeout is counted as coverage.

The October 12 unpaused retry (`build/equiv-queue-value-20261012-v4`)
also times out at 1,800 seconds with a 12 GiB limit, without a completed
proof or counterexample. The refreshed coverage review still validates
1,342/1,343 obligations; the original full-run verdict is unchanged.

The completed continuation in `build/a-mainnet-synthesis-finish-20261011-v2`
passes all 24 batches, final optimization, ABC mapping and independent SRAM
inventory reconciliation. Its 1,932,766 generic cells retain all 288 logical
SRAMs and 1,126,852,480 bits. This is a source-bound generic synthesis PASS;
production mapping, PPA and mainnet equivalence remain separate gates.

The earlier mainnet synthesis resume in `build/a-mainnet-synthesis-resume-20261011`
verified and reused 18 completed batches, then completed five additional
batches. Nine coarse cells remained. That run is FAIL because the next stage
was rejected by the 10 GiB disk guard; it is not a generic-synthesis PASS.
To reproduce the continuation from that verified prefix in a fresh build,
keep the same source, tool image and geometry:

```sh
python3 pd/qualify_solver_synthesis.py \
  --build build/mainnet-synthesis-next \
  --n 200 --engines 16 --slots 640 --bucket0-slots 768 \
  --resume-mapping build/a-mainnet-synthesis-resume-20261011 \
  --compress-checkpoints --startup-timeout 600
```

The resume evidence tests reject altered checkpoints, scripts, selections,
source/tool/parameter changes, invalid stage verdicts and broken hash chains.
Every continuation still requires final optimization, generic ABC mapping
and complete SRAM inventory before reporting PASS.

Verified immutable checkpoints share storage through hard links when the
archive and continuation use the same filesystem; mutable mapping ledgers
are copied separately. `--startup-timeout` controls the additional container
startup allowance without changing the Yosys stage execution limit or the
10 GiB free-disk guard.

The historical failed Plan D EQY working directory is preserved losslessly
in `build/plan-d-lec-eqy-v1/eqy.archive.tar.gz`. Its `eqy.archive.json`
records all 3,766 entries, original file hashes and the verified archive
hash. The original FAIL result and its eleven bound root artifacts remain
in place. Restore the working directory from that build directory with
`tar -xzf eqy.archive.tar.gz` when needed; allow about 16 GiB of space.
The completed failed Plan H SMT intermediates are archived the same way in
`build/plan-h-lec-smt-v1`: all 46,200 entries were verified before removing
the raw directory, while the FAIL verdict and twelve bound root artifacts
remain untouched. Its manifest records the archive hash and restoration
command; allow about 11 GiB to restore it.
The failed Plan H EQY intermediates in `build/plan-h-lec-eqy-v1` likewise
retain all 47,701 entries in a verified archive. Its original FAIL and
twelve bound root artifacts remain in place; allow about 10 GiB to restore
the working directory using the command in its manifest.

The October 12 alternate queue proof retains all 6,000 assertions but times out
during model preparation, before PDR search. Coverage remains 1,342/1,343.
See [the phase diagnosis](production/queue_equivalence_review.json); the
synthetic PDR controls and seven progress-parser tests pass.

The subsequent early-compaction experiment, `build/equiv-queue-compact-pdr-20261012`,
reduced the serialized model by 44.6% while preserving all 6,000 assertions
and 11,464 assumptions by cell type and identity. It still timed out during
preparation at 600 seconds with an unchanged 8 GiB cap; PDR search never started.
Positive, duplicate-assertion, and injected-fault controls pass, as do seven
preparation tests. These checks do not close the remaining obligation.
