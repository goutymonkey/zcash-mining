# Formal verification

Four layers of formal verification, each matched to what it can check:

| Layer | Tool | Checks | Run |
|---|---|---|---|
| Algorithm | Lean 4 (core, no Mathlib) | The hardware's solution construction is sound for Zcash, and bucketing and flow-control sizing are correct | `./run.sh lean` |
| Protocol / architecture | TLA+ (TLC) | Chain protocol, the P-engine crossbar round, job tagging | `./run.sh tla` |
| RTL blocks | Yosys SAT (induction / BMC) | Arbiter, UART, FIFO | `./run.sh formal` |
| Implementation | ABC sequential equivalence (`dprove`) | RTL ≡ routed netlist; synthesis ≡ routed; scan insertion transparent with scan off | `./run.sh lec` |

Simulation stays the main check that the RTL implements the algorithm
(bit-exact against `model/`, every solution through two independent
verifiers). The proofs cover what simulation can't enumerate: all
interleavings of the protocol, all timings of the arbiter, all values in
the soundness argument, and every gate of the netlist.

## Lean: `lean/Zeq/*.lean`

No `sorry` and no axioms beyond Lean core. Each module lists what it proves:

- **Soundness** is over an abstract `ChunkSpace` (XOR group plus
  per-chunk projections). `built_valid`: every tree the hardware builds
  (pair rows whose next chunk collides, store the XOR with the collided
  chunks masked) satisfies Zcash's recursive collision conditions.
  `final_sound`: the final-round pair XORs to zero.
- **Model** gives a concrete `ChunkSpace` (K+1 chunks of CB-bit
  `BitVec`s), so the axioms are satisfiable and are exactly the
  hardware's value format.
- **Ordering**: the ORD/SWP step (`canon`) only permutes leaves
  (`canon_perm`), keeps validity and the XOR (`canon_valid`,
  `canon_X`), and with distinct indices yields Zcash's `IndicesBefore`
  order at every node (`canon_ordered`, `ordered_lex`).
- **Bucket**: splitting a key into bank bucket and local key is
  lossless. Equal keys always meet in the same bank (`bucket_split`,
  `group_same_bucket`), which is what makes the ZEQ-200X bucket-parallel
  solver find the same collisions as a global sort.
- **FlowControl**: the upstream FIFO never overflows with the RTL's actual
  `FIFO_AW` and `ROOM` at (48,5), (96,5) and (200,9), including 1/64
  oscillator drift. Checked by kernel evaluation (`decide`).

## TLA+: `tla/*.tla`

| Spec | Model | Properties | Result |
|---|---|---|---|
| `ChainProtocol` | 3 chips, 1–2 byte packets, FIFO = 2 packets, ROOM rule | `NoOverflow`, `NoInterleave` (packets never mix on RO), `InOrder`, liveness `AllDelivered` | pass |
| `ParRound` | 2 engines, 2 rounds, 1 slot per bank (the drop path is exercised) | `Conservation` (every row stored or counted as dropped), `RoundSeparation`, `Capacity`, liveness `Terminates` | pass |
| `JobTags` | 3 jobs, 2 lanes, queued reports | `CorrectTags`: each report carries its attempt's job id | pass |
| `JobTags_buggy` | the pre-fix RTL (id stamped at send time) | `CorrectTags` | **violation found**: this bug was in the RTL, and `rtl/zeq_link.v` now captures `lane_job`/`done_job` |

`./run.sh tla` also runs three mutants and requires TLC to find a
violation in each: a looser ROOM rule, the job id stamped at send time,
and a barrier that ignores in-flight requests. That shows the properties
aren't vacuous.

## Yosys SAT: `arb.ys`, `uart.ys`, `fifo.ys`

- `zeq_xbar_arb`: k-induction at P = 4 and 8. At most one grant, grants
  only to requesters, work-conserving, and a waiting requester is served
  within P grants.
- UART TX→RX loop: every byte is delivered intact.
- `zeq_fifo`: order and integrity, and level never exceeds capacity.
  Bounded check.

## Equivalence: `cec/cec.sh`

