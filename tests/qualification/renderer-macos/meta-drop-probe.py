"""New-contract scratch oracle. Never inherits rejection-at-Enter acceptance."""
import argparse
import importlib.util
import json
import pathlib
import subprocess
import time
import traceback

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('fixed_probe', HERE / 'meta-fixed-probe.py')
fixed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixed)
meta, prior, helper = fixed.meta, fixed.prior, fixed.helper
NOTICE = '! Key combination not recognized; ignored. Draft unchanged.'
CASES = meta.CASES + [
    ('kitty-super-dot', b'\x1b[46;9u', b'', 'unbound'),
    ('kitty-hyper-dot', b'\x1b[46;17u', b'', 'unbound'),
    ('kitty-meta-dot', b'\x1b[46;33u', b'', 'unbound'),
    ('kitty-alt-up', b'\x1b[1;3A', b'', 'unbound'),
    ('meta-enter-esc-cr', b'\x1b\r', b'', 'unbound'),
    ('meta-enter-esc-lf', b'\x1b\n', b'', 'unbound'),
    ('kitty-alt-enter', b'\x1b[13;3u', b'', 'unbound'),
    ('kitty-alt-enter-text', b'\x1b[13;3;13u', b'', 'unbound'),
    ('tmux-m-enter', b'', b'', 'unbound'),
    ('bound-shift-enter', b'\x1b[13;2u', b'alpha beta', 'bound'),
    ('ctrl-x', b'\x18', b'', 'ctrl'),
    ('kitty-alt-c0', b'\x1b[28;3u', b'', 'unbound'),
    ('esc-nul', b'\x1b\x00', b'', 'unbound'),
    ('incomplete-csi-enter', b'\x1b[', b'', 'partial'),
    ('bound-alt-backspace-h', b'\x1b\x08', b'first second', 'bound'),
    ('ordinary-backspace-h', b'\x08', b'first second', 'bound'),
    ('ordinary-backspace-del', b'\x7f', b'first second', 'bound'),
    ('meta-unicode-e-acute', b'\x1b\xc3\xa9', b'', 'unbound'),
    ('double-esc-marked-paste', b'\x1b\x1b[200~first\nsecond\x1b[201~', b'keep:', 'paste'),
    ('double-esc-csi-up', b'\x1b\x1b[A', b'keep-arrow', 'bound'),
    ('double-esc-ss3-up', b'\x1b\x1bOA', b'keep-ss3', 'bound'),
    ('triple-esc-dot', b'\x1b\x1b\x1b.', b'', 'unbound'),
    ('double-esc-alone', b'\x1b\x1b', b'keep-escape', 'close_view'),
]
CONTROLS = {
    **fixed.CONTROLS, 'bound-shift-enter': 'alpha beta\nZ',
    'bound-alt-backspace-h': 'first Z',
    'ordinary-backspace-h': 'first seconZ',
    'ordinary-backspace-del': 'first seconZ',
    'double-esc-marked-paste': 'keep:first\nsecondZ',
    'double-esc-csi-up': 'keep-arrowZ',
    'double-esc-ss3-up': 'keep-ss3Z',
}


def same_draft_caret(before, after, seed):
    # These ASCII, single-line seeds do not wrap. The notice may move the
    # composer vertically; draft text and relative caret column must stay.
    assert seed.isascii() and '\n' not in seed and len(seed) + 2 < 100
    return (fixed.draft_rows(before, seed) and fixed.draft_rows(after, seed)
            and after['cursor'][0] == before['cursor'][0])


