# Mining operation and verification

The development miner implements [ZIP 301](https://zips.z.cash/zip-0301).
It preserves pool-supplied header bytes, derives the remaining nonce length
from NONCE_1, submits only NONCE_2, and prefixes minimal solutions with their
canonical CompactSize. Header version 4 is supported; unknown versions are
reported and ignored. Public-pool account validation is pending.

## Running

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/zcash-miner --pool HOST:PORT --user ACCOUNT.worker --probe
./zig-out/bin/zcash-miner --pool HOST:PORT --user ACCOUNT.worker \
  --threads 1 --memory-limit-mb 3072 --stats-interval 5
```

Use your pool's account or payout-address format. No spending key is needed.
Transport is TCP. DNS resolution uses the operating system resolver; connection,
handshake, idle and share-response timeouts are controlled by
`--timeout-seconds` (default 120). Failed connections retry with bounded
exponential backoff and jitter. Server reconnects use the configured endpoint;
they cannot redirect credentials to another host. Every session reauthorizes.

The default is one worker. The total solver allocation budget is divided
equally between workers. Allocator metadata, stacks and network buffers add
process overhead; the allocation budget is not an operating-system RSS limit.
Allocation failure stops mining with a nonzero exit and a worker-failure
counter. Increase the budget or reduce threads after checking available RAM.

CPU is the default backend. Actual RTL simulation and Linux serial transport
are selected with `--backend rtl|serial`; see the [backend guide](BACKENDS.md)
for reproducible commands, device nonce assignment and current limitations.

Each new job becomes the next work even when `clean_jobs=false`. Clean jobs
cancel active work and invalidate queued shares. Targets attach to the next
job and do not retroactively change earlier jobs. Nonce suffixes do not wrap;
exhaustion stops workers. Reused nonce prefixes retain their allocation cursor
across reconnects in the running process.

SIGINT and SIGTERM cancel active solves. `--run-seconds N` bounds a run for
qualification. `--reconnect-ms` sets the initial reconnect delay.

## Statistics

JSON lines on stdout report cumulative counters; diagnostics go to stderr.
The final record has `event="final"`. `submitted` counts attempted writes;
only a matching positive server response increments `accepted`. A rejected
response increments `rejected`, with stale rejections also counted in `stale`.
Timeouts and disconnected outstanding requests become `unknown`, because a
lost acknowledgement cannot establish acceptance or rejection. Unsolicited or
duplicate replies never increment acceptance. At shutdown:

```text
submitted = accepted + rejected + unknown
```

`attempts` counts started nonce attempts; `solutions` counts verified solver
outputs before the target check. `discarded` counts invalidated local results.
`response_ms_total` accumulates correlated response latency. These counters
describe miner activity, not pool payout or network block discovery.

## Benchmarks and correctness

```sh
./zig-out/bin/zcash-miner --bench --params 48,5 --iterations 4
./zig-out/bin/zcash-miner --bench --params 200,9 --corpus headers.txt --solutions all
./zig-out/bin/zcash-miner --bench --params 200,9 --corpus headers.txt --solutions first
./zig-out/bin/zcash-miner --bench --params 200,9 --iterations 1 --cancel-after-ms 100
python3 -m unittest discover -s tests -v
python3 scripts/benchmark_miner.py --params 200,9 --cases 4 --repeats 3 \
  --output private/benchmark200-v1
```

A corpus contains one 140-byte header input encoded as 280 hex characters per
line. Blank lines and `#` comments are allowed. Without a file, deterministic
synthetic inputs use the versioned `zcash-benchmark-corpus-v1` seed and nonce
indices. Output includes each input, all returned minimal solutions, elapsed
solve time, verified solutions/sec, peak requested solver bytes, and Linux
process peak RSS. RSS is a process-lifetime high-water mark; run cases in
separate processes when comparing isolated memory peaks.

Cancellation records the actual request timestamp and return latency. A null
latency means cancellation was not observed during the measured solve; it is
not a zero-latency result. Complete small-parameter solution sets are checked
against an independent uncapped explicit-tree implementation. This finite
test corpus does not establish universal solver completeness.

The paired benchmark runner freezes the executable and corpus, records source
hashes and CPU/tool metadata, alternates first/all run order, independently
verifies outputs in Python, and reports aggregate verified solutions/sec.
Keep its full output directory when sharing a performance result. A successful
benchmark verifies that workload; it makes no energy or profitability claim.

## Local qualification evidence

```sh
python3 tests/qualify_mining.py --seconds 300 --params 200,9 \
  --scenario normal --output private/mainnet-acceptance-v1
python3 tests/qualify_mining.py --seconds 86400 --scenario soak \
  --output private/mining-soak-v1
```

Each output directory must be new. The harness freezes the executable,
buildable software sources and verifier, records hashes and resource samples,
and writes a final result with individual checks. Mainnet-parameter acceptance
uses an intentionally easy local share target and the Python consensus
verifier. It is not acceptance by a public pool or discovery of a network block.
The fault scenario exercises reconnect requests, EOF, malformed input,
rejections, job updates and target changes. Dedicated integration tests cover
authorization failure, oversized frames, idle timeouts and worker memory
failure. Only a completed run of at least 86,400 seconds can claim 24-hour
coverage. An absent final result means the run is incomplete.
