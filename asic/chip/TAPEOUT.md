# ZEQ-200 tapeout readiness

Process evaluation artifacts (comparisons, review packets and supplier forms)
are maintained privately and excluded from this public snapshot. No final
production process is frozen here.

Both regular and extended memory tiles now have complete mainnet traces and
successful generic RTL replay, each over 14,383,447 cycles. The two runs use
the same two headers and retain the same five independently verified solutions;
this expands geometry coverage, not the workload corpus. Both traces include
startup BIST and are available as losslessly verified compressed payloads in
the comparison packet. Intake checks bind supplier responses to the supplied
trace hash, geometry variant and cycle count. See
[the trace review](production/tile_trace_review.json). Broader workload coverage
and physical macro characterization remain open; this does not qualify a
production process.

No manufacturing release or fabrication submission exists.

Current review (October 12, 2026): production tapeout readiness and competitive
wall efficiency remain unqualified. Plan H has synthesis and digital
verification evidence; its physical gate fails because post-route STA,
physical checks and IR results are absent. Its `final/` directory contains
synthesis exports, not a completed physical implementation.

The current closure record is
[`production/tapeout_readiness_review.json`](production/tapeout_readiness_review.json).
It records all eleven production release requirements and their remaining
actions, with hashes of the supporting evidence. None is closed by a SKY130
demonstrator result. Licensed production PDK/SRAM access remains unavailable
according to the October 7 access record; full-chip equivalence, production
DFT/repair and physical signoff remain required.

The latest scoped N48 proofs resolve all ten observed failing
partition groups from the stopped RTL-to-generic run. Walker/SRAM-control
induction passes 100 assertions on each of the four N48 engines, and digest induction passes all 1,472
outputs on each engine after restoring scalar aliases verified in both source netlists.
Pointer relationships are additional assertions, never assumed equality;
injected pointer and digest output faults both fail as expected. The
candidate-queue composition passes all 400 assertions with depth-three
induction; its earlier depth-two timeout remains archived separately. See
[`production/equivalence_composition_review.json`](production/equivalence_composition_review.json).
All 68 formal-flow tests and 99 physical-flow tests pass.
The compositions cover 110 distinct original partition groups in total.
The broader walker-control composition proves 212 assertions per engine;
the grow-table composition proves 244 per engine, including 162 additional
address-copy assertions. All four engines pass both matrices. Value-table
compositions also pass all four engines, with 342 assertions per engine,
including 180 additional address-copy assertions. Engines 0 and 3 pass the
extended retries; their earlier timeouts remain preserved.
The combined source-bound inventory validates 1,342 of the 1,343 original
N48 obligations. Only `zeq_eh_par.q_v.0` remains uncovered; see
[`production/partition_coverage_review.json`](production/partition_coverage_review.json).
Its latest 6,000-assertion composition retry, `build/equiv-queue-value-20261012-v4`,
exhausted the full unpaused 1,800-second limit with 12 GiB memory available.
No completed proof or counterexample resulted. The earlier storage-paused
attempt remains preserved separately.
An alternate PDR attempt, `build/equiv-queue-value-pdr-20261012`, retained the
same 6,000 assertions but exhausted its 600-second budget while preparing the
model, before ABC PDR search started. Shared-host memory pressure required
lowering its container cap from 8 GiB to 4 GiB. Its result does not establish
whether PDR can solve the obligation. Synthetic positive/fault controls pass,
and seven progress-parser tests distinguish model preparation from engine
search. See [the queue diagnosis](production/queue_equivalence_review.json).
Coverage remains 1,342/1,343; the prior failed and timed-out runs are preserved.
These are scoped verification improvements; the original full proof remains
FAIL and the requested A tapeout grade has not been achieved.

The source-verified mainnet continuation passes complete generic synthesis
in `build/a-mainnet-synthesis-finish-20261011-v2/result.json`: all 24 mapping
batches, final optimization, generic ABC mapping and SRAM reconciliation
complete. The 1,932,766 generic cells include all 288 logical SRAMs, retaining
1,126,852,480 bits; no coarse logic cells remain. Earlier disk-guard and
startup-timeout failures remain archived. This establishes generic synthesis,
not production PPA, mainnet equivalence or physical signoff.

The current-source sixteen-header mainnet baseline and eight-hash-engine
variant both completed and retain all 33 untruncated reference solutions.
The independent paired comparison passes, rechecking archived sources,
executables, evidence hashes, complete solution sets and memory activity.
All 25 generic RTL files in the baseline archive match the current worktree.
With sixteen solver engines, reducing hash engines from sixteen to eight
increases cycles from 92,959,466 to 123,377,507 (32.72%); logical table-memory
traffic is essentially unchanged. This is solver-level digital evidence,
not full-chip qualification or measured power. The comparison is archived in
`build/mainnet16-hash8-comparison-20261011.json`.

The October 11 Plan H signoff rerun rejects nine missing physical-evidence
checks (`build/signoff-review-20261011.log`). Release packaging now also
requires explicit boolean LEC eligibility and an explicit qualified engine
matching the hash-bound proof inputs. Missing fields, non-boolean eligibility,
and experimental-engine relabeling fail before staging. The proof producer
emits eligibility only for successful ABC runs; EQY remains ineligible.
Older proof results without these fields require a fresh proof run rather
than manually changing archived verdicts. All 99 physical-flow tests and
10 paired-architecture comparison tests pass.

