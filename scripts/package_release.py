#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build, run and reproduce a portable Linux miner from a clean source snapshot.

Outputs are build candidates. This command does not tag, publish, or claim
that the separate mining, hardware, or long-run release gates are complete.
"""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import re
import shutil
import struct
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
TARGETS = {"x86_64-linux-musl": ("x86_64", 62), "aarch64-linux-musl": ("aarch64", 183)}


def build_options(target):
    if target not in TARGETS:
        raise ValueError("unsupported portable target")
    return [f"-Dtarget={target}", "-Doptimize=ReleaseFast", "-Dstrip=true"]


def source_record(head, version, zig, hashes):
    # Both native jobs publish the same source archive name. Its metadata
    # must describe both targets, independently of the machine packaging it.
    return {"git_head": head, "version": version, "zig": zig, "files": hashes,
            "rebuild_commands": {target: ["zig", "build", *build_options(target)]
                                 for target in sorted(TARGETS)}}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def dump(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def archive(path, root, prefix):
    """Deterministic tar/gzip: stable ordering, ownership, times and modes."""
    with path.open("wb") as output, gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as tar:
            for source in sorted(root.rglob("*")):
                if source.is_symlink():
                    raise ValueError(f"symlink is not an accepted release input: {source}")
                if not source.is_file():
                    continue
                data = source.read_bytes()
                info = tarfile.TarInfo(prefix + "/" + source.relative_to(root).as_posix())
                info.size, info.mtime = len(data), 0
                info.mode = 0o755 if source.stat().st_mode & 0o111 else 0o644
                tar.addfile(info, io.BytesIO(data))


def extract(path, destination):
    """Only regular files under one relative archive root are accepted."""
    destination.mkdir(parents=True, exist_ok=False)
    with tarfile.open(path, "r:gz") as tar:
        members = tar.getmembers()
        roots = set()
        names = set()
        for member in members:
            name = Path(member.name)
            if (not member.isfile() or name.is_absolute() or ".." in name.parts
                    or len(name.parts) < 2 or member.name in names):
                raise ValueError("unsafe or duplicate release archive member")
            roots.add(name.parts[0])
            names.add(member.name)
        if len(roots) != 1:
            raise ValueError("release archive must have exactly one root")
        for member in members:
            target = destination / member.name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(tar.extractfile(member).read())
            target.chmod(member.mode & 0o777)
    return destination / roots.pop()


def static_elf(path, machine):
    data = path.read_bytes()
    if len(data) < 64 or data[:6] != b"\x7fELF\x02\x01":
        raise ValueError("expected little-endian ELF64 executable")
    if struct.unpack_from("<H", data, 18)[0] != machine:
        raise ValueError("ELF architecture does not match selected target")
    offset = struct.unpack_from("<Q", data, 32)[0]
    size, count = struct.unpack_from("<HH", data, 54)
    if size < 56 or count == 0 or offset + size * count > len(data):
        raise ValueError("invalid ELF program header table")
    for i in range(count):
        if struct.unpack_from("<I", data, offset + i * size)[0] in (2, 3):
            raise ValueError("release binary has a dynamic segment or interpreter")


def source_snapshot(source):
    if subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT):
        raise ValueError("release candidates require a clean worktree; commit the reviewed sources first")
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    source.mkdir(parents=True, exist_ok=False)
    files = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).split(b"\0")
    hashes = {}
    for raw in files:
        if not raw:
            continue
        name = raw.decode()
        path = ROOT / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"unsupported tracked release input: {name}")
        digest = sha(path)
        target = source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        if sha(target) != digest:
            raise ValueError(f"source changed while copying: {name}")
        hashes[name] = digest
    if (subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT)
            or subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip() != head):
        raise ValueError("worktree changed during release snapshot")
    return head, hashes


def run(command, cwd, log, env=None, timeout=1800):
    with log.open("w") as stream:
        subprocess.run(command, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=timeout)


def runtime_sources(out, package, source):
    # Include the source copyright/license headers for the linked runtimes,
    # including musl's per-file third-party notices, with the binary package.
    environment = subprocess.check_output(["zig", "env"], text=True)
    library = Path(json.loads(re.search(r'\.lib_dir = ("[^"\n]+"),', environment).group(1)))
    runtime = out / "runtime-source"
    runtime.mkdir()
    for name in ("std", "compiler_rt", "libc/musl", "libc/include/generic-musl",
                 "libc/include/x86_64-linux-musl", "libc/include/aarch64-linux-musl"):
        shutil.copytree(library / name, runtime / "lib" / name)
    for name in ("compiler_rt.zig", "ubsan_rt.zig", "c.zig"):
        shutil.copy2(library / name, runtime / "lib" / name)
    for name in ("Zig-MIT.txt", "musl-COPYRIGHT.txt"):
        shutil.copy2(source / "LICENSES" / name, runtime / name)
    dump(runtime / "SOURCE.json", {"zig": "0.15.2", "upstream": "https://github.com/ziglang/zig/tree/0.15.2/lib",
         "scope": "Unmodified standard library, compiler runtime and musl source, including per-file notices",
         "files": {str(p.relative_to(runtime)): sha(p) for p in sorted(runtime.rglob("*")) if p.is_file()}})
    archive(package / "RUNTIME-SOURCE.tar.gz", runtime, "zig-0.15.2-runtime-source")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=TARGETS, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    architecture, machine = TARGETS[args.target]
    if platform.system() != "Linux" or platform.machine() != architecture:
        parser.error("run this qualification on the selected native Linux architecture")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    result = {"status": "FAIL", "scope": "portable binary packaging and reproducibility; separate release gates still apply"}
    try:
        source = out / "snapshot"
        head, hashes = source_snapshot(source)
        version = re.search(r'const VERSION = "([0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.]+)?)";', (source / "src/main.zig").read_text()).group(1)
        if f'.version = "{version}"' not in (source / "build.zig.zon").read_text():
            raise ValueError("CLI and package versions disagree")
        zig = subprocess.check_output(["zig", "version"], text=True).strip()
        if zig != "0.15.2":
            raise ValueError("release toolchain must be Zig 0.15.2")
        options = build_options(args.target)
        dump(source / "SOURCE.json", source_record(head, version, zig, hashes))
        source_name = f"zcash-miner-{version}-{head[:12]}-source"
        source_tar = out / (source_name + ".tar.gz")
        archive(source_tar, source, source_name)

        # Both builds use independent extractions of the distributed source
        # archive and separate local caches. Compare the actual binaries.
        binaries = []
        for index in (1, 2):
            tree = extract(source_tar, out / f"build-{index}")
            run(["zig", "build", *options], tree, out / f"build-{index}.log")
            binary = tree / "zig-out/bin/zcash-miner"
            static_elf(binary, machine)
            binaries.append(binary)
        if sha(binaries[0]) != sha(binaries[1]):
            raise ValueError("independent builds produced different binary bytes")

        tree = binaries[0].parents[2]
        run(["zig", "build", "test", *options, "--summary", "all"], tree, out / "unit-tests.log")
        package = out / "package"
        (package / "bin").mkdir(parents=True)
        shutil.copy2(binaries[0], package / "bin/zcash-miner")
        for name in ("LICENSE", "LICENSING.md", "NOTICE", "THIRD_PARTY_NOTICES.md", "README.md"):
            shutil.copy2(source / name, package / name)
        shutil.copytree(source / "LICENSES", package / "LICENSES")
        (package / "docs").mkdir()
        for name in ("INSTALL.md", "MINING.md", "BACKENDS.md", "STATUS.md"):
            shutil.copy2(source / "docs" / name, package / "docs" / name)
        runtime_sources(out, package, source)
        manifest = {"version": version, "git_head": head, "target": args.target, "zig": zig,
                    "binary_sha256": sha(binaries[0]), "source_archive": source_tar.name,
                    "source_archive_sha256": sha(source_tar), "static_elf": True,
                    "runtime_source_sha256": sha(package / "RUNTIME-SOURCE.tar.gz"),
                    "independent_rebuild_identical": True, "build_options": options,
                    "scope": "engineering build candidate; no public-pool, silicon or profitability claim"}
        dump(package / "BUILD.json", manifest)
        package_name = f"zcash-miner-{version}-{head[:12]}-linux-{architecture}"
        package_tar = out / (package_name + ".tar.gz")
        archive(package_tar, package, package_name)
        install = extract(package_tar, out / "fresh-install")
        installed = install / "bin/zcash-miner"
        if subprocess.check_output([str(installed), "--version"], text=True).strip() != version:
            raise ValueError("installed binary version mismatch")
        run([str(installed), "--demo", "--params", "48,5"], install, out / "onboarding-demo.log", timeout=60)
        env = dict(os.environ, ZCASH_MINER=str(installed))
        run([os.sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "test_*.py"],
            tree, out / "onboarding-tests.log", env, timeout=300)
        checksums = {path.name: sha(path) for path in (source_tar, package_tar)}
        (out / "SHA256SUMS").write_text("".join(f"{digest}  {name}\n" for name, digest in sorted(checksums.items())))
        result.update(status="PASS", target=args.target, git_head=head, version=version,
                      binary_sha256=sha(installed), independent_rebuild_identical=True,
                      native_tests=True, fresh_install_tests=True, artifacts=checksums,
                      logs={p.name: sha(p) for p in sorted(out.glob("*.log"))})
    except Exception as exc:
        result["error"] = str(exc)
        raise
    finally:
        dump(out / "result.json", result)
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
