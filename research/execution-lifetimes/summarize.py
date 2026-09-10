#!/usr/bin/env python3
"""Audit recorded evidence without replacing its historical provenance."""
import argparse
import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
POINTS = {(1, 4096), (100, 4096), (1000, 4096), (100, 1024), (100, 1048576)}
POSITIVE_CHECKS = {
    'pending_cleanup_rejected', 'delayed_callback_drained',
    'cancelled_publication_suppressed', 'failed_capture_not_sealed',
    'released_after_join', 'settled_credit_held_through_callback',
    'sealed_source_not_written',
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def audit(matrix, checks):
    expected = {(kind, variant, n, size) for kind in ('model', 'bash', 'edit')
                for variant in ('baseline', 'early') for n, size in POINTS}
    keys = [(c['kind'], c['variant'], c['count'], c['payload_bytes'])
            for c in matrix['cases']]
    require(len(keys) == len(set(keys)) and set(keys) == expected,
            'Matrix must contain each of the 30 distinct cells exactly once')
    derived = []
    for case in matrix['cases']:
        stages = ['cold', 'fixed_custody', 'loaded']
        if case['kind'] == 'model':
            stages += ['transport_active']
        stages += ['sealed_waiting', 'delayed_validation', 'retained_idle', 'closed']
        require([x['stage'] for x in case['samples']] == stages,
                'Missing, duplicate or reordered lifecycle snapshot')
        s = {x['stage']: x for x in case['samples']}
        require(case['exit'] == 0, 'Fixture did not complete successfully')
        for stage in ('sealed_waiting', 'delayed_validation'):
            require(s[stage]['occupied'] == case['count'], 'Custody released before validation')
        for stage in ('retained_idle', 'closed'):
            require(s[stage]['occupied'] == s[stage]['owned_fds'] == 0,
                    'Custody or owned descriptors survived cleanup')
        require(s['closed']['own_live'] == s['closed']['curl_live'] == 0,
                'Tracked allocation survived final closure')
        if case['kind'] == 'bash':
            require(s['sealed_waiting']['children_observed'] == case['count'],
                    'Missing subprocess observation at sealed capture')
            if case['variant'] == 'early':
                require(s['delayed_validation']['children_observed'] == 0,
                        'Subprocess survived early cleanup')
        derived.append(dict(
            kind=case['kind'], variant=case['variant'], count=case['count'],
            payload_bytes=case['payload_bytes'],
            active_application_increment=s['sealed_waiting']['own_live'] - s['retained_idle']['own_live'],
            curl_released_before_validation=s['sealed_waiting']['curl_live'] - s['delayed_validation']['curl_live']))
    for kind in ('bash', 'edit'):
        for n in (1, 100, 1000):
            pair = {c['variant']: c for c in derived
                    if c['kind'] == kind and c['count'] == n and c['payload_bytes'] == 4096}
            require(pair['baseline']['active_application_increment'] -
                    pair['early']['active_application_increment'] == 16384 * n,
                    'Recorded window comparison differs from the reported saving')
    require(set(checks['positive']) == POSITIVE_CHECKS and
            all(v is True for v in checks['positive'].values()), 'Missing or failed callback control')
    require(checks['negative_exit'] != 0 and 'heap-use-after-free' in checks['negative_diagnostic'],
            'Unsafe release was not detected by the sanitizer')
    require(checks['production_bash']['released_live'] == 0, 'Production Bash allocation retained')
    captures = checks['production_capture']
    require(len(captures) == 2 and {c['count'] for c in captures} == {1, 100},
            'Missing production parser population')
    require(all(c['released_live'] == 0 for c in captures), 'Production parser allocation retained')
    return derived


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, help='Write a separate audit for a new reproduction')
    args = parser.parse_args()
    matrix = json.loads((HERE / 'results.json').read_text())
    checks = json.loads((HERE / 'checks.json').read_text())
    derived = audit(matrix, checks)
    for name in ('probe.c', 'run.py'):
        require(digest(HERE / name) == matrix['sources'][name], f'Matrix source changed: {name}')
    raw_hashes = {name: digest(HERE / name) for name in ('results.json', 'checks.json')}
    if args.output:
        protected = {p.resolve() for p in HERE.iterdir() if p.is_file()}
        require(args.output.resolve() not in protected, 'Audit output must not overwrite an existing artifact')
        # Execution environment belongs to the recorded run, never this audit process.
        result = dict(revision=matrix['revision'], matrix_closed_cells=len(derived), derived=derived,
                      recorded_matrix_machine=matrix['machine'], raw_hashes=raw_hashes,
                      sources_at_audit={p.name: digest(p) for p in HERE.iterdir()
                                        if p.suffix in ('.py', '.c', '.zig')})
        args.output.write_text(json.dumps(result, indent=2) + '\n')
    else:
        recorded = json.loads((HERE / 'manifest.json').read_text())
        require(raw_hashes == recorded['raw_hashes'], 'Raw evidence changed; use --output for a new reproduction audit')
        require(derived == recorded['derived'], 'Derived evidence disagrees with the recorded manifest')
        for name in ('check.py', 'failures.c', 'production_bash.zig', 'production_capture.zig', 'tracking.zig'):
            require(digest(HERE / name) == recorded['sources'][name], f'Check source changed: {name}')
    print('30 distinct matrix cells and all production/callback controls passed; historical manifest preserved.')


if __name__ == '__main__':
    main()