The current production top requires startup memory BIST after every reset.
Jobs remain held until a fresh successful completion; STOP cancels a queued
job and failed BIST quarantines mining. Ten UART checks at N48/N200, scoped
ownership induction with three reachable fault checks, and integrated N48
startup/reset qualification with packed and separate tables pass. Mainnet
packed production-top integration passes in
`build/core-control200-startup-bist-v1`, with one independently verified
solution, four forwarded packets and all required startup/reset/control/BIST
coverage on the source before independent hash controls were exposed. Mainnet separate
tables also pass in `build/core-control200-startup-separate-v1`, with the same
required coverage and a byte-identical UART capture. The models are
behavioral RAM; these runs do not qualify physical compiler behavior or IO.
Persistent repair
loading, compiler test integration and manufacturing DFT remain open.
The production top now exposes `HPB` and `HASH_SPLIT`, preserving defaults
`HPB=PB` and `HASH_SPLIT=1`. A scoped elaboration check confirms identical
default boundary wiring and correct alternative parameter forwarding, with
the core black-boxed. N48 one-hash/quarter-step full-core integration passes;
the actual N200 eight-hash/half-step packed run now passes in
`build/core-control200-hash-half-v1`. It verifies one solution, four forwarded
packets, 124,622 backpressure cycles and all required startup/reset/cancel/filter/BIST
coverage. All 25 archived generic RTL files matched source before the optional
bucket-zero capacity change; the executable,
source archive and evidence hashes are verified. Its UART capture matches both
earlier default-hash configurations byte for byte. This is scoped digital
integration, not broad retained-yield or PPA qualification. Earlier N200 startup
archives predate the top hash controls and bucket-zero extension; the boundary check is
not full-chip or routed-netlist equivalence.
The behavioral whole-core RAM-fault matrix passes all 33 checks in
`build/core-bist-faults-v2`, covering every small-core memory class and packed
slice, first/last-engine aggregation, UART failure status, quarantine, healthy
retest and reset. Deliberately masked bank failures and broken quarantine
are detected while healthy controls pass. This is digital fault propagation
evidence, not physical SRAM defect coverage or compiler repair qualification.
Current-source parser induction also passes with startup BIST enabled at N48
and N200, with five reachable CRC/address/length/state fault counterexamples
at each geometry. These checks cover decoded command bytes; serial sampling,
mining behavior and physical CDC/RDC require their own qualification.

The complete Plan H bank-binding synthesis proof now passes all 1,486 EQY
partitions (`build/plan-h-lec-bank-v1/result.json`). Source-manifest,
configuration, synthesis-netlist and recorded proof-artifact hashes match.
This is SKY130 digital synthesis equivalence with SRAMs as matched cut points;
`release_eligible` remains false. Final routed-netlist equivalence and
qualification of the proof flow for packaging are still required.
The startup BIST changes postdate Plan H's source snapshot; this proof does
not qualify the changed current RTL.

The 16-header packed mainnet simulation has completed: 33 solutions over
92,955,773 cycles. Review of all 53 archived inputs, the source tarball and
header hashes passes; all 25 generic RTL files matched the worktree before
the startup BIST changes. Every
output passes the archived Python and Zig verifiers without duplicates, and
per-header counts match the prior untruncated capacity-model corpus. The
original runner has no final `result.json` or completed reference-set audit.
This post hoc validity/count audit is recorded separately in
`production/verification_snapshot.json`; it does not establish a completed
source-bound qualification, population-level yield, power or achievable clock.
A separate provenance-preserving exact-reference audit passes in
`build/par-diverse200-reference-audit-v1`, with exact retention of all 33/33
untruncated reference solutions across all 16 headers. It leaves the
original archive untouched; it does not reconstruct the
original simulation executable's provenance or replay that simulation.
The fresh sixteen-header N200 qualification in
`build/par-diverse200-current-v1` terminated with SIGTERM before its complete
simulation/reference audit. Its result is FAIL and its container is stopped.
The source/configuration/header-bound rerun at
`build/par-diverse200-current-v2` now passes: 33/33 exact untruncated references
across 16 headers in 92,955,773 cycles. All 30 evidence files, 55 archived
sources and the simulation executable were hash-verified. Its frozen source
predates the optional bucket-zero extension and production-top hash controls.

The frozen solver runner now permits paired solver-count, hash-count and
Blake2b split sweeps. Four N48 workflow configurations retain the exact same
complete reference sets, with 42,623/47,085/62,061/56,532 total cycles.
This validates the measurement workflow; it does not characterize mainnet
throughput, achievable clock or energy. N200 sweeps and target-process
extracted PVT timing/power remain required before architecture selection.
The sixty-four-engine, four-header N200 simulation completed at
`build/par-scale64-current-v3`, after SIGTERM interrupted
v1 and v2 reached its fixed 900-second compile timeout. The runner now permits
an explicit compile budget and separate generated C++ files; the latter passes
the complete N48 audit with identical output and cycle count. The v3 compiled
RTL/bench and tool image match the sixteen-engine baseline, and its headers
are the first four baseline headers. Its compile budget is 3,600 seconds.
Independent Python/Zig output comparison against the completed archived baseline
fails: ten versus eleven verified solutions, with one missing on attempt 1
(`build/par-scale64-retention-diagnostic-v1.json`). Candidate and baseline use
7,073,439 and 23,406,212 cycles respectively, but the loss rejects scaling
acceptance. The complete source/executable-bound reference audit now also
records FAIL: 10/11 retained with no reference truncation. Root cause is unproven.
A source-frozen two-header diagnostic at `build/par-scale64-droptrace-v1`
reproduces the affected prefix with capacity-discard tracing. Solver RTL, tool
image and headers match the failed candidate. Trace validation preserves the
healthy N48 output exactly and counts all 1,024 drops in a deliberately
capacity-constrained case, whose lost solution still fails qualification.
The completed mainnet trace matches all 1,774 reported drops, exclusively in
bucket zero. A round-5 row discarded at slot 640 matches a required value/key
of the missing solution; exact parent-subtree identity is not established.
The diagnostic reference audit confirms FAIL (4/5 retained). A four-header uniform 768-slot
experiment at `build/par-scale64-cap768-v1` tests the capacity hypothesis.
Its logical SRAM grows by 27.600896 MB; it is not a selected production remedy.
Its completed four-header simulation now exactly matches all 11 baseline
solutions, independently checked in Python/Zig
(`build/par-scale64-cap768-comparison-v1.json`). It uses 7,218,699 cycles versus
23,406,212 for the paired 16-engine baseline. All 1,623 trace drops reconcile
with the completion counters and are in bucket zero. Its fresh untruncated
reference audit now passes all 11/11, with source/executable/evidence hashes
verified. This is four-header digital evidence; cycle counts do not establish physical PPA.
No scale acceptance, physical throughput or energy claim is established.

