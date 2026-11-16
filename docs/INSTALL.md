# Running a portable Linux build

Portable candidates are available from the **Portable Linux candidates**
GitHub Actions workflow after its native build and installation tests pass.
Choose `linux-x86_64` for Intel/AMD 64-bit Linux or `linux-aarch64` for 64-bit
ARM Linux. A candidate is an engineering build; consult [project status](STATUS.md)
for the qualification scope. Public-pool validation is still pending.

Download the binary archive, its corresponding source archive, and
`SHA256SUMS` from the same workflow artifact. In that download directory, run:

```sh
sha256sum --check SHA256SUMS
```

Extract the binary `.tar.gz` archive and enter its directory. The executable
is statically linked: Zig, Python and a separately installed libc are not
required to run it. Start with a short offline check:

```sh
./bin/zcash-miner --version
./bin/zcash-miner --demo --params 48,5
```

The demo should print `verify=true`. It uses small test parameters for a fast
check. For a Zcash pool, use the default mainnet `(200,9)` parameters and your
pool's endpoint and worker format:

```sh
./bin/zcash-miner --pool HOST:PORT --user WORKER --probe
./bin/zcash-miner --pool HOST:PORT --user WORKER \
  --threads 1 --memory-limit-mb 3072 --stats-interval 5
```

The probe checks subscription, authorization and job parsing without solving.
During mining, look for increasing `accepted` counts in the JSON output.
`submitted` alone does not establish pool acceptance. No wallet spending key
or seed phrase is needed. Stop with Ctrl-C. This is a reference CPU miner;
commercial mining performance has not been established.

See [mining operation](MINING.md) for resource limits, statistics, reconnects
and verification, and [backends](BACKENDS.md) for RTL simulation and serial
devices. `BUILD.json` identifies the exact source commit, target, compiler,
binary checksum and corresponding source archive. Keep the licenses, notices
and `RUNTIME-SOURCE.tar.gz` with redistributed binaries.

## Troubleshooting

- `Exec format error`: confirm the archive matches `uname -m`.
- `Permission denied`: extract the `.tar.gz` with a tool that preserves Unix
  executable modes; confirm `bin/zcash-miner` has execute permission.
- Authorization rejected: check the pool's documented worker/account or
  payout-address format. The miner stops before starting workers.
- Out of memory: reduce `--threads`, ensure enough available RAM, and set an
  appropriate total `--memory-limit-mb`. Mainnet solving needs much more RAM
  than the small demo. The configured allocation limit excludes some process
  overhead.
- Submitted shares but no acceptance: inspect `rejected`, `stale`, `unknown`
  and stderr. A lost reply is recorded as unknown. Public pools may require
  protocol compatibility work or more hashing throughput than a CPU provides.
- Device worker failure: check parameter/baud/chain configuration and the
  backend guide. A failed device does not silently switch to CPU mining.