A Blake2b netlist and its reference are both lowered to their cell
functions (liberty `ff`/`function` for SKY130 cells, generic gates for the
RTL) and joined in a miter on matching ports. ABC's `dprove` then proves
the miter never fires from the imposed all-zero register state, for
every input sequence of any length under that model. This is not a proof
of arbitrary silicon power-up behavior. It finds register correspondence by
induction, so no name matching is needed. That handles what name-based
LEC can't: registers renamed or restructured by synthesis, buffers and
resizing from place-and-route, and scan flops.

| Check | Result |
|---|---|
| RTL (`SPLIT = 4`) ≡ routed netlist | **equivalent**: latch correspondence + k-step induction to 0 latches; physical timing/electrical signoff is separate |
| Synthesis netlist ≡ routed netlist | **equivalent** |
| Synthesis netlist ≡ scan-inserted netlist, `scan_en = 0` (`cec/scan0.v`) | **equivalent** |
| Mutant: scan mode left on (`cec/scan1_mutant.v`) | **counterexample** at cycle 98 (one Blake2b block) |
| Mutant: RTL with one `h_out` bit flipped (`cec/zeq_blake2b_mutant.v`), and RTL with `SPLIT = 2` | not proved equivalent (UNDECIDED, no counterexample within the budget: outputs change only at the end of a block, ~96 cycles deep). Run once and not in the regression. |

A mutant must never pass. The scan mutant, which is part of `./run.sh lec`,
must also produce a concrete counterexample.

`./run.sh scan` checks the other mode of the scan chain by simulation.
The 2125-flop chain shifts a random stream with 0 errors, and load /
capture / unload works.

Trusted steps: Yosys's reading of RTL and liberty models, and ABC. Both
sides go through the same readers, so a reader bug could hide a real
difference only if it hit both sides the same way. A commercial LEC
(Conformal, Formality) would be an independent second check.

## Full-chip run binding: `cec/chip.py`