An optional `BUCKET0_SLOTS` solver parameter now adds capacity only to bucket
zero, retaining existing slot and pointer widths. The proposed 640/768 geometry
adds 6,896 logical SRAM bytes at 64 engines. Reduced N48 solver/BIST tests pass,
including 44 accepted writes beyond regular capacity and use of the final added
slot. Optimized Yosys RAM depths match the inventory exactly, with only bank
zero growing. Mainnet qualification now passes at
`build/par-scale64-bucket0-768-v1`: exact 11/11 retention over four headers
in 7,218,699 cycles, with source/executable/evidence hashes verified,
broadened to exact 17/17 over eight headers in 13,754,458 cycles at
`build/par-scale64-bucket0-768-nh8-v1` (first four headers byte-identical).
Exhaustive address checking passes all 2,621,568 rows across 64 banks and
eight parent levels (`build/bucket0-mapping-v1/result.json`). This checks
physical address separation, not solver yield or compiler behavior.
The option is forwarded through `zeq200x` and `zeq200_core`, with uniform
capacity still the default. N48 integrated control/BIST passes in
`build/core-control48-bucket0-v1`: two verified solutions, four forwarded
packets, startup/reset BIST and cancellation coverage. Mainnet production-top
integration now passes at `build/core-control200-bucket0-scale64-v1` with
64 solver/hash engines: one independently verified solution, four forwarded
packets, 134,055 backpressure cycles and all required startup/reset/BIST/
cancellation coverage, with solver RTL matching the retention candidate.
Together these form the first complete end-to-end digital candidate for the
640/768 geometry. Separate-table N48 integration also passes in
`build/core-control48-bucket0-separate-v2`; its reference checker uses and binds
the configured bucket-zero capacity, and rejects a mismatched capacity.
This is eight-header digital evidence with single-solution production-top
integration only; broader qualification, synthesis equivalence and physical
compiler mapping remain open, with no production selection or PPA claim.

Plan D routing is stopped by the disk guard, with 2,069 violations at the
last completed optimization iteration. Its source remains release-blocked;
any corrected-source physical qualification needs a new run. The physical
and release-evidence unit suite now passes 67 tests.

The next production decision is whether an actual SRAM mapping and routed
compute/memory/network tile can support the system target. The ordered
decision gates below and `production/workstreams.json` define that work.

Plan H adds downstream command recovery.
Actual-UART tests reproduce swallowed commands on Plan G for oversized lengths
and truncated headers/payloads at all four strap addresses. The corrected parser
validates lengths by command type and abandons an incomplete frame after 32
UART byte budgets without a received byte. A controller must leave that idle
gap after an interrupted frame before issuing another command. Framing bytes
inside valid payloads remain data. Both N48 and N200 pass all 20 command cases;
length-guard and timeout mutants are caught independently. Partial target data
does not change the active target. The exact-wrapper test passes with 32
independently verified solutions and a normal UART capture identical to Plan G.
BIST UART, scoped ownership induction/mutations, and both 20-case upstream
recovery matrices pass. Plan H synthesis passes with 70,778 mapped instances,
19 matching SRAMs and zero unmapped cells/check errors. Standard-cell area is
918,792.4448 um2 excluding SRAM, about 0.44% above Plan G. Frozen-input mainnet
integration passes with one independently verified solution, four forwarded
packets, 124,627 backpressure cycles and all required control/BIST coverage.
All 25 archived generic RTL files match Plan H; they predate startup BIST in
the current source. The
simulation executable, models, verifier and result evidence hashes were audited.
Controller inter-byte-gap compatibility remains to be qualified;
the timeout is a protocol requirement, not a claim about arbitrary host delays.
Evidence is tracked in `production/workstreams.json`.

Extended command qualification now passes 52 cases per geometry, including
missing/bad CRC, exact command lengths, state preservation and received-byte
intervals four clocks below/above the timeout. The length-guard and timeout
mutants are caught in 12 and 20 cases respectively; healthy controls pass.
These tests use the existing Plan H RTL without changing its source snapshot.

Plan G synthesis passed with 70,346 mapped instances, 19 matching SRAM macros,
zero unmapped cells/check errors, and 914,728.5472 um2 standard-cell area
excluding SRAM. Its reproduced command-parser defect now blocks release by
source hash. Its superseded equivalence test and earlier mainnet integration
exercise archived Plan G, not the corrected Plan H.
The Plan G mainnet audit passed with one independently verified solution and
all required control/BIST coverage. Its equivalence run has failing fill-counter
partitions: eight inspected traces assign different values to two aliases of
the same mapped wire. Those traces are not full-netlist executions. A separate
partition diagnostic now proves all 64 bits of the eight affected fill counters.
The reusable alias rule passes 14 unit tests and five mapped qualification cases,
including four deliberate faults. Plan G's superseded proof was stopped; the
earlier current-source Plan H runs subsequently ended FAIL. SMT proved 1,487 of
1,489 partitions, with two SRAM read-enable failures. PDR proved 1,484, with
the same two failures and three hash-word timeouts. Full-chip equivalence
remains unqualified.
The archived Plan G hash-word partition that timed out under PDR now passes
both the base case and temporal induction with Bitwuzla in 189 seconds.
This is a scoped solver diagnostic, not a full-chip equivalence result.
SMT-only and combined PDR/SMT configurations each pass all five mapped
qualification fixtures, including four reachable fault counterexamples.
Seventeen proof-runner and 24 release-packaging unit checks pass. A separate
full Plan H induction run resolved the three PDR hash-word timeouts. The two
remaining traces independently drive the reconstruction bank selector and
entry bucket inconsistently in the leaf-read state. Retaining the selector's
actual driver proves both read-enable outputs together in a focused diagnostic
(`build/plan-h-bank-cut-diagnostic-v1/result.json`). RTL and mapped netlist are
unchanged. The subsequent complete rerun passes at synthesis;
the experimental EQY flow remains ineligible for release packaging.
Explicit driver retention now passes 19 unit checks and five mapped fixtures,
including four reachable fault traces. The complete proof in
`build/plan-h-lec-bank-v1` passes all 1,486 partitions with the reviewed
bank-selector binding. This supersedes the earlier incomplete synthesis
proofs; it does not qualify the final routed netlist or production chip.

A separate frozen-input packed-solver simulation has completed on 16 diverse
mainnet headers (`build/par-diverse200-plan-h-v1`), exactly matching the prior
capacity-model corpus. Its strict reference/independent-verifier workflow passes
a four-header N48 check and catches a deleted solution despite reported bucket
drops. A post hoc audit verifies all 33 mainnet outputs and matching per-header
reference counts. The original runner's final qualification and regenerated
reference-set audit remain absent; power and achievable clock are unmeasured.

