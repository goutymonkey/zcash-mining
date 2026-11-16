# CPU, RTL and serial mining backends

The host accepts `--backend cpu|rtl|serial`. Every backend supplies the full
140-byte input and minimal Equihash solution to the same host verifier and
job-bound target check. Only those verified shares enter the bounded pool
submission queue. CPU is the default. The RTL backend connects to a simulator
that runs the actual Verilog UART, link, hash, solver and share-filter logic.

The digital simulator has a shared ideal clock. It does not model oscillators,
physical timing, board power, cooling, process corners or fabricated silicon.
Simulation wall-clock speed is not an ASIC hashrate or clock-frequency result.

## Reproduce the RTL path

Use Docker, Zig 0.15.2 and Python 3.11 with `requirements-dev.txt` installed.
The Verilator 5.052 image is pinned by digest in `asic/chip/toolchain.json`.
The compiler runs without networking against a frozen source snapshot.

```sh
docker pull verilator/verilator@sha256:a5b73e2fce0b2c483396f3800940f33b6faa802331a061c21694dd27b7352120
python3 asic/chip/sim/build.py --build asic/chip/build/host48-v1
python3 asic/chip/sim/bridge.py --build asic/chip/build/host48-v1 \
  --smoke-report asic/chip/build/host48-v1/smoke.json
python3 tests/qualify_device.py --build asic/chip/build/host48-v1 \
  --seconds 30 --output private/rtl-pool48-v1
```

Choose fresh output paths for each run. `build.py --chips 4` builds the full
four-chip digital chain. `--n 200` builds mainnet `(200,9)` geometry; it requires
more compilation time and memory. The smoke test uses complete independent
solution sets at `(48,5)` and recorded CPU vectors plus independent solution
verification at `(200,9)`. The qualification script freezes both executables,
their source snapshots, the bridge and verifier, and records accepted shares,
logs, hashes and individual pass/fail checks. It uses a synthetic local pool.

To expose a simulator for a separate host process:

```sh
python3 asic/chip/sim/bridge.py --build asic/chip/build/host48-v1 --port 8421
./zig-out/bin/zcash-miner --pool HOST:PORT --user WORKER --params 48,5 \
  --backend rtl --device 127.0.0.1:8421 --chips 1 --threads 1
```

The pool must use the same parameters as the simulator. Public Zcash pools
require `(200,9)`; the example above requires a small-parameter test pool.
The bridge binds localhost, resets the simulated chain for each connection,
and forwards protocol bytes through the actual RTL UART pins. Bounded queues
pause virtual time under output backpressure instead of losing bytes.

## Physical serial transport

```sh
./zig-out/bin/zcash-miner --pool HOST:PORT --user WORKER --params 200,9 \
  --backend serial --device /dev/ttyUSB0 --baud 2500000 --chips 4 --threads 1
```

This requires a board implementing ZEQ protocol version 2 at the configured
baud and Equihash geometry. The Linux serial driver uses raw 8N1 with hardware
flow control disabled. Supported baud rates are 115200, 460800, 921600, 1000000
and 2500000. Permissions and adapter support must match the device. The driver
has been exercised with pseudo-terminals; physical adapter, electrical and
silicon behavior remain unqualified.

## Backend contract and limits

- One host worker owns one chain of 1–4 chips at contiguous addresses starting
  at zero. CPU mining supports multiple workers. Mixing backends in one process
  is not implemented.
- Each device job reserves a distinct host nonce prefix. The chip owns input
  byte 136 for its address and bytes 137–139 for its attempt counter. Pool
  `NONCE_1` must leave at least five bytes for the host/device split (at most
  27 bytes). Unsupported prefixes and exhaustion fail visibly.
- The initial driver accepts attempt zero from each chip, then starts a fresh
  host allocation. Automatic later attempts are discarded. This bounds result
  tracking and simplifies cancellation; larger batches are future throughput
  work. Device job IDs may wrap, but the host nonce allocation does not.
- Protocol-v2 `DONE` counts solutions before share filtering. The driver sets
  the device target to its maximum, receives all solutions, and applies the
  actual pool target on the host. Efficient filtered completion needs a versioned
  protocol update; changing only the target would make completion ambiguous.
- `DONE` can precede the associated solution frames. Completion requires both
  the per-chip count and its reported solutions. CRC framing is bounded;
  corrupted frames resynchronize, while missing frames eventually time out.
- Clean jobs and shutdown request cancellation and send `STOP`. Discovery runs
  before each new device job. Invalid proofs, indices, duplicate solutions,
  discovery faults, disconnects and timeouts stop the worker with a nonzero
  process exit. No failed device silently switches to CPU mining.
- `--device-timeout` bounds each discovery/solve operation (default 120 seconds).
  The JSON status includes `backend` and discovered chip versions, flags, lane
  counts and raw sensor codes. Sensor codes are not calibrated temperatures.
  Device `attempts` counts host-reserved attempts, including interrupted work.

`tests/test_backend.py` uses explicitly labeled reference transport fixtures
for fragmentation, malformed output, stale jobs, cancellation and serial
pseudo-terminal checks. Those tests are separate from actual RTL evidence.
The hardware CI workflow runs short RTL integration on relevant changes and
offers a longer mainnet run through `workflow_dispatch`.
