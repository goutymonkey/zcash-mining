# Contributing

This is an experimental Zcash mining software and hardware project.
Contributions to correctness, reproducibility, memory architecture and
verification are welcome. Start with the [README](README.md),
[chip overview](asic/chip/README.md) and [current status](docs/STATUS.md).

For a bug report, include the commit, command, parameters, tool versions,
expected behavior and a minimal reproducer. Remove credentials and private
data from logs. Use [SECURITY.md](SECURITY.md) for sensitive reports.

For substantial architecture changes, open an issue describing the problem
and the evidence you will use to compare alternatives. Keep pull requests
focused and describe what changed, why, and how you checked it. Communicate
respectfully and review technical claims on their evidence.

## Local checks

Use Zig **0.15.2**, Python **3.11** and a virtual environment for the same
configuration used by CI. The Python model tests require NumPy.

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements-dev.txt
zig build -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseFast
python scripts/check_python.py
./zig-out/bin/zcash-miner --demo --params 48,5
git diff --check
```

The Python mining integration tests run the built binary against an independent
loopback pool and verifier. A sandbox that prohibits local listening sockets
cannot run those tests. They need the preceding Zig build. Complete small
solution sets are also compared with an uncapped explicit-tree Python oracle.
The Python runner executes each suite separately because their modules use
directory-local imports; a single top-level discovery can miss suites.

These checks need no mining account, Docker, foundry PDK or external pool.
They do not rerun full mainnet simulations, hardware formal proofs or physical
signoff. For RTL changes, also run the relevant commands documented in
[asic/chip/README.md](asic/chip/README.md), record the tool/image revision and
report exactly which parameters and properties were checked.

For board changes, follow [asic/README.md](asic/README.md). Generated outputs
belong in ignored build directories. Review pin mappings and electrical
assumptions separately from a successful PCB build.

## Verification evidence

- Compare complete solution sets with an independent verifier, not just a
  solution count or one successful sample.
- Keep simulations, generic synthesis, formal equivalence and physical
  timing/power results distinct. State workload and geometry limits.
- Preserve original failed, timed-out and partial results. A narrower proof
  does not turn the original full-design verdict into a pass.
- Treat `asic/chip/build/plan-d-source/` as immutable. New experiments use
  fresh directories and manifests; do not edit archived bytes or rewrite
  historical evidence to match current source.

## Licensing and private material

By submitting a contribution, you agree to license your contribution under
the applicable terms in [LICENSING.md](LICENSING.md). Only contribute material
you have the right to share. Imported code needs its original notices,
license and source reference in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
New original files should carry an SPDX identifier matching their scope.

Do not commit wallet keys, credentials, `.env` files, production PDKs,
restricted SRAM views, NDA documents or private supplier correspondence.
`.gitignore` is a convenience, not a substitute for reviewing a diff.

With [Gitleaks](https://github.com/gitleaks/gitleaks) installed, scan reachable
history before publication or importing source:

```sh
gitleaks git . --log-opts=--all --redact
```

Use a separate export of the intended files for a directory scan. Do not
upload local credential directories or unredacted scanner reports to issues.