Plan H UART qualification also passes at DIV 8 and 16 with every byte value
in back-to-back streams, three asynchronous start phases and bit periods
98%/100%/102% of nominal. It checks 4,628 valid received bytes, 532 transmitted
bytes, 40 reset interruptions, 512 invalid stop frames and six short glitches.
All six bit-order, stop-bit and active-state-reset fault cases are detected.
`build/uart-robustness-v2/result.json` binds the archived RTL, bench, executable
and logs. `./run.sh uart` repeats the qualification with a fresh build name.
Physical clock tolerance, metastability, reset recovery/removal and CDC/RDC
signoff remain open.

Command-parser induction passes on the actual one-lane N48/K5/DIV16 Plan H
RTL for arbitrary decoded bytes, all static strap addresses and repeated
reset. It covers header sequencing/preservation, CRC recurrence, command
authorization and atomic target/thermal updates. Five deliberate faults
(CRC/address/length bypass, skipped header and overwritten address) each yield
a reachable counterexample. Evidence: `build/link-parser-formal-v4/result.json`;
repeat with a fresh `BUILD` using `./run.sh parser_formal`. This is a parser
boundary proof, excluding UART sampling, payload ordering, timeout duration,
mining behavior and physical CDC/RDC.

Plan G previously froze the corrected upstream
frame-recovery RTL. Oversized payload lengths are abandoned and an empty
forwarding FIFO times out after 32 byte budgets. Valid tail pacing is about
four byte budgets. Already forwarded bytes cannot be recalled; a controller
must resynchronize damaged frames with bounded lengths, CRC and an inter-byte
timeout. This is not a guarantee against arbitrary continuous malformed traffic.

Actual-UART tests reproduce starvation on Plan F at every address for oversized
lengths and truncated headers/payloads. The current fix passes 20 cases at
each packet geometry, including prompt invalid-length rejection, slow valid
forwarding and byte-exact maximum-length solution packets. Removing either
guard is independently detected by fault-injected copies of the RTL. BIST UART and scoped ownership induction
plus fault counterexamples pass. Plan G exact-wrapper and all four
sustained-traffic cases pass. Its 32 verified solutions and normal-traffic
byte capture match Plan F. These results predate the command-parser fix.

Verification preparation now freezes the digital-core RTL, bench, Python
models and independent Zig verifier throughout compilation and checking.
`./run.sh core_control` uses this runner; its seven archive/failure tests pass.
The final qualification verdict is separate from the checker's own verdict
and requires unchanged input and executable hashes. Python environment
settings cannot disable model assertions; host Python/NumPy versions are
recorded. These controls improve evidence integrity, not physical coverage.
The N48 frozen-input integration passes with two verified solutions and four
forwarded packets under an optimization-enabled caller environment; a damaged
coverage capture is correctly rejected by the protected checker.
The resource-controlled EQY runner passes all five mapped fixtures, including
four validated fault counterexamples, with one worker and 600 seconds per
strategy. Every partition remains required, and the engine remains
ineligible for release packaging pending full-chip qualification.

Archived Plan F mainnet integration passes with one independently verified
solution, four forwarded packets and required control/BIST coverage. Its
one-second transport checks pass at both clock settings (the offset case
required replay after a wall timeout). Synthesis passes with 70,188 instances
and 19 matching SRAM macros. These results predate frame recovery. Plans
C/D/E/F/G have reproduced functional defects and are rejected by the source-hash
release registry. Plan D routing stopped at the disk guard;
logs and restart provenance are in `build/plan-d-resume-flow.log` and
`build/plan-d-resume.json`.

The revised equivalence runner normalizes bit names and groups aliases across
both designs. Twelve unit checks and five mapped-circuit checks pass. Plan D
partition preparation produces 1,506 partitions, with the largest mapped
partition reduced from about 173,000 to 17,793 cells. Plan F's full-chip run
terminated after 28 partitions passed; preprocessing timeouts/errors left the
rest unproven. No full-chip equivalence or production release is qualified.

The installed 2 KiB SRAM has only TT/1.8 V/25 C Liberty. Reusing it for
SS/1.6 V/100 C or FF/1.95 V/-40 C analysis does not establish macro corner
closure. `pd/check_macro_timing.py` now gates this explicitly, checking actual
Liberty voltage/temperature, reviewed per-corner process/library hashes, and
matching resolved/final-STA macro views. `macro_timing_views` in the release
policy is empty until qualified views are available and reviewed; changing
corner labels or copying the same TT view is insufficient. This limitation
also applies to later snapshots. The gate's diagnostic on checkpoint 40 is recorded
in `build/plan-d-macro-timing-block.json`.

SRAM interface screening (`build/sram-slew-screen-v3/result.json`) measures
192 combinations of 12 buffers, four input slews and four lumped wire loads
using the exact TT libraries selected by Plan H. All measured SRAM address
loads are 6.89 fF. Eleven combinations meet the 40 ps address-input limit;
all have zero added wire capacitance. The best result is 34.435 ps with
`buf_12` and a 10 ps input slew. At just 5 fF added capacitance, the best
result is 41.530 ps and every tested buffer fails. These are ideal-wire
timing-library estimates, not routed or SPICE-characterized results.
Seven evidence-parser tests reject incomplete sweeps, tool diagnostics,
incorrect loads and inconsistent measurements.

The archived Plan D checkpoint-40 report has 949 slew, 1,208 fanout and
three capacitance violations. All 342 SRAM address pins violate slew;
344 SRAM input pins violate in total. The report and configuration hashes
are bound in `build/sram-slew-screen-v3/historical-analysis.json`.
This is evidence from the blocked historical source, not Plan H routing.
The next physical experiment must measure extracted RC with local address
drivers placed close to macro pins. If that cannot meet the existing limits,
new characterization must establish a supported operating range. Raising a
Liberty limit or reducing clock frequency alone does not establish slew closure.


There are three configurations:

- **ZEQ-200-TC**, a test chip on SKY130: the whole design, one lane,
  Equihash (48,5), every table on die. It's small enough for an open-PDK
  shuttle (Caravel-style 2.92 × 3.52 mm user area) and exercises every
  block, including the chain protocol and the real board pins.
