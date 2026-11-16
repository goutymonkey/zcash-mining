# Public launch deliverables

This is the implementation ledger for the requested one-month preparation
plan. A deliverable is complete only when its evidence is recorded here.
Publication, fabricated silicon, and production physical signoff are separate
decisions; this work does not change GitHub visibility.

| Deliverable | Acceptance evidence | State |
| --- | --- | --- |
| ZIP 301 protocol | Independent message/header/share vectors, malformed-input tests | Implemented and tested |
| Account-based live pool validation | Live pool handshake, authorization and job capture with a user-supplied worker | Deferred by user until a pool account is available |
| Mainnet share acceptance | Independent low-difficulty server verifies a real (200,9) solution and block target | PASS: source-bound 90-second run, 5 accepted shares; frozen vectors in tests/fixtures |
| Reliable host | Authorization, every job update, job-bound targets, disjoint nonces, reconnect/backoff, timeouts, cancellation, bounded buffers and memory | Implemented; integration tests and two-minute fault pilot pass; long soak remains separate |
| Share accounting | Correlated accepted/rejected/stale/unknown replies, latency, throughput, worker health | Implemented and tested |
| Long-run qualification | Actual 24-hour fault-injection soak with source hash, events, resource measurements, and verdict | Stale/unverified as of 2026-11-16: no public result recorded. Frozen two-worker CPU build started 2026-10-29 18:37 UTC. |
| Solution yield | Stream all valid distinct solutions; differential solution-set checks and measured first/all comparison | Implemented; 32 complete small oracle comparisons and mainnet first/all pilot pass |
| Benchmarks | Fixed mainnet corpus, verified solutions/sec, per-nonce timing, peak RAM, cancellation latency, machine/tool metadata | CLI and paired runner complete; two-input mainnet pilot passes; 16-input paired run in progress; redistribution pending |
| Backend interface | CPU and actual RTL simulator share job/cancel/result/status interface; serial chip transport | Implemented; CPU, actual RTL and serial pseudo-terminal tests pass; physical serial qualification remains open |
| End-to-end hardware host | Pool job through RTL to independently verified share; stale output, fault rejection and backpressure checks | Mainnet UART smoke and local pool acceptance pass; small-parameter four-chip fault run and mainnet-sized four-link saturation with clock skew pass |
| Hardware reproduction | Redistributable corpus/results/manifests, pinned tools, documented fresh-clone commands | Pinned immutable RTL build and source-bound qualification scripts implemented; evidence packaging pending |
| Hardware CI | RTL lint and short simulation; separate longer mainnet qualification workflow | PASS on fresh clone at 249db01; manual longer mainnet job available |
| Hardware qualification | Broaden overflow/reset/cancellation/transport corpus; attempt remaining equivalence obligation, report exact scope | Small-parameter core reset/cancel/BIST and four-link transport stress pass; 32-header mainnet RTL and mainnet core-control runs ongoing; overflow controls and formal attempt pending |
| Release artifacts | Linux binaries, checksums, licenses, reproducible packaging, fresh-machine onboarding trial | Native x86-64 and ARM64 candidates PASS in CI: identical independent builds and fresh-install tests; combined release set verification and distribution pending |
| Documentation | Current CLI, protocol/backend contracts, configuration, troubleshooting, evidence and measured limits | Mining, backend, installation and release guides updated; final benchmark results and evidence bundles pending |

## Conditional physical milestone

A routed representative memory/compute tile with extracted timing, area,
and workload power requires suitable licensed process and SRAM views. Access
was previously recorded as unavailable. Recheck availability before attempting
this milestone; generic synthesis and an unrelated process demonstration do
not establish production physical performance.

## Evidence log

- Initial inspection: existing Stratum used Bitcoin-style subscribe/notify
  layouts and incorrect Zcash share encoding. Existing CI does not establish
  live-pool interoperability. Reference: <https://zips.z.cash/zip-0301>.
- Implementation started from a clean worktree at `a14b4b8`.
- User requested waiting on account-based live-pool testing because no pool
  account exists yet. Continue all local and independent acceptance work;
  do not represent synthetic fixtures as captured pool traffic.
