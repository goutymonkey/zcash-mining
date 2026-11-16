# SPDX-License-Identifier: Apache-2.0
import importlib.util
import io
import json
from pathlib import Path
import struct
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("package_release", ROOT / "scripts/package_release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
sys.path.insert(0, str(ROOT / "scripts"))
import assemble_release


class ReleasePackagingTests(unittest.TestCase):
    def test_archive_is_deterministic_and_preserves_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            (source / "miner").write_bytes(b"executable")
            (source / "miner").chmod(0o755)
            (source / "LICENSE").write_text("license")
            release.archive(root / "a.tar.gz", source, "release")
            release.archive(root / "b.tar.gz", source, "release")
            self.assertEqual(release.sha(root / "a.tar.gz"), release.sha(root / "b.tar.gz"))
            installed = release.extract(root / "a.tar.gz", root / "install")
            self.assertEqual((installed / "miner").stat().st_mode & 0o777, 0o755)

    def test_extractor_rejects_escape_links_and_duplicates(self):
        for case in ("escape", "link", "duplicate"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                path = root / "bad.tar.gz"
                with tarfile.open(path, "w:gz") as tar:
                    member = tarfile.TarInfo("../escape" if case == "escape" else "release/file")
                    if case == "link":
                        member.type = tarfile.SYMTYPE
                        member.linkname = "/tmp/escape"
                    else:
                        member.size = 1
                    tar.addfile(member, io.BytesIO(b"x"))
                    if case == "duplicate":
                        tar.addfile(member, io.BytesIO(b"y"))
                with self.assertRaises(ValueError):
                    release.extract(path, root / "install")

    def test_static_check_rejects_wrong_architecture_and_dynamic_interpreter(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "elf"
            data = bytearray(120)
            data[:6] = b"\x7fELF\x02\x01"
            struct.pack_into("<H", data, 18, 62)
            struct.pack_into("<Q", data, 32, 64)
            struct.pack_into("<HH", data, 54, 56, 1)
            struct.pack_into("<I", data, 64, 1)
            path.write_bytes(data)
            release.static_elf(path, 62)
            with self.assertRaises(ValueError):
                release.static_elf(path, 183)
            struct.pack_into("<I", data, 64, 3)
            path.write_bytes(data)
            with self.assertRaises(ValueError):
                release.static_elf(path, 62)


class ReleaseAssemblyTests(unittest.TestCase):
    commit = "a" * 40
    version = "1.2.3"

    def candidates(self, root):
        """Tiny synthetic packages exercise manifest integrity without mining."""
        candidates = root / "candidates"
        source = root / "source"
        source.mkdir()
        for name in ("LICENSE", "LICENSING.md", "NOTICE", "THIRD_PARTY_NOTICES.md",
                     "LICENSES/Zig-MIT.txt", "LICENSES/musl-COPYRIGHT.txt"):
            p = source / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(name)
        hashes = {p.relative_to(source).as_posix(): release.sha(p) for p in source.rglob("*") if p.is_file()}
        release.dump(source / "SOURCE.json", release.source_record(self.commit, self.version, "0.15.2", hashes))
        stem = f"zcash-miner-{self.version}-{self.commit[:12]}"
        for target, (architecture, machine) in release.TARGETS.items():
            directory = candidates / architecture
            directory.mkdir(parents=True)
            source_tar = directory / (stem + "-source.tar.gz")
            release.archive(source_tar, source, stem + "-source")
            package = root / f"package-{architecture}"
            (package / "bin").mkdir(parents=True)
            data = bytearray(120)
            data[:6] = b"\x7fELF\x02\x01"
            struct.pack_into("<H", data, 18, machine)
            struct.pack_into("<Q", data, 32, 64)
            struct.pack_into("<HH", data, 54, 56, 1)
            struct.pack_into("<I", data, 64, 1)
            binary = package / "bin/zcash-miner"
            binary.write_bytes(data)
            binary.chmod(0o755)
            runtime = package / "RUNTIME-SOURCE.tar.gz"
            runtime.write_bytes(b"synthetic runtime source")
            for name in hashes:
                dest = package / name
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes((source / name).read_bytes())
            release.dump(package / "BUILD.json", {
                "version": self.version, "git_head": self.commit, "target": target, "zig": "0.15.2",
                "binary_sha256": release.sha(binary), "source_archive": source_tar.name,
                "source_archive_sha256": release.sha(source_tar), "static_elf": True,
                "runtime_source_sha256": release.sha(runtime), "independent_rebuild_identical": True,
                "build_options": release.build_options(target)})
            binary_tar = directory / (stem + f"-linux-{architecture}.tar.gz")
            release.archive(binary_tar, package, binary_tar.name[:-7])
            artifacts = {p.name: release.sha(p) for p in (source_tar, binary_tar)}
            logs = {}
            for name in assemble_release.LOGS:
                (directory / name).write_text("synthetic log\n")
                logs[name] = release.sha(directory / name)
            release.dump(directory / "result.json", {
                "status": "PASS", "git_head": self.commit, "version": self.version, "target": target,
                "independent_rebuild_identical": True, "native_tests": True, "fresh_install_tests": True,
                "artifacts": artifacts, "logs": logs, "binary_sha256": release.sha(binary)})
            self.checksums(directory, artifacts)
        return candidates

    def checksums(self, directory, artifacts):
        (directory / "SHA256SUMS").write_text("".join(f"{digest}  {name}\n" for name, digest in sorted(artifacts.items())))

    def test_combines_two_architectures_with_one_source_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = assemble_release.assemble(self.candidates(root), root / "release", self.commit)
            self.assertEqual(result["status"], "PASS")
            self.assertEqual(set(result["native"]), set(release.TARGETS))
            self.assertEqual(len(result["artifacts"]), 3)
            self.assertEqual(len(list((root / "release").glob("*-source.tar.gz"))), 1)

    def test_rejects_missing_failed_altered_or_mismatched_candidates(self):
        for case in ("missing", "failed", "log", "checksum", "source_collision", "wrong_binary"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                candidates = self.candidates(root)
                candidate = candidates / "x86_64"
                report = candidate / "result.json"
                record = json.loads(report.read_text())
                if case == "missing":
                    report.unlink()
                elif case == "failed":
                    record["fresh_install_tests"] = False
                elif case == "log":
                    (candidate / "unit-tests.log").write_text("changed")
                elif case == "checksum":
                    (candidate / "SHA256SUMS").write_text("")
                elif case == "source_collision":
                    source_tar = next(candidate.glob("*-source.tar.gz"))
                    source_tar.write_bytes(source_tar.read_bytes() + b"changed")
                    record["artifacts"][source_tar.name] = release.sha(source_tar)
                    self.checksums(candidate, record["artifacts"])
                else:
                    package = root / "package-x86_64"
                    binary = package / "bin/zcash-miner"
                    binary.write_bytes(binary.read_bytes() + b"changed")
                    binary_tar = next(candidate.glob("*-linux-x86_64.tar.gz"))
                    release.archive(binary_tar, package, binary_tar.name[:-7])
                    record["artifacts"][binary_tar.name] = release.sha(binary_tar)
                    self.checksums(candidate, record["artifacts"])
                if case != "missing":
                    release.dump(report, record)
                with self.assertRaises(ValueError):
                    assemble_release.assemble(candidates, root / "release", self.commit)
                self.assertFalse((root / "release/SHA256SUMS").exists())