`cec/chip.sh` now requires `RUN` and `SOURCE_MANIFEST`; see the invocation in
[TAPEOUT.md](../TAPEOUT.md#source-bound-release-preparation). It verifies the
archived source list and constraints against the selected run, then snapshots
the actual proof inputs into a fresh directory. It never reuses a synthesized
reference based on file modification times. Its JSON result binds the gate
netlist, source manifest, resolved run configuration and proof evidence by
hash. The release packager requires a passing result for the exact final
netlist and rejects changed proof inputs or logs.

The mapped XOR smoke test passes and the XNOR mutant yields a combinational
counterexample. ABC's `UNSATISFIABLE` combinational verdict is recognized
alongside its sequential `Networks are equivalent` verdict. A timeout or
undecided result never qualifies release. Full-chip synthesis equivalence
for Plan D timed out after 1200 seconds. No mismatch was established, but
no equivalence proof was obtained; routed-netlist equivalence remains required.

The proof still relies on `cec.sh`'s zero-initialization model and matched
SRAM cut points. It does not establish SRAM macro behavior, analog behavior,
physical signoff, or arbitrary uninitialized silicon behavior.

### Partitioned proof candidate

`cec/chip.py --engine eqy` preserves named internal signals and uses EQY
with SBY/ABC PDR to prove partitions. The input/archive checks are the same
as the ABC runner. It requires a global PASS, matching top/SRAM interfaces,
and a successful strategy for every generated partition. It hashes the
partition definitions, logs, strategy results and any counterexamples.
Missing partitions, timeouts and conflicting verdicts fail. This engine
is experimental and is explicitly rejected by release packaging.

`--eqy-strategy smt` selects SBY/Bitwuzla induction; `--eqy-strategy pdr-smt`
tries PDR followed by induction on unresolved partitions. The default remains
`pdr`. Both use [EQY's SBY prove strategy](https://yosyshq.readthedocs.io/projects/eqy/en/latest/strategies.html#the-sby-strategy),
with formal X propagation enabled. The induction search depth is five; a PASS
requires both the base case and temporal induction, not merely five simulated
or bounded steps. Every generated partition and the global verdict must pass.
A fallback PASS can resolve TIMEOUT/UNKNOWN, but cannot hide FAIL, ERROR,
an empty status or an unrecognized verdict. Seventeen unit checks cover these
rules and the existing alias matching. The fixture runner accepts the same
selection as `--strategy`; each invocation requires a fresh build directory.

`build/plan-g-word12-smt-v1/result.json` proves the exact archived hash-word
partition that timed out after 600 seconds with PDR. Bitwuzla completed both
the base case and induction in 189 seconds without changing that partition.
This supports investigating the alternative solver, not claiming full-chip
equivalence or qualifying the current Plan H netlist by itself.
Both strategy configurations subsequently pass all five mapped fixtures in
`build/eqy-smt-fixtures-v1/result.json` and
`build/eqy-pdr-smt-fixtures-v1/result.json`: the healthy circuit proves and
each deliberate fault has a reachable counterexample. All 24 release-bundle
unit checks also pass; experimental EQY evidence remains release ineligible.
An independent full Plan H run in `build/plan-h-lec-smt-v1` now uses
`--eqy-strategy smt --jobs 2 --partition-timeout 600 --timeout 14400`.
The original runs subsequently ended FAIL: PDR proved 1,484 partitions, with
two failures and three timeouts; SMT proved 1,487, with the same two failures
out of 1,489. Both failures involve index-SRAM read enables. Their traces set
`xs=8`, `ent_b=1`, `x_bank=0`, although the bank-selection logic requires
`x_bank=ent_b` in that state. A separate diagnostic retains the selector's
driver, and both read-enable outputs then prove in one partition:
`build/plan-h-bank-cut-diagnostic-v1/result.json`. This leaves the RTL/netlist
unchanged and does not establish a complete new full-chip proof.

`--eqy-bind-net` can retain an explicitly reviewed common scalar net's driver
in consuming partitions. Names must exist on both sides; constants, buses and
top/SRAM input aliases are rejected. It adds logic to prove without assuming
values or excluding outputs. The reviewed Plan H selector is
`mprj.u_tc.u_core.g_lane[0].g_par.u_solver.x_bank[0]`.

The runner normalizes both designs with Yosys `splitnets -ports` before
matching, so a reference vector can match the mapped netlist's individual
bit names. It groups each bus and joins overlapping aliases from either
design. This avoids circular cut points when a reference wire alias becomes
a mapped buffer. These are partition boundaries, not assumptions of internal
equivalence: every generated partition must still pass. Normalization scripts,
logs, JSON interfaces and RTLIL designs are included in the evidence hashes.
The rules follow the [EQY matching and collection syntax](https://yosyshq.readthedocs.io/projects/eqy/en/latest/config.html).

The proof uses [EQY's formal X propagation and safe-replacement semantics](https://yosyshq.readthedocs.io/projects/eqy/en/latest/xprop.html).
It does not force uninitialized registers to zero. SRAMs remain matched
cut points: memory read data is arbitrary and memory command pins are
compared. Physical memory behavior, timing and analog circuitry remain
outside the proof. A complete synthesis proof would still not qualify
a different routed netlist.

LibreLane 3.0.14 includes EQY but lacks GNU Make and shell helpers. On the host, run
`bash formal/cec/bootstrap_make.sh` once to build a project-local static
GNU Make from a pinned source archive and stage the host's static BusyBox.
This bootstrap needs GCC, make and `/usr/bin/busybox` built statically.
The proof runner exposes AWK/sed and the image's Bitwuzla locally and records
their hashes. No host installation is performed.
Then, inside LibreLane from `/work`, run:

```sh
python3 formal/cec/qualify_partitioned.py --build build/eqy-qualification-new \
  --library /work/pd/pdk/ciel/sky130/versions/8afc8346a57fe1ab7934ba5a6056ea8b43078e71/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
```

The qualification requires mapped sequential/SRAM equivalence for the
correct fixture and reachable counterexamples for reset, vector state-update,
scalar state-update and SRAM-address mutations. The mapped fixtures split
internal buses into named bits and exercise aliases that become buffers.
Mere failure to prove a mutant is insufficient.
The earlier four-check suite passes in `build/eqy-qualification-v6/result.json`;
it predates normalization and does not qualify the revised runner.
The revised five-check suite passes in
`build/eqy-normalized-fixtures-v3/result.json`: the correct fixture proves
all 11 partitions, and all four mutants produce Bitwuzla-validated traces.
Twelve unit checks cover matching, aliases and fail-closed verdict handling.
The resource-controlled runner also passes all five fixtures in
`build/eqy-resource-fixtures-v1/result.json`, using `--jobs 1` and
`--partition-timeout 600`. Both options are forwarded by `cec/chip.py` and
recorded in its inputs. EQY runs with `-k` so independent partitions continue
after a strategy error; qualification still requires every partition and
the global verdict to pass. Increasing a timeout changes the resource budget,
not the proof requirements. This fixture result does not establish full-chip
equivalence or make the experimental engine eligible for release packaging.
Plan G's longer-budget run reaches concrete fill-counter partition failures.
`build/plan-g-alias-diagnostic-v1/result.json` inspects eight validated traces:
each independently drives `fill_clr` and `kst[3]` to different initial values,
although both names refer to the same mapped wire. These are counterexamples
to the abstract partitions, not executable full-netlist traces. This observation
does not establish full-chip equivalence or classify other failed partitions.
A separate preparation experiment binds those two signals, using
[EQY's documented bind rule](https://yosyshq.readthedocs.io/projects/eqy/en/latest/config.html#bind-and-nobind)
to keep their driving logic inside the partitions. It changes proof boundaries,
not RTL or an equivalence assumption. The active full-chip run is left intact;
the diagnostic's `setup-result.json` is explicitly preparation evidence only.
The focused proof subsequently passes in
`build/plan-g-alias-diagnostic-v1/proof-result.json`: all 64 bits of the eight
engine-0 fill counters are proved in one 1,258-cell partition. The reusable
runner now detects asymmetric alias classes in either design and binds only
their members. Fourteen unit tests and all five mapped fixtures pass in
`build/eqy-alias-fixtures-v1/result.json`, including the four fault traces.
The original Plan G run was then stopped with 61 passing, eight failing and one
timed-out partition out of 1,511. Its artifacts remain archived. Full-chip
Plan H equivalence uses the corrected rule and remains unqualified until every
partition and the global verdict pass.
Full-chip synthesis verification in
`zeq-plan-d-lec-eqy-v1` timed out after 3600 seconds, with evidence under
`build/plan-d-lec-eqy-v1`; no full-chip equivalence proof was obtained.
That snapshot is now release-blocked by a reproduced BIST/JOB overlap:
even a successful equivalence verdict would prove implementation agreement
with defective RTL, not functional correctness or release eligibility.

## Command parser

`BUILD=build/parser-review ./run.sh parser_formal` proves the actual one-lane
N48/K5 command parser at DIV 16 with arbitrary decoded bytes, all four static
strap addresses and repeated reset. The harness checks header transitions,
preservation of type/address/length fields, legal lengths, a separately written
CRC recurrence, command strobes, and atomic target/thermal updates. A timeout
must return the parser to framing. The healthy case requires induction;
CRC bypass, address bypass, invalid lengths, skipped headers and payload-time
address overwrite must each produce a reachable counterexample. Tool failures
and timeouts cannot qualify a faulty case.
`build/link-parser-formal-v4/result.json` passes healthy induction and all five
fault cases; its archived RTL matches the Plan H snapshot and current source.

The UART outputs are symbolic inputs at the parser boundary; command strobes
and parser state remain actual RTL outputs. This proof excludes serial sampling,
JOB/target payload byte order, timeout duration, solver behavior and physical
CDC/RDC. Actual-UART matrices and full-core integration provide separate scoped
evidence. The `all` target includes this check, and each build name must be fresh.

## Link BIST ownership

`tb/run_link_bist.sh` exercises the actual UART parser and scheduler with
a delayed BIST acknowledgment and controllable completion/failure. It
reproduces mining during destructive BIST on Plan D's archived source and
passes against the corrected RTL. Tests cover latest-job replacement,
STOP while a JOB is queued, failed-test quarantine, successful retest,
reset, invalid CRC/payload and wire-level PONG status. A separate run with
`HAS_BIST=0` checks unsupported architectures remain operational without
falsely reporting a successful test.

`qualify_link_bist.py` cuts only the three decoded command strobes at their
actual RTL nets. The one-lane scheduler then sees arbitrary command,
lane-status and BIST-response interleavings, including stale DONE. The
independent request/completion monitor checks mining exclusion and failure
quarantine. Reachable-state invariants linking the monitor to the control
state are asserted and proved, not assumed. UART inputs are idle in this
proof; serial decoding is covered by simulation. It does not prove SRAM
fault coverage or analog timing. Broken stale-DONE and failure gates must
produce reachable counterexamples; failed induction is insufficient.
All three checks pass in `build/link-bist-formal-v3/result.json`. Earlier
attempts could not close induction from unreachable monitor states; they
remain archived. The final harness proves the additional state invariants
without adding input assumptions beyond initial reset.

## SRAM repair and diagnosis

`zeq_mbist` now records the first failing address, expected/observed word
and March element, plus a flag for failures at different addresses. The
new `zeq_repair_bank` candidate remaps a single logical row to a spare
through both ports, arbitrates application/BIST ownership, rejects unsafe
configuration changes and invalidates qualification when repair changes.
The physical memory contract is one-cycle registered reads, old data on
same-address read/write, and DEPTH+1 physical rows.

`BUILD=build/repair-review ./run.sh repair` runs healthy and fault-injected
memory simulation at depths 1, 5 and 64, including bad-spare retest,
read/write collisions, multirow diagnosis and reset during BIST.
`python3 formal/qualify_repair.py --build build/repair-formal-new`, inside
LibreLane, proves the adapter contract at those geometries using copied,
archived inputs. Broken read remapping, write remapping and stale BIST
qualification must each yield a reachable counterexample. Both matrices
pass in `build/repair-bank-v3` and `build/repair-formal-qualification-v1`.

This adapter is not wired into the production top. Volatile configuration
still needs a chip-level maintenance/control path and a persistent repair
loader. Compiler-specific redundancy, scan/ATPG and manufacturing pattern
qualification remain open. These tests do not prove physical fault coverage.
`app_ready` denotes port availability, not memory health: the future
chip-level controller must enforce a successful test before enabling mining.

## Packed SRAM: `qualify_packed.py`

`BUILD=build/packed-review ./run.sh packed_formal` runs whole-word induction
at (48,5)/PW18 and (200,9)/PW32, each at depths 2 and 3. Use a fresh BUILD
directory: the runner refuses to overwrite an existing qualification.
It archives the exact source files, Yosys version, scripts, log hashes and
per-case verdicts, and only produces PASS when every case succeeds.

The independent reference keeps separate per-round values and parents.
Checked invariants relate live values and retained parents to the DUT's
actual storage. Arbitrary write data and legal addresses, phase stalls,
reset, and cancellation/restart by returning to phase zero are allowed.
Reset invalidates reference rows but does not clear SRAM. Reads are checked
only for previously written rows; parent reads occur in the final phase.
BIST is never started, and its inactive state is itself asserted.

Three temporary RTL mutations corrupt value outputs, parent outputs, or
write addresses. Each must produce a reachable bounded counterexample;
timeout or failure to prove induction is insufficient. These checks exercise
the assertions and their assumptions, including final-phase parent reads.

This proves the stated concrete depths and parameter sets. It does not prove
arbitrary-depth memories, active BIST coexistence, compiler macro behavior,
physical timing, or the entire solver. Integrated RTL regressions and later
macro/final-netlist equivalence remain necessary.

September 30 result: all four induction cases pass, and all three mutations
produce counterexamples, including requalification after the BIST diagnostic
update. See `../build/packed-qualification-diagnostics/result.json`
and the artifact hashes in `../production/verification_snapshot.json`.

## What this does not prove

- **Layout.** No theorem prover checks polygons. DRC, LVS, antenna and
  XOR are the tapeout checks for layout (see [../TAPEOUT.md](../TAPEOUT.md)).
- **The whole chip's netlist.** Equivalence is proved on the hardened
  Blake2b block. The full test chip gets the same check once its run
  signs off (`cec/cec.sh` takes any pair of netlists).
- **The full RTL against the Lean model.** The Lean proofs are about the
  algorithm the RTL implements. The link between them is bit-exact
  simulation, not a proof.
- **The TLA+ models are small.** TLC checks every state of the stated
  configurations. `ChainProtocol` uses equal byte ticks and finite packet
  budgets; it excludes current per-hop pacing and the clock-drift overflow
  reproduced in RTL. Neither that model nor the Lean buffer-size argument
  establishes paced-chain safety or bounded progress with independent clocks.
- **Silicon.** Analog behavior, timing margins across process spread, and
  yield.