- Foundation evidence: [mining-foundation.json](evidence/mining-foundation.json).
  Thirty Zig tests and 322 Python tests pass. Mainnet acceptance and a two-minute
  fault pilot pass with frozen binaries, source/verifier copies, resource logs
  and manifests under the ignored `private/launch/` directory. Those local
  directories are not distributed artifacts; packaging them remains open.
- `tests/fixtures/mainnet-shares.json` contains five generated mainnet-parameter
  vectors, with verifier/source provenance. Mutation controls reject changed
  commitment bytes in both the Python and Zig verifiers.
- Earlier acceptance runs v2/v3 are retained as FAIL: unrelated HTTP port
  probes were counted as mining-protocol failures. The harness now records
  pre-session HTTP probes separately and tests that HTTP inside a mining
  session still fails. The first fault pilot also has a source-binding audit
  failure; qualification now rebuilds and checks sources before snapshotting.
- Mainnet benchmark pilot: two SHAKE-derived inputs, two repeats per mode,
  first mode 4 solutions / 97.24 seconds; all mode 6 / 107.15 seconds. The
  measured ratio is 1.36 on this small, non-isolated workload. Broaden the
  corpus before a general speed claim.
- Device backend evidence: [device-backends.json](evidence/device-backends.json).
  Thirty-four Zig tests and 24 Python mining integration tests pass. The
  four-chip `(48,5)` smoke test matches complete independent solution sets
  (3, 1, 0 and 7 solutions). A 45-second actual RTL fault run accepted 20
  shares, rejected 5 and reconnected twice, with no worker failure and clean
  simulator exit. These are digital checks, not silicon performance results.
- Fault tests exposed delayed PONG replies after cancelled discovery; the
  driver now handles valid late status idempotently. The first chain fault
  run did not qualify clean shutdown because SIGTERM could interrupt cleanup;
  its separate audit records that limitation. The repeated v2 run requires
  and passes explicit bridge-exit checks.
- Mainnet `(200,9)` UART smoke passes: chip discovery, one complete nonce,
  the recorded CPU solution set and independent Python verification agree.
  A separate 300-second local pool-to-RTL run also passes: one independently
  verified share accepted, no worker failure, clean bridge shutdown. This
  verifies the digital mining path; it does not measure ASIC performance.
- Mainnet UART build v1 failed its live-source audit while bridge code was
  being edited. It is retained as FAIL. The build now compiles a read-only
  snapshot and checks those exact frozen inputs; the v2 mainnet build passes.
- Fresh-clone [software CI](https://github.com/goutymonkey/zcash-mining/actions/runs/40933042934)
  and [hardware CI](https://github.com/goutymonkey/zcash-mining/actions/runs/40933042943)
  pass for backend commit `249db0121312fc43518291ff34a95b915d39333c`.
- Portable candidate [evidence](evidence/portable-candidates.json) binds the
  x86-64 candidate at `69dc184e0f32cef07fc52c490299e7cc277966ee`. Two different
  source-archive extractions produce identical stripped static ELF binaries.
  Tests run against the executable extracted from the installation archive.
  This is an engineering candidate using the current 0.5.0 version string;
  it has not replaced a tagged release or closed the long-run qualification.
- Both native targets pass [portable CI](https://github.com/goutymonkey/zcash-mining/actions/runs/40936720552)
  at `b359d5917fee1820c9c2249e348a4be231697860`. Downloaded archive and
  validation-log hashes match their reports. The x86-64 executable also
  matches the independently built local candidate. The first CI run exposed
  target-specific rebuild metadata inside identically named source archives;
  the packager now records both targets, and a combined CI job must verify
  one shared source archive before producing the release set.
- [Hardware stress evidence](evidence/hardware-stress.json) records a
  four-link saturation PASS with mainnet-sized synthetic payloads, equal
  clocks and up to 0.6% clock-period skew. Each case supplies traffic for
  500 ms of simulated time, then drains the queues. This tests transport,
  not Equihash throughput or physical timing. Small-parameter core control
  separately passes reset, cancellation, memory self-test and backpressure
  checks. Its three mainnet-only control coverage points remain untested
  by that run and are explicitly listed in the evidence record.
