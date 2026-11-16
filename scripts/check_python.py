#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run all Python unit suites, including the separately imported CEC suite."""
from pathlib import Path
import argparse
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
SUITES = (
    "tests",
    "asic/chip/formal",
    "asic/chip/formal/cec",
    "asic/chip/model",
    "asic/chip/pd",
    "asic/chip/tb",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", action="append", choices=SUITES,
                        help="run only the selected suite (repeatable)")
    args = parser.parse_args()
    failed = []
    for suite in args.suite or SUITES:
        print(f"Running {suite}", flush=True)
        result = subprocess.run(
            [sys.executable, "-m", "unittest", "discover", "-s", suite,
             "-p", "test_*.py"],
            cwd=ROOT,
        )
        if result.returncode:
            failed.append(suite)
    if failed:
        print("Failed suites: " + ", ".join(failed), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
