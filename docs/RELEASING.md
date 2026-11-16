# Portable candidate packaging

`scripts/package_release.py` builds from a clean Git worktree, freezes every
tracked source file, and produces a source archive and a portable Linux binary
archive. It supports native x86-64 and AArch64 Linux with Zig 0.15.2 and Python
3.11 plus `requirements-dev.txt`. Use the matching native target:

```sh
python3 scripts/package_release.py --target x86_64-linux-musl \
  --output private/release-x86-v1
python3 scripts/package_release.py --target aarch64-linux-musl \
  --output private/release-arm-v1
```

Output paths must be new. The packager extracts its own source archive twice,
builds in different directories with independent local caches, requires
byte-identical executables, checks ELF architecture and static linking, runs
native unit tests, then tests the binary extracted from the installation
archive. The installation checks include independent mainnet verification,
small-parameter solving, CPU pool behavior, device transport faults and serial
pseudo-terminals. They do not contact a public pool or fabricate hardware.

`result.json` reports each build's result and binds its artifact/log hashes.
`SHA256SUMS` covers both archives. The binary archive includes `BUILD.json`,
operating guides, license notices and an archive of the toolchain's standard
library, compiler-runtime and musl source so per-file runtime notices travel
with the executable. Archive ordering, ownership, timestamps and modes are
normalized. C source paths are normalized before compilation, and debug
information is stripped from portable builds.

The source archive contains `SOURCE.json` with the commit, per-file hashes,
compiler version and rebuild commands for both supported targets. It is the
same archive on both architectures. Rebuilding requires the pinned Zig
distribution; compare the resulting binary against `BUILD.json`.

After downloading both native candidate artifacts into separate subdirectories,
assemble the release set with:

```sh
python3 scripts/assemble_release.py --candidates private/candidates \
  --output private/assembled --commit FULL_COMMIT_HASH
```

This requires successful native reports from both architectures at the selected
commit. It checks archive and log hashes, identical shared source archives,
source manifests, packaged binaries, runtime archive hashes and license notices.
The output has one source archive, two binary archives, one `SHA256SUMS`, and
both native validation records. A mismatch fails assembly. It verifies recorded
native checks; it does not execute a foreign-architecture binary.

## CI and publication

The **Portable Linux candidates** workflow runs on demand and on `v*` tags,
using native `ubuntu-24.04` and `ubuntu-24.04-arm` runners. Tool downloads and
workflow actions are pinned. It uploads candidates and logs, including failure
logs, as GitHub Actions artifacts, then runs the combined artifact check above.
Only a passing assembly produces a `release-set-COMMIT` artifact. The workflow
does not create a GitHub release or change repository visibility.

Before a release, update both `src/main.zig` and `build.zig.zon` to the same
version; the packager rejects disagreement. Review the [launch ledger](LAUNCH_PLAN.md)
and require the intended qualification evidence, CI and artifact checks for
the release's actual source. A successful packaging run establishes binary
reproduction and installation, not the separate long-run, pool or hardware
milestones. Preserve historical run reports and create new reports for new
source or scope instead of relabeling earlier evidence.
