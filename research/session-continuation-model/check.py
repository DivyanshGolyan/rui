#!/usr/bin/env python3
"""Run the bounded design checks, including expected counterexamples. No LLM calls."""
import argparse
import hashlib
import json
import platform
from datetime import datetime, timezone
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
JAR_SHA256 = '936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88'
CASES = {
    'correct': None,
    'correct-two-crashes': None,
    'broken-drop': 'NoInputLoss',
    'broken-result': 'OriginalResultStable',
    'broken-wait': 'WaitPinned',
    'witness-idle-continuation': 'NoIdleContinuationWitness',
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--jar', type=Path, required=True, help='Pinned TLA+ v1.7.4 tla2tools.jar')
    parser.add_argument('--java', default='java')
    parser.add_argument('--output', type=Path, default=ROOT / 'results')
    args = parser.parse_args()
    jar = args.jar.resolve()
    if hashlib.sha256(jar.read_bytes()).hexdigest() != JAR_SHA256:
        parser.error('Jar does not match the recorded v1.7.4 artifact; inspect it before updating the pin.')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    summary = {'recorded_at': datetime.now(timezone.utc).isoformat(), 'platform': platform.platform(), 'java_version': subprocess.run([args.java, '-version'], text=True, capture_output=True, check=True).stderr.strip(), 'jar_source': 'https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar', 'jar_sha256': JAR_SHA256, 'model_sha256': hashlib.sha256((ROOT / 'SessionContinuation.tla').read_bytes()).hexdigest(), 'cases': {}}
    for name, expected in CASES.items():
        with tempfile.TemporaryDirectory(prefix='onepage-session-tlc-') as tmp:
            # TLC may generate trace modules on failure. Run on temporary copies
            # so the model folder contains only authored sources and saved logs.
            work = Path(tmp)
            for filename in ['SessionContinuation.tla', name + '.cfg']:
                (work / filename).write_bytes((ROOT / filename).read_bytes())
            command = [args.java, '-XX:+UseParallelGC', '-Xmx512m', '-cp', str(jar),
                       'tlc2.TLC', '-workers', '1', '-fp', '0', '-seed', '1',
                       '-metadir', str(work / 'states'), '-config', name + '.cfg',
                       'SessionContinuation.tla']
            run = subprocess.run(command, cwd=work, text=True, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, timeout=120)
        (output / (name + '.log')).write_text(run.stdout)
        violated = re.search(r'Error: Invariant (\w+) is violated\.', run.stdout)
        actual = violated.group(1) if violated else None
        counts = re.search(r'([\d,]+) states generated, ([\d,]+) distinct states found, ([\d,]+) states left on queue', run.stdout)
        counts = [int(s.replace(',', '')) for s in counts.groups()] if counts else None
        passed = (run.returncode == 12 and actual == expected) if expected else (
            run.returncode == 0 and 'Model checking completed. No error has been found.' in run.stdout
            and counts is not None and counts[2] == 0)
        summary['cases'][name] = {'expected_violation': expected, 'actual_violation': actual,
            'exit_code': run.returncode, 'expectation_met': passed,
            'states_generated_distinct_queued': counts,
            'config_sha256': hashlib.sha256((ROOT / (name + '.cfg')).read_bytes()).hexdigest()}
        print(f'{name}: {"PASS" if passed else "UNEXPECTED"}; {actual or "no violation"}; counts={counts}', flush=True)
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    return 0 if all(case['expectation_met'] for case in summary['cases'].values()) else 1


if __name__ == '__main__':
    raise SystemExit(main())