class DropProbe(fixed.FixedProbe):
    def provider(self):
        return [r for r in helper.read_jsonl(self.run.evidence / 'provider.jsonl') if 'kind' in r]

    def send_named_meta_enter(self):
        target = helper.term_record(self.run, self.name)['tmux_target']
        argv = ['send-keys', '-t', target, 'M-Enter']
        record = {'t_ns': time.monotonic_ns(), 'term': self.name, 'via': 'tmux',
                  'input_kind': 'tmux named key', 'tmux_argv': argv}
        self.run.tmux(*argv)
        record['t_end_ns'] = time.monotonic_ns()
        # Do not claim an encoding for M-Enter. The owned PTY tap records it.
        helper.append_jsonl(self.run.evidence / 'injections.jsonl', record)
        return record

    def submit_exact(self, row, expected, via):
        row['enter'] = self.send(b'\r', via)
        if row['kind'] == 'partial':
            row['cr_injection_delay_ns'] = row['enter']['t_end_ns'] - row['injection']['t_ns']
            assert 0 <= row['cr_injection_delay_ns'] < 2_000_000_000, 'CR exceeded incomplete-input deadline'
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            records = self.provider()[len(row['provider_before']):]
            if records:
                assert len(records) == 1 and records[0]['user_text'] == expected, records
                break
            time.sleep(.025)
        else:
            raise TimeoutError('seeded draft never submitted')
        marker = f"Fixture answer {records[0]['n']}:"
        row['answer_frame'] = self.wait(lambda f: marker in f['screen'] and self.draft(f) == '›'
                                      and f['t_ns'] >= row['enter']['t_ns'])
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            result = self.run.rui_cmd('session', 'inspect', '--store', self.run.store, '--session', 'demo')
            assert result.returncode == 0, result.stderr
            state = json.loads(result.stdout).get('work', {}).get('status')
            if state == 'completed':
                break
            time.sleep(.05)
        assert state == 'completed', state
        row['settled_work'] = state
        row['provider_after'] = self.provider()
        submitted = row['provider_after'][len(row['provider_before']):]
        assert len(submitted) == 1 and submitted[0]['user_text'] == expected, submitted
        row['submitted_utf8_hex'] = submitted[0]['user_text'].encode().hex()

    def execute(self, selected):
        rows = []
        routes = ['client', 'tmux'] if self.surface == 'tmux-attached' else ['tmux']
        for via in routes:
            for number, (label, payload, seed, kind) in enumerate(CASES):
                if selected and label not in selected:
                    continue
                if label == 'tmux-m-enter' and via != 'tmux':
                    continue
                if via == 'tmux' and self.surface == 'tmux-attached' and kind not in ('unbound', 'ctrl'):
                    continue
                row = {'surface': self.surface, 'via': via, 'case': label, 'kind': kind, 'passed': False}
                opened, baseline = False, 0
                try:
                    self.start(f'{via}-{number}')
                    opened = True
                    self.wait(lambda f: 'Fixture answer' in f['screen'] and self.draft(f) == '›')
                    if kind in ('unbound', 'ctrl', 'partial'):
                        seed = ('keep-' + label).encode()
                    if seed:
                        self.ordered_draft(seed, '› ' + seed.decode(), label + '-seed', via)
                    if kind in ('unbound', 'close_view'):
                        seeded = self.latest()
                        moved = self.send(b'\x1b[D\x1b[D', via)
                        self.wait(lambda f: f['cursor'] == [seeded['cursor'][0] - 2, seeded['cursor'][1]]
                                  and f['t_ns'] >= moved['t_ns'], seeded['gen'])
                    if kind == 'close_view':
                        browsing = self.send(b'\x1b[5~', via)
                        row['browsing_frame'] = self.wait(
                            lambda f: f['screen'].startswith('Browsing · Esc returns')
                            and fixed.draft_rows(f, seed.decode()) and f['t_ns'] >= browsing['t_ns'])
                    row['seed_utf8_hex'] = seed.hex()
                    row['provider_before'] = self.provider()
                    baseline = (self.term / 'input.bin').stat().st_size
                    before = self.latest()
                    row['before_frame'] = before
                    row['injection'] = self.send_named_meta_enter() if label == 'tmux-m-enter' else self.send(payload, via)
                    raw_framing = label.startswith('modifyOtherKeys') and via == 'tmux'
                    if kind == 'unbound' and not raw_framing:
                        # No marker or Enter may manufacture a post-chord frame.
                        row['ignored_frame'] = self.wait(
                            lambda f: NOTICE in f['screen'] and same_draft_caret(before, f, seed.decode())
                            and f['t_ns'] >= row['injection']['t_ns'], before['gen'])
                        row['provider_before_enter'] = self.provider()
                        assert row['provider_before_enter'] == row['provider_before']
                        row['delivered_before_enter_hex'] = (self.term / 'input.bin').read_bytes()[baseline:].hex()
                        assert row['delivered_before_enter_hex'], 'no chord delivered to pane'
                        row['expected'] = seed.decode()
                        self.submit_exact(row, row['expected'], via)
                    elif kind == 'partial':
                        row['expected'] = seed.decode()
                        self.submit_exact(row, row['expected'], via)
                        chunks = helper.read_jsonl(self.term / 'input.jsonl')
                        prefix = next(c for c in chunks if c['offset'] <= baseline < c['offset'] + c['n'])
                        end = baseline + len(payload)
                        enter = next(c for c in chunks if c['offset'] <= end < c['offset'] + c['n'])
                        row['cr_delivered_delay_ns'] = enter['t_ns'] - prefix['t_ns']
                        assert 0 <= row['cr_delivered_delay_ns'] < 2_000_000_000
                        assert (self.term / 'input.bin').read_bytes()[baseline:end + 1] == payload + b'\r'
                    elif kind == 'ctrl':
                        row['enter'] = self.send(b'\r', via)
                        row['rejected_frame'] = self.wait(
                            lambda f: '! Input rejected; nothing sent.' in f['screen'] and self.draft(f) == '›'
                            and f['t_ns'] >= row['enter']['t_ns'], before['gen'])
                        row['recovery'] = self.send(b'Q', via)
                        row['frame'] = self.wait(lambda f: fixed.draft_rows(f, 'Q')
                                                and f['t_ns'] >= row['recovery']['t_ns'])
                        row['provider_after'] = self.provider()
                        assert row['provider_after'] == row['provider_before']
                    else:
                        if kind == 'close_view':
                            row['escaped_frame'] = self.wait(
                                lambda f: not f['screen'].startswith('Browsing')
                                and NOTICE not in f['screen'] and same_draft_caret(before, f, seed.decode())
                                and f['t_ns'] >= row['injection']['t_ns'], before['gen'])
                            # A later printable control must not become an Alt
                            # chord left pending beyond the 80 ms Esc deadline.
                            time.sleep(.12)
                        self.marker = self.send(b'Z', via)
                        row['marker'] = self.marker
                        if kind == 'close_view':
                            row['marker_delay_ns'] = self.marker['t_ns'] - row['injection']['t_end_ns']
                            assert row['marker_delay_ns'] >= 80_000_000
                        self.barrier(baseline, b'Z', False)
                        row['expected'] = seed.decode()[:-2] + 'Z' + seed.decode()[-2:] if raw_framing or kind == 'close_view' else CONTROLS[label]
                        row['frame'] = self.latest()
                        assert fixed.draft_rows(row['frame'], row['expected']), row
                        if kind == 'close_view':
                            assert NOTICE not in row['frame']['screen'], row
                        row['raw_framing_only'] = raw_framing
                        # Raw unsupported framing is not decoded-chord acceptance.
                        assert self.provider() == row['provider_before']
                        self.submit_exact(row, row['expected'], via)
                    row['passed'] = True
                except BaseException:
                    row['failure'] = traceback.format_exc()
                    row['last_frame'] = self.latest()
                    row['provider_after'] = self.provider()
                finally:
                    if opened:
                        row['delivered_hex'] = (self.term / 'input.bin').read_bytes()[baseline:].hex()
                        try:
                            row['exit'] = self.close()
                        except BaseException:
                            row['cleanup_failure'] = traceback.format_exc()
                            row['passed'] = False
                    rows.append(row)
                    helper.append_jsonl(prior.OUT / 'rows.jsonl', row)
                    print(json.dumps({k: row.get(k) for k in ('surface', 'via', 'case', 'passed', 'expected', 'failure')}), flush=True)
                if not row['passed']:
                    return rows
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
    prior.OUT = HERE / 'meta-drop-geometry-corrected' / args.sha
    prior.OUT.mkdir(parents=True, exist_ok=False)
    summary = {'sha': args.sha, 'binary_sha256': prior.digest(binary),
               'helper_sha256': prior.digest(prior.HELPER), 'driver_sha256': prior.digest(pathlib.Path(__file__)),
               'contract': 'immediate drop; notice; preserve draft; Enter submits exact draft',
               'negative_control': args.negative_control, 'instrumented': False, 'surfaces': []}
    for surface in args.surface or ('tmux-detached', 'tmux-attached'):
        probe = None
        result = {'surface': surface, 'completed': False}
        try:
            probe = DropProbe(surface)
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
        if not result['completed'] or any(not r['passed'] for r in result.get('rows', [])):
            break
    rows = [r for s in summary['surfaces'] for r in s.get('rows', [])]
    assert all(s['completed'] and 'cleanup_error' not in s for s in summary['surfaces']), summary
    assert rows and not any('cleanup_failure' in r for r in rows)
    if args.negative_control:
        assert all(not r['passed'] and "row['ignored_frame'] = self.wait" in r['failure']
                   and r['provider_before'] == r['provider_after'] for r in rows), rows
        summary['verdict'] = 'EXPECTED_RED: immediate ignored notice/preserved draft absent'
    else:
        assert all(r['passed'] for r in rows), prior.OUT / 'summary.json'
        summary['verdict'] = 'PASS'
    (prior.OUT / 'summary.json').write_text(json.dumps(summary, indent=1))
    print(json.dumps({'verdict': summary['verdict'], 'rows': len(rows), 'evidence': str(prior.OUT)}))


if __name__ == '__main__':
    main()
