"""Container-side Yosys stage with frozen-input and memory-limit evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import resource
import subprocess
import time


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def memory_counters():
    values = {}
    for name in ('memory.current', 'memory.peak', 'memory.events',
                 'memory/memory.usage_in_bytes', 'memory/memory.max_usage_in_bytes',
                 'memory/memory.failcnt', 'memory/memory.oom_control'):
        path = Path('/sys/fs/cgroup') / name
        if path.is_file():
            values[name] = path.read_text().strip()
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--name', required=True)
    parser.add_argument('--input', action='append', default=[])
    parser.add_argument('--timeout', type=int, required=True)
    args = parser.parse_args()
    script = args.name + '.ys'
    runner = str(Path(__file__).resolve().relative_to(Path.cwd()))
    inputs = {p: sha(p) for p in [script, runner, *args.input]}
    result = dict(status='FAIL', command=['yosys', '-Q', '-T', '-s', script],
                  input_sha256=inputs, memory_before=memory_counters(),
                  timeout_seconds=args.timeout)
    start = time.monotonic()
    try:
        process = subprocess.run(result['command'], timeout=args.timeout)
        result['exit_code'] = process.returncode
        if process.returncode == 0:
            result['status'] = 'PASS'
    except subprocess.TimeoutExpired:
        result.update(status='TIMEOUT', exit_code=124)
    finally:
        result['elapsed_seconds'] = time.monotonic() - start
        result['memory_after'] = memory_counters()
        result['child_peak_rss_KiB'] = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
        result['inputs_unchanged'] = all(sha(p) == digest for p, digest in inputs.items())
        if not result['inputs_unchanged']:
            result['status'] = 'FAIL'
        Path(args.name + '-execution.json').write_text(json.dumps(result, indent=2) + '\n')
    return result['status'] == 'PASS'


if __name__ == '__main__':
    raise SystemExit(0 if main() else 1)
