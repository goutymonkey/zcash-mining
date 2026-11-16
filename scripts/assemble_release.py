#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Verify both native candidates and assemble one unambiguous release set.

This checks the artifacts and recorded native test results; it does not run
foreign binaries or replace the separate mining and hardware qualifications.
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import tempfile

from package_release import TARGETS, build_options, dump, extract, sha, source_record, static_elf

LOGS = {"build-1.log", "build-2.log", "unit-tests.log", "onboarding-demo.log", "onboarding-tests.log"}


def assemble(candidates, output, commit):
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("expected a full Git commit identifier")
    reports = sorted(candidates.glob("*/result.json"))
    if len(reports) != len(TARGETS):
        raise ValueError("expected exactly one native report per supported architecture")
    output.mkdir(parents=True, exist_ok=False)
    result = {"status": "FAIL", "git_head": commit,
              "scope": "artifact integrity, matching sources and recorded native tests; separate release gates still apply"}
    try:
        versions, targets, artifacts, native = set(), set(), {}, {}
        with tempfile.TemporaryDirectory(prefix="zcash-release-") as directory:
            temporary = Path(directory)
            for report in reports:
                record = json.loads(report.read_text())
                target = record.get("target")
                if target not in TARGETS or target in targets:
                    raise ValueError("unsupported or duplicate native target")
                targets.add(target)
                architecture, machine = TARGETS[target]
                version = record.get("version", "")
                if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.]+)?", version):
                    raise ValueError("invalid candidate version")
                versions.add(version)
                if record.get("git_head") != commit or record.get("status") != "PASS":
                    raise ValueError("candidate failed or belongs to a different commit")
                for check in ("independent_rebuild_identical", "native_tests", "fresh_install_tests"):
                    if record.get(check) is not True:
                        raise ValueError(f"missing successful native check: {check}")
                stem = f"zcash-miner-{version}-{commit[:12]}"
                source_name = stem + "-source.tar.gz"
                binary_name = stem + f"-linux-{architecture}.tar.gz"
                if set(record["artifacts"]) != {source_name, binary_name}:
                    raise ValueError("unexpected candidate artifact names")
                expected_sums = "".join(f"{digest}  {name}\n" for name, digest in sorted(record["artifacts"].items()))
                if (report.parent / "SHA256SUMS").read_text() != expected_sums:
                    raise ValueError("candidate checksum file does not match its report")
                for name, digest in record["artifacts"].items():
                    path = report.parent / name
                    if path.is_symlink() or sha(path) != digest:
                        raise ValueError(f"artifact hash mismatch: {name}")
                    if name in artifacts and artifacts[name] != digest:
                        raise ValueError(f"different bytes share an artifact filename: {name}")
                    artifacts[name] = digest
                if set(record["logs"]) != LOGS:
                    raise ValueError("missing native validation logs")
                for name, digest in record["logs"].items():
                    if sha(report.parent / name) != digest:
                        raise ValueError(f"validation log hash mismatch: {name}")

                tree = extract(report.parent / source_name, temporary / f"source-{architecture}")
                source = json.loads((tree / "SOURCE.json").read_text())
                files = {p.relative_to(tree).as_posix(): sha(p) for p in tree.rglob("*")
                         if p.is_file() and p != tree / "SOURCE.json"}
                if source != source_record(commit, version, "0.15.2", files):
                    raise ValueError("source manifest does not match the archive and supported rebuild commands")
                package = extract(report.parent / binary_name, temporary / f"binary-{architecture}")
                build = json.loads((package / "BUILD.json").read_text())
                expected = {"version": version, "git_head": commit, "target": target, "zig": "0.15.2",
                            "binary_sha256": record["binary_sha256"], "source_archive": source_name,
                            "source_archive_sha256": record["artifacts"][source_name], "static_elf": True,
                            "runtime_source_sha256": sha(package / "RUNTIME-SOURCE.tar.gz"),
                            "independent_rebuild_identical": True, "build_options": build_options(target)}
                if any(build.get(key) != value for key, value in expected.items()):
                    raise ValueError("binary build manifest does not match its native report")
                binary = package / "bin/zcash-miner"
                if sha(binary) != record["binary_sha256"]:
                    raise ValueError("packaged binary hash mismatch")
                static_elf(binary, machine)
                for name in ("LICENSE", "LICENSING.md", "NOTICE", "THIRD_PARTY_NOTICES.md",
                             "LICENSES/Zig-MIT.txt", "LICENSES/musl-COPYRIGHT.txt"):
                    if not (package / name).is_file() or sha(package / name) != files.get(name):
                        raise ValueError(f"missing or altered packaged license notice: {name}")

                verification = output / "verification" / architecture
                verification.mkdir(parents=True)
                for name in sorted(LOGS | {"result.json", "SHA256SUMS"}):
                    shutil.copy2(report.parent / name, verification / name)
                native[target] = {"result_sha256": sha(report), "binary_sha256": record["binary_sha256"]}
            if len(versions) != 1 or targets != set(TARGETS):
                raise ValueError("candidates do not cover one version on both architectures")
            # Nothing is made distributable until both candidates validate.
            for report in reports:
                record = json.loads(report.read_text())
                for name in record["artifacts"]:
                    destination = output / name
                    if not destination.exists():
                        shutil.copy2(report.parent / name, destination)
                    if sha(destination) != artifacts[name]:
                        raise ValueError("artifact changed while assembling the release set")
            (output / "SHA256SUMS").write_text("".join(f"{digest}  {name}\n" for name, digest in sorted(artifacts.items())))
            result.update(status="PASS", version=versions.pop(), artifacts=artifacts, native=native)
    except Exception as exc:
        result["error"] = str(exc)
        raise
    finally:
        dump(output / "result.json", result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidates", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()
    print(json.dumps(assemble(args.candidates, args.output, args.commit), indent=2))


if __name__ == "__main__":
    main()
