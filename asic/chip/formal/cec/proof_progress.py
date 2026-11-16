"""Describe where an archived SBY run stopped; never upgrade its verdict."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def summarize(log, status, exit_code):
    words = status.split()
    if (type(exit_code) is not int or len(words) != 3 or not words[1].isdigit()
            or int(words[1]) != exit_code):
        raise ValueError('inconsistent terminal status')
    state = words[0]
    codes = {'PASS': 0, 'FAIL': 2, 'UNKNOWN': 4, 'TIMEOUT': 8, 'ERROR': 16}
    if codes.get(state) != exit_code:
        raise ValueError('unexpected terminal status/exit code')
    terminals = re.findall(r'^SBY \d{2}:\d{2}:\d{2} \[[^\]]+\] DONE \((\w+), rc=(\d+)\)$', log, re.M)
    if terminals != [(state, str(exit_code))]:
        raise ValueError('missing or contradictory terminal log')
    starts = re.findall(r'^SBY \d{2}:\d{2}:\d{2} \[[^\]]+\] ([\w.]+): starting process "(.*)"$', log, re.M)
    # Engine selection and counterexample conversion are not proof searches.
    searches = [phase for phase, command in starts if phase.startswith('engine_')
                and re.search(r'\b(?:yosys-abc|yosys-smtbmc)\b', command)
                and '--yw ' not in command]
    stage = starts[-1][0] if starts else None
    category = state
    if state == 'TIMEOUT':
        category = ('ENGINE_TIMEOUT' if searches else 'MODEL_PREPARATION_TIMEOUT'
                    if stage in ('base', 'prep', 'smt2', 'aig') else 'UNKNOWN_STAGE_TIMEOUT')
    return dict(terminal_status=state, terminal_stage=stage, category=category,
                proof_search_started=bool(searches), proof_search_processes=searches,
                release_eligible=False, full_design_equivalence=False,
                scope='Log-stage diagnosis only; does not validate proof soundness or change the archived verdict.')


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1048576), b''):
            digest.update(block)
    return digest.hexdigest()


def review(path):
    result = json.loads(path.read_text())
    texts = {}
    for name in ('proof/status', 'proof/logfile.txt'):
        source = (path.parent / name).resolve()
        source.relative_to(path.parent.resolve())
        raw = source.read_bytes()
        if hashlib.sha256(raw).hexdigest() != result['evidence_sha256'].get(name):
            raise ValueError('changed or unbound progress evidence: ' + name)
        texts[name] = raw.decode()
    record = summarize(texts['proof/logfile.txt'], texts['proof/status'], result['exit_code'])
    if record['terminal_status'] != result['status']:
        raise ValueError('result verdict differs from terminal evidence')
    record.update(result_sha256=sha(path), evidence_sha256={name: result['evidence_sha256'][name]
                                                          for name in texts})
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--result', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    record = review(args.result)
    with args.output.open('x') as stream:
        stream.write(json.dumps(record, indent=2) + '\n')
    print(record['category'])
