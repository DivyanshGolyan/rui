"""Exact-artifact modified-key acceptance with an ordered rejection oracle.

Only synthetic input and private tmux clients are used. The exact55 negative
control must fail on rejection, rather than setup or the marker-at-caret check.
"""
import argparse
import importlib.util
import json
import pathlib
import subprocess
import time
import traceback

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('meta_probe', HERE / 'meta-origin-probe.py')
meta = importlib.util.module_from_spec(spec)
spec.loader.exec_module(meta)
prior, helper = meta.prior, meta.helper

CONTROLS = {
    'bound-alt-b': 'alpha Zbeta', 'bound-alt-f': 'alphaZ beta',
    'bound-alt-backspace': 'alpha Z', 'bound-alt-left': 'alpha Zbeta',
    'bound-alt-right': 'alphaZ beta', 'bound-alt-j': 'alpha beta\nZ',
    'plain-dot-space': '. Z', 'marked-paste': 'plain . space\nmoreZ',
}


def draft_rows(frame, expected):
    lines = ['› ' + expected.split('\n')[0]] + ['  ' + line for line in expected.split('\n')[1:]]
    y = frame['cursor'][1]
    return frame['screen'].splitlines()[y - len(lines) + 1:y + 1] == lines


class FixedProbe(meta.Probe):
    @staticmethod
    def draft(frame):
        lines = frame['screen'].splitlines()
        y = frame['cursor'][1]
        return lines[y].rstrip() if y < len(lines) else ''

    def close(self):
        self.send(b'\x03', 'tmux')
        deadline = time.monotonic() + 10
        while not (self.term / 'exit.json').exists() and time.monotonic() < deadline:
            time.sleep(.025)
        exited = json.loads((self.term / 'exit.json').read_text())
        assert exited['target_rc'] == '0' and exited['termios_restored']
        assert exited['alternate_screen_active_at_exit'] is False
        return exited

    def execute(self, selected):
        rows = []
        routes = ['client', 'tmux'] if self.surface == 'tmux-attached' else ['tmux']
        for via in routes:
            for number, (label, payload, seed, kind) in enumerate(meta.CASES):
                if selected and label not in selected:
                    continue
                if via == 'tmux' and self.surface == 'tmux-attached' and kind != 'unbound':
                    continue
                row = {'surface': self.surface, 'via': via, 'case': label, 'kind': kind, 'passed': False}
                opened = False
                baseline = 0
                try:
                    self.start(f'{via}-{number}')
                    opened = True
                    self.wait(lambda f: 'Fixture answer 3:' in f['screen'] and self.draft(f) == '›')
                    if seed:
                        self.ordered_draft(seed, '› ' + seed.decode(), label + '-seed', via)
                    before_provider = helper.read_jsonl(self.run.evidence / 'provider.jsonl')
                    row['provider_before'] = before_provider
                    baseline = (self.term / 'input.bin').stat().st_size
                    before = self.latest()
                    row['injection'] = self.send(payload, via)
                    self.marker = self.send(b'Z', via)
                    row['marker'] = self.marker
                    unsupported_raw = label.startswith('modifyOtherKeys') and via == 'tmux'
                    if kind == 'unbound' and not unsupported_raw:
                        # Rejection deliberately suppresses subsequent draft keys.
                        # Enter is an ordered visible witness of that rejection;
                        # a pre-input empty composer cannot satisfy this oracle.
                        row['reset'] = self.send(b'\r', via)
                        rejected = self.wait(lambda f: '! Input rejected; nothing sent.' in f['screen']
                                             and self.draft(f) == '›'
                                             and f['t_ns'] >= row['reset']['t_ns'], before['gen'])
                        row['rejection_frame'] = rejected
                        row['recovery'] = self.send(b'Q', via)
                        row['frame'] = self.wait(lambda f: draft_rows(f, 'Q')
                                                and f['t_ns'] >= row['recovery']['t_ns'], rejected['gen'])
                        row['expected'] = 'reject, no submission, then fresh Q'
                    else:
                        self.barrier(baseline, b'Z', False)
                        expected = 'Z' if unsupported_raw else CONTROLS[label]
                        row['frame'] = self.latest()
                        assert draft_rows(row['frame'], expected), (label, row['frame'], expected)
                        row['expected'] = expected
                    row['delivered_hex'] = (self.term / 'input.bin').read_bytes()[baseline:].hex()
                    row['provider_after'] = helper.read_jsonl(self.run.evidence / 'provider.jsonl')
                    assert row['provider_after'] == before_provider, 'input unexpectedly reached provider'
                    row['passed'] = True
                except BaseException:
                    row['failure'] = traceback.format_exc()
                    row['last_frame'] = self.latest()
                    row['provider_after'] = helper.read_jsonl(self.run.evidence / 'provider.jsonl')
                    if opened:
                        row['delivered_hex'] = (self.term / 'input.bin').read_bytes()[baseline:].hex()
                finally:
                    if opened:
                        try:
                            row['exit'] = self.close()
                        except BaseException:
                            row['cleanup_failure'] = traceback.format_exc()
                            row['passed'] = False
                    rows.append(row)
                    helper.append_jsonl(prior.OUT / 'rows.jsonl', row)
                    print(json.dumps({k: row.get(k) for k in ('surface', 'via', 'case', 'passed', 'expected', 'failure')}), flush=True)
        return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--sha', required=True)
    parser.add_argument('--surface', action='append', choices=('tmux-attached', 'tmux-detached'))
    parser.add_argument('--case', action='append')
    parser.add_argument('--negative-control', action='store_true')
    args = parser.parse_args()
    build = helper.load_build(args.sha)
    source, binary = pathlib.Path(build['source']), pathlib.Path(build['binary'])
    assert subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip() == args.sha
    assert not subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain', '--untracked-files=no'], text=True).strip()
    assert prior.digest(binary) == build['files_sha256']['rui']
    prior.BASE, prior.DIAG = args.sha, binary
    prior.OUT = HERE / 'meta-fixed' / args.sha
    prior.OUT.mkdir(parents=True, exist_ok=False)
    summary = {'sha': args.sha, 'binary': str(binary), 'binary_sha256': prior.digest(binary),
               'helper_sha256': prior.digest(prior.HELPER), 'driver_sha256': prior.digest(pathlib.Path(__file__)),
               'negative_control': args.negative_control, 'instrumented': False, 'surfaces': []}
    for surface in args.surface or ('tmux-detached', 'tmux-attached'):
        probe = None
        result = {'surface': surface, 'completed': False}
        try:
            probe = FixedProbe(surface)
            result['run'] = str(probe.run_path)
            prior.call('doctor', probe.run_path, '--expect-sha', args.sha)
            result['rows'] = probe.execute(args.case)
            result['completed'] = True
        except BaseException:
            result['failure'] = traceback.format_exc()
        finally:
            if probe:
                try:
                    result['cleanup'] = prior.call('cleanup', probe.run_path)
                except BaseException:
                    result['cleanup_error'] = traceback.format_exc()
            summary['surfaces'].append(result)
            (prior.OUT / 'summary.json').write_text(json.dumps(summary, indent=1))
    rows = [r for s in summary['surfaces'] for r in s.get('rows', [])]
    assert all(s['completed'] and 'cleanup_error' not in s for s in summary['surfaces']), summary
    assert rows and not any('cleanup_failure' in r for r in rows)
    if args.negative_control:
        assert all(not r['passed'] and 'rejected = self.wait' in r['failure']
                   and len(r['provider_after']) > len(r['provider_before']) for r in rows), rows
        summary['verdict'] = 'EXPECTED_RED: bare key submitted instead of rejection'
    else:
        assert all(r['passed'] for r in rows), prior.OUT / 'summary.json'
        summary['verdict'] = 'PASS'
    (prior.OUT / 'summary.json').write_text(json.dumps(summary, indent=1))
    print(json.dumps({'verdict': summary['verdict'], 'rows': len(rows), 'evidence': str(prior.OUT)}))


if __name__ == '__main__':
    main()