- **ZEQ-200M**, the mainnet compute die (200,9): the same RTL with its
  tables on external DRAM ports. It needs an advanced node plus DRAM
  controller/PHY IP that no open PDK has. See
  [README.md](README.md#competitiveness) for why a *competitive* mainnet
  part needs on-die SRAM instead.
- **ZEQ-200X**, the primary production candidate: mainnet (200,9) with
  on-die SRAM and bucket-parallel engines. The intended process and compiler
  are not provisioned; target-process mapping, routed PPA and production
  signoff remain open.

Status legend: ✅ done here · 🟡 done with caveats · ❌ not done (needs
external IP/PDK access, lab work, or funding).

## Production scope — September 29, 2026

The primary target is now competitive mainnet silicon. The SKY130 run is
a separate demonstrator and cannot qualify the production chip. The
production top is `rtl/zeq200x.v`; PDK/IP access and physical implementation
remain outstanding. The corrected RTL memory budget and implemented
compact-row option are documented in `README.md` under Production target.

The packaging gate now requires post-route STA reports and finite,
nonnegative setup/hold slack at every corner listed by the final STA
step. The gate also requires each corner's `ws.max.rpt` and `ws.min.rpt`
to report finite, nonnegative worst slack matching the final metrics;
inherited positive metrics cannot hide a failing or missing timing report.
Missing or partial reports fail (`pd/check_sta_evidence.py`), tested
with missing-report, truncated-report and invalid-slack cases. This is one
additional evidence check, not a complete production signoff flow.

## Ordered production decision gates — October 2, 2026

These gates order the engineering decisions; they do not grant release
authorization. Verification and preparation can proceed while process/IP
access is pending. Production architecture selection depends on measured
physical results, not the SKY130 demonstrator.

| Gate | Next work | Evidence needed to advance |
|---|---|---|
| 1. Reconcile digital evidence | Complete a source-bound mainnet reference-set qualification; retain synthesis proof scope and known failures | Immutable input/executable/log hashes, independently verified outputs, complete reference retention on the selected corpus, and explicit limitations |
| 2. Establish process/SRAM feasibility | Obtain licensed PDK, compiler views, supported shapes, repair interfaces and supplier quotes | Verified port/collision behavior; mapping with macro padding, periphery, redundancy, area, PVT timing, access energy and leakage |
| 3. Characterize routed tiles | Compare packed/separate memories and flat/staged transport; sweep engine/hash parallelism and voltage/frequency | Extracted PVT timing, workload power, physical area, clock/buffer/wire costs and a defensible full-die estimate |
| 4. Select the machine architecture | Expand paired mainnet corpora and integrated network scale; choose die count from routed throughput and power | Credible 1 MSol/s at <=2 kW wall including operating margin, package/board/cooling/conversion losses, and quoted cost per delivered kSol/s |
| 5. Complete production integration/test | Integrate compiler repair and persistent loading, startup qualification, scan/ATPG, clock/sensor/pads, CDC/RDC and controller recovery | Verified manufacturing modes, agreed test coverage, package/power/thermal feasibility and multiple-chain work assignment without duplicate work |
| 6. Sign off and release | Qualify the proof flow and exact final implementation | Final-netlist equivalence, post-route simulation, required PVT/RC timing/electrical checks, foundry DRC/LVS/antenna/density, dynamic EM/IR, package/thermal signoff and submission acceptance |

Packing leaves 140.85–141.25 MB of logical SRAM across 16–512 engines;
reducing engine count barely reduces storage. At 512 engines there are
9,216 logical memories before compiler tiling. The historical 8,400 Sol/s
per-die projection implies about 120 dies for 1 MSol/s and roughly 16.7 W
of wall allowance per die before system overhead. These are feasibility
checks, not a validated die-count or power budget. Actual compiler mapping
and routed throughput must decide the architecture.

The SKY130 signoff gate now also requires matching electrical report and
metric counts for slew/cap/fanout, the exact corner set in the release
policy, and static IR drop within an explicit budget. Its initial 90 mV
ceiling is 5% of nominal 1.8 V; it is only a static screening limit, not
production EM/IR qualification. Forty-nine signoff/release regressions pass, and the
historical Blake2b layout is correctly rejected. Precheck outputs are
retained in timestamped directories and only the full success verdict is
accepted. Full-chip equivalence, production test and dynamic EM/IR remain
separate required gates.

## Source-bound release preparation

Packaging and chip equivalence now require the selected run's archived
source manifest. They verify every archived file, source order and timing
constraint against that run's `resolved.json`; neither reads the live
default `wrapper/config.json`. Equivalence snapshots its RTL, gate netlist,
standard-cell library and SRAM black-box model, records the tool version,
and binds the verdict and proof files by hash. A synthesis-netlist proof
cannot qualify a different final routed netlist.

`pd/release_bundle.py` requires physical signoff and matching final-netlist
equivalence before staging any output. It includes all policy-required
SDF corners and SPEF RC views, both archived wrapper files, chip RTL, final
layout views and the source/signoff/LEC evidence. This fixes the previous
packager's live-config selection and SPEF directory-pattern mismatch.
Each staged file is hashed; an incomplete installation leaves a marker
that blocks precheck. Precheck records the bundle-manifest and log hashes
and requires the installed files to remain unchanged.

From `asic/chip`, after physical closure on a **new corrected run**. Replace
`qualified` below with its actual run/archive name; Plans C and D are blocked:

```sh
RUN=pd/wrapper/runs/qualified SOURCE_MANIFEST=build/qualified-source/manifest.json \
  ./formal/cec/chip.sh \
  pd/wrapper/runs/qualified/final/nl/user_project_wrapper.nl.v build/qualified-lec-final

# The packaging/precheck scripts resolve these paths after changing to pd/.
RUN=wrapper/runs/qualified SOURCE_MANIFEST=../build/qualified-source/manifest.json \
  LEC_DIR=../build/qualified-lec-final BUNDLE=../build/qualified-release \
  ./pd/tapeout.sh
```

Use fresh proof and bundle directories. The current Plan D run still fails
release preflight because its source has a reproduced functional defect
and final physical reports are absent; the original negative
check creates no bundle (`build/plan-d-release-block.json`). The runner's
mapped-circuit smoke test passes, and an XOR-to-XNOR mutation produces a
counterexample (`build/lec-runner-smoke/`). Plan D synthesis equivalence
timed out after 1200 seconds in `build/plan-d-lec-synthesis`; this is
unproven, not an established mismatch. The experimental partitioned EQY
runner passes its mapped-circuit qualification and three validated mutant
counterexamples. Full-chip synthesis verification in
`zeq-plan-d-lec-eqy-v1` timed out after 3600 seconds; no full-chip proof was
obtained. The engine remains blocked from release packaging
pending full-chip and release-flow qualification.
No fabrication submission occurs in these scripts.

To freeze a new corrected wrapper revision and qualify its actual top:

```sh
python3 pd/snapshot_wrapper.py review   # fresh tag; never overwrite an archive
python3 tb/qualify_wrapper.py --source-manifest build/plan-review-source/manifest.json \
  --build build/plan-review-wrapper-chain
```

The snapshot includes RTL, wrapper/constraints and verification sources.
The regression uses its archived Verilog list, pins the simulator image ID,
copies/hashes the Python and Zig checkers, and rechecks source hashes after
simulation. The SRAM model is digital, and the test does not qualify timing
or analog behavior. Plan E's completed attempts retained 346/380 model
solutions, and its saturated chain is unfair (4/97/156/222 completed job-2
attempts by address). Neither full solution yield nor bounded chain latency
is established by the PASS. A fresh source-bound physical run and complete
signoff are still required.

The paced revision requires addresses 0/1/2/3 in order from controller to
tail. Its static aggregate quotas are full, 3/4, 1/2 and 1/4 line capacity,
including forwarding. A lone tail chip retains its quota even if other chips
are idle; adaptive allocation is not implemented. Bit rate and packet bytes
are unchanged. The current stress evidence is finite and does not qualify
arbitrary oscillator offsets, analog sampling, reset disturbances during
saturation, or all mixtures of packet sizes. The earlier equal-clock TLA+
model does not include this pacing or the reproduced drift failure.

`production/blocked_sources.json` identifies exact known-defective RTL
hashes. Packaging checks that registry independently of run-directory
markers, requires the registry to be present and valid, and includes its
checked contents in release evidence. Copying/renaming an old run cannot
qualify its known-defective source. A source hash absent from the registry
still needs all verification and physical gates.

The new memory-repair adapter passes simulation and scoped formal checks
at three geometries, including first-failure diagnostics and invalidating
BIST qualification after a repair change. It is not yet integrated into
the production top, persistent repair loading or compiler macros. See
`formal/README.md` for reproducible runs and proof limits. Chip-wide
scan/ATPG, macro-specific repair and manufacturing tests remain required.

## Earlier runs — September 29, 2026

The full chip is **not signed off**. Plan B (`pd/wrapper/runs/b`) reached
31,556 global-routing overflow and still had 16,797 DRC violations after
15 detailed-routing optimization iterations. Its last routing log entry
is September 29 at 07:54 PDT; no flow container remained at inspection.
The cause of termination is unknown. There is no final signoff or precheck
result for this run. The earlier overnight completion estimate is obsolete.

Plan C (`pd/wrapper/runs/c`, container `zeq-plan-c`) started September 29
at 15:59 PDT. It reached step 27 (mid-PnR STA) and was stopped by
the disk guard after available space fell below 5 GiB. The container is
confirmed exited; resume requires adequate free space and the last valid
checkpoint, not a fresh run. It uses the same floorplan and disables
the per-lane SHA256 share filter only in `zeq200_tc` (`SHARE_FILTER=0`).
The core and generic pad-ring defaults retain filtering. The test chip
accepts SET_TARGET commands but forwards all solutions; the host must apply
the pool target. No routing improvement or cell-count reduction has yet
been measured for C.

Validation of this change:

- Lint and Yosys structural checks passed.
- SKY130 board simulation with bypass: 30/30 solutions pass the Zig
  verifier, all 23 model solutions on completed attempts delivered, and
  seven below-target solutions forwarded. DONE counts checked against
  delivered solutions on completed attempts.
- Filter-enabled SKY130 regression: 20/20 solutions verified, all 17 model
  shares on completed attempts delivered, target filtering exercised.
- The board capture drain window was extended to cover the queued traffic
  across all four chips; a partial final packet now fails explicitly.

Run logs: `build/plan-c-flow.log`, `build/plan-c-chain.log`,
`build/plan-c-filter-regression.log`, and `build/plan-c-lint.log`.
Source snapshot: `build/plan-c-source/`. The flow uses eight cores and
`pd/guard_flow.py` stops it if free disk falls below 5 GiB, leaving previous
runs intact. Completion status is written to `build/plan-c-flow.exit`.

After successful routing, remaining work includes final DRC/LVS/antenna/XOR,
STA and IR-drop review, full-chip final-netlist equivalence, final-netlist
board verification, and `RUN=wrapper/runs/c ./pd/tapeout.sh` for the package
and Caravel precheck. Neither precheck nor equivalence is auto-started by
the current flow supervisor.

## SKY130 demonstrator gates

These gates apply to the historical shuttle demonstrator. They do not qualify
the current production top. A passing block test or behavioral BIST test
does not close any corresponding production gate.

| Gate | Status |
|---|---|
| Full chip routes with 0 DRC (Magic + KLayout), LVS clean, 0 antenna, 0 XOR | ❌ Corrected Plan H has synthesis only; historical Plan D stopped with 2,069 routing violations and blocked source |
| STA signed off at tt/ss/ff, 40 MHz: setup, hold, max slew/cap/fanout all clean | ❌ Plan D checkpoint 40 nominal setup +5.40 ns and hold +0.082 ns, but 949 slew and 3 capacitance violations; final corner-complete reports pending |
| IR drop within budget | ⬜ after routing |
| Caravel `mpw_precheck` passes | 🟡 tooling installed (precheck repo, image, caravel-lite); needs the GDS |
| Equivalence: RTL ≡ final netlist | 🟡 Blake2b block routed proof and Plan H 1,486-partition synthesis proof pass; full-chip final routed-netlist proof and release-flow qualification remain open |
| Gate-level board test | ✅ synthesized netlist: 21/21 shares verified. Final routed netlist: after routing |
| DFT | 🟡 behavioral memory BIST verified; block scan verified. Chip-wide scan/ATPG, physical fault coverage and manufacturing patterns remain open |

## Signoff waivers

The entries below are historical proposals, **not active approvals**.
`pd/wrapper/signoff_policy.json` currently grants no waivers. The release
gate checks slew, capacitance and fanout at every policy corner. Any future
exception must identify the exact pin/check/corner, a numerical bound,
the SHA256 of the reviewed report, and a justification file. SRAM instance
names no longer exempt violations automatically. Macro behavior outside
its characterized conditions requires characterization evidence.

| Check | Count | Reason |
|---|---|---|
| Max transition on SRAM macro inputs | Historical proposal: ~324 pins; checkpoint 40 has 344, including all 342 address pins | The installed Liberty sets an explicit 0.04 ns limit on `addr0`, `addr1` and `wmask0` buses, with a 0.5 ns library default. Its cell/constraint transition tables stop at 0.04 ns. The explicit limit is not present on every input. Timing outside characterized ranges requires supporting characterization, even if reported slack is positive. |
| Max fanout on clock-tree leaf buffers | ~1,500 nets, 20 vs 10 | The generic `MAX_FANOUT_CONSTRAINT` also applies to CTS leaves. Their slew and capacitance meet limits, which is what fanout stands in for; skew is from the balanced tree. |
| Max capacitance on SRAM `dout1` pins | 2 | The macro's output pin limit (0.028 pF) is exceeded by about 0.009 pF; the downstream slew and timing close. |

## Front end

The results below describe scoped digital and demonstrator checks. They are
not current-source, production-scale signoff unless explicitly identified as
such above; archived Plan H checks predate the startup-BIST changes.

| Item | Status | Evidence |
|---|---|---|
| Synthesizable RTL, no latches, single clock per chip | ✅ | `./run.sh synth`, Yosys `check -assert` in `./run.sh lint` |
| Lint clean (Verilator `-Wall`, both tops) | ✅ | `./run.sh lint` |
| No multiply-driven nets | ✅ | Yosys `check -assert` (it caught a real one: a loop variable shared across processes) |
| Reset: asynchronous assert, synchronous release; reset re-driven down the chain | ✅ | `rtl/zeq200_core.v` |
| CDC: every chip-boundary input (CI, RI, BI) through 2-FF synchronizers; ADDR straps static | 🟡 structural implementation | `rtl/zeq_uart.v`, `rtl/zeq_link.v`; CDC/RDC constraints, physical synchronizer implementation and signoff remain open |
| Functional verification against an independent reference | ✅ | bit-exact vs `model/`, every solution checked by a port of zcashd's verifier *and* the Zig consensus verifier (`zcash-miner --verify`) |
| Mainnet (200,9) verified in RTL | ✅ | `build/mainnet_solver3_*`: solutions match the model and pass `zcash-miner --verify --params 200,9` |
| Board-level test in the exact tapeout configuration | ✅ | `./run.sh chain_sky130`: 4 chips, separate clocks, SRAM-macro models, JOB/STOP/PING/SET_OT, busy chain, over-temp |
| Latency and backpressure robustness | ✅ | `solver2`/`solver3` pass with random stalls and 1–20 cycle memory latency |
| Regression in one command | ✅ | `./run.sh all` (~10 min, includes TLA+ and Lean); `./run.sh signoff` (scan, LEC, gate-level) |
| Formal proofs | ✅ | [formal/README.md](formal/README.md). Lean 4: soundness of the solution construction, canonical order, bucketing, FIFO sizing at the real parameters. TLA+: chain protocol, crossbar round, job tags, plus 3 mutants that must fail (one found a real RTL bug). Yosys SAT: arbiter fairness by induction, UART, FIFO. `./run.sh tla lean formal` |
| Code coverage | ❌ | Not measured. Verilator `--coverage` would give line and toggle numbers. |
| Gate-level simulation (post-synthesis, zero delay) | ✅ | `./run.sh chain_gl`: the 4-chip board test on the Yosys netlist of the test-chip core (bucket-parallel solver, 18 SRAM macro instances, share filter), on the current RTL: 21 shares from 4 chips, same as the RTL run; 21/21 pass the Zig verifier; all 18 model shares on finished attempts found |
| Equivalence (LEC) | ✅ block / 🟡 chip | Blake2b, sequential equivalence with ABC `dprove` (`formal/cec/cec.sh`, `./run.sh lec`): **RTL ≡ signed-off routed netlist**, synthesis ≡ routed, and synthesis ≡ scan-inserted with scan off. A scan-mode mutant gives a counterexample. Full chip: same script once `pd/tc` signs off. |
| Gate-level simulation with SDF (post-route timing) | ❌ | Needs the signed-off full-chip netlist and SDF |

## Back end (SKY130, LibreLane 3.0.14)

| Item | Status | Evidence |
|---|---|---|
| Standard-cell flow runs end to end | ✅ | `pd/blake2b/`: synthesis → floorplan → placement → CTS → routing → signoff |
| Timing closure on the critical block | 🟡 | Blake2b G-function split into quarter steps (`SPLIT=4`) to fit a 130 nm cycle; see [results](#results) |
| SRAM macros | ✅ | `rtl/tech/sky130/zeq_sram_port.v` tiles OpenRAM `sky130_sram_2kbyte_1rw1r_32x512_8`; byte-identical board simulation with macro models |
| Full-chip floorplan with 18 macros in the shuttle user area | 🟡 | `pd/tc/config.json`; see [results](#results) |
| DRC / LVS / antenna clean GDS | 🟡 | See [results](#results) |
| Multi-corner STA (ss/tt/ff) | 🟡 | LibreLane signoff corners; see [results](#results) |
| IR drop / EM signoff | 🟡 | Blake2b block: worst static IR drop 1.2 mV (OpenROAD PSM). No EM analysis, and no full-chip IR yet. |
| Harness integration | 🟡 | `../zeq200_caravel` (a caravel_user_project checkout): `user_project_wrapper` instantiates `zeq_caravel_wrapper` (`rtl/`), every pad has a GPIO power-up mode, and the Wishbone port is tied off. `pd/wrapper` hardens the wrapper **flat** (SRAM macros + cells directly in the wrapper, Caravel core ring and fixed pin template). A nested macro can't work here: its grid must stay on met4, where the SRAM power pins are. `pd/package_caravel.sh` collects the views. Remaining: finish the flow, `make precheck`. |
| Memory BIST | ✅ digital tests / 🟡 manufacturing qualification | March C− on every table (`rtl/zeq_mbist.v`), BIST command and production startup, result in PONG. Digital fault tests pass; compiler-specific fault coverage, repair and manufacturing patterns remain open |
| Scan | 🟡 | `pd/scan_insert.py`: full scan on the Blake2b block (2125 flops, 100% of them). Shift and capture simulated (`./run.sh scan`); scan-off equivalence proved (`./run.sh lec`). Not yet in the full-chip flow, and no ATPG patterns (needs Fault or a commercial tool). |
| Analog: PLL, thermal sensor | 🟡 | The shuttle version needs neither: `user_clock2` clocks the chip and the management core supplies the sensor code on `la_data_in[7:0]`. A production part needs PLL and sensor IP (behavioral stubs in `rtl/zeq200.v`). |

## What a fabrication submission still needs

1. Finish `pd/wrapper` (the flat harness layout), package it
   (`pd/package_caravel.sh`), run `make precheck` in `../zeq200_caravel`.
2. Close the SS corner (see [results](#results)): 40 MHz nominal, or
   retime the Blake2b quarter-step.
3. Fix max-slew and max-fanout violations (high-fanout message and state
   nets in the Blake2b block).
4. Scan in the full-chip flow, plus ATPG patterns.
5. Gate-level simulation with SDF on the signed-off netlist.
6. For ZEQ-200X / ZEQ-200M: an advanced-node PDK, large SRAM compilers
   (or DRAM PHY), PLL and sensor IP, and a package. None of that is open,
   and all of it costs money.

## Results

### Blake2b block (`pd/blake2b`, SPLIT = 4, 20 ns target)

| Check | Result |
|---|---|
| Cells | 34,995 std cells (2,125 flops), 0.48 mm² core, 63% utilization |
| DRC (Magic, KLayout) | **0 / 0** |
| LVS | **clean** (0 device, net, pin differences) |
| Antenna | **0** violations (181 diodes) |
| XOR (Magic vs KLayout GDS) | **0** differences |
| Setup, tt 25 °C 1.8 V | +5.07 ns at 50 MHz |
| Setup, ff −40 °C 1.95 V | +8.78 ns |
| Setup, ss 100 °C 1.6 V | **−5.57 ns** at 50 MHz → closes at ~39 MHz (25.6 ns) |
| Hold, all corners | +0.08 ns, 0 violations |
| IR drop (static) | 1.2 mV worst |
| Power | 75 mW (tt, 50 MHz, default activity) |
| Max slew / fanout | 488 slew (tt), 12 fanout violations: **open** |
| Equivalence | **RTL ≡ routed, synthesis ≡ routed, scan-off ≡ original: all proved** (ABC `dprove`, unbounded) |

The current test-chip target is 25 ns (40 MHz). The older block's SS
result implies at least 25.57 ns (about 39.1 MHz), so that result does not
establish timing closure at 40 MHz. The slew violations are all on fanout trees that timing repair built
from `clkdlybuf4s25_1`, a weak delay cell (e.g. the phase counter bit
`ph[0]` that selects the G-step operands). `pd/blake2b` and `pd/wrapper` now
exclude `clkdlybuf4s*` (`EXTRA_EXCLUDED_CELLS`) and constrain transitions
to 0.75 ns; the numbers above are from the run before that change.

### Test chip (`pd/tc`, 2.92 × 3.52 mm, 18 SRAM macros, 25 ns)

Full flow run through detailed routing on the pre-merge RTL. Not signed off; it's the layout study behind `pd/wrapper`.

| Stage | Result |
|---|---|
| Synthesis | 153k cells, 37.6k flip-flops |
| Floorplan | 18 SRAM macros = 50% of the 10.2 mm² core; standard cells 56% of the rest (78% overall) |
| After CTS + repair | 297k cells: **38.5k hold delay cells** and 15.3k weak `clkdlybuf4s25_1` fanout buffers; 4,525 clock nets, 9 levels |
| Timing before routing (tt/ss/ff) | setup +7.7 ns, hold +0.2 ns at 40 MHz |
| Global routing | overflow never cleared; OpenROAD relaxed the 2×-spacing clock rules one net per pass for hours |
| Detailed routing | **325k violations** at 90% of the first pass: **not routable as floorplanned** |

### Harness layout (`pd/wrapper`, flat user_project_wrapper): what the congestion taught

| Attempt | Global-route overflow | Finding |
|---|---|---|
| 3 × 6 SRAM block, 50 µm row gaps, 2 hash units | 93k (met2 69k) | SRAM signal pins sit on the top and bottom edges (both ports in use), so every row gap held two pin edges |
| same, placement spread (density 42%, padding) | 115k | spreading only lengthened wires |
| 5 SRAM rows spanning the die, 240 µm channels | 187k (met2 171k) | each row blocked vertical routing across the die |
| **3 × 6 block, 180 µm row gaps, one shared hash unit (B)** | 31,556 | Detailed routing still had 16,797 violations after iteration 15; stopped without signoff |
| Same floorplan, share filter bypassed on test chip (C) | not qualified | Stopped and release-blocked for archived UART forwarding defect |
| Archived C sources with verified UART correction (D) | stopped, 2,069 violations | Resumed September 30 from checkpoint 40, then stopped at the disk guard; source blocked and no final signoff |

A net-by-net count of the routing guides settled it: 88% of met2 use was
short local wiring, and only 908 of 137k nets crossed an SRAM row. That's
a logic-density limit, not a placement problem. The two Blake2b units were
39% of all cells. A test chip needs one: at (48,5) an attempt takes about
52 compressions, and leaf rows reach their bank through the crossbar
whichever engine hashed them. `zeq_eh_par` gained `HPB` (log2 hash units;
the test chip uses 0, mining configs keep one per engine). With the
key/value merge that brings synthesis from 153k to 96k cells and from
37.6k to 24.0k flops.

What changed for the harness layout (`pd/wrapper`, the full 2.92 × 3.52 mm user area, hardened flat):

1. **RTL**: each engine's local keys now ride in the spare bits of the value
   macros (`m_val*` is `{key, value}`, 53 of 64 bits), which removes
   2 × 2,560 flip-flops per engine (~10k flops and their hold cells).
2. `clkdlybuf4s*` excluded from repair; max transition 0.75 ns.
3. Clock NDR at the root only; hold margins 0.05 / 0.02 ns (instead of
   0.1 / 0.05).
4. Global routing allowed to finish with residual overflow for detailed
   routing to clear, with 10% more track capacity (`GRT_ADJUSTMENT` 0.2)
   and short relaxation passes.

The subsequent early-compaction experiment, `build/equiv-queue-compact-pdr-20261012`,
reduced the serialized model by 44.6% while preserving all 6,000 assertions
and 11,464 assumptions by cell type and identity. It still timed out during
preparation at 600 seconds with an unchanged 8 GiB cap; PDR search never started.
Positive, duplicate-assertion, and injected-fault controls pass, as do seven
preparation tests. These checks do not close the remaining obligation.
