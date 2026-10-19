"""Modified-key diagnostics on owned synthetic tmux; never physical evidence."""
import argparse
import importlib.util
import json
import os
import pathlib
import re
import subprocess
import sys
import time
import traceback

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('prefix_probe', HERE / 'prefix-chain-probe.py')
prior = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prior)
OUT = HERE / 'meta-origin'
prior.OUT = OUT
helper = prior.helper

CASES = [
    ('meta-dot', b'\x1b.', b'', 'unbound'),
    ('meta-space', b'\x1b ', b'', 'unbound'),
    ('meta-i', b'\x1bi', b'', 'unbound'),
    ('meta-s', b'\x1bs', b'', 'unbound'),
    ('meta-semicolon', b'\x1b;', b'', 'unbound'),
    ('kitty-alt-dot', b'\x1b[46;3u', b'', 'unbound'),
    ('kitty-alt-dot-text', b'\x1b[46;3;46u', b'', 'unbound'),
    ('kitty-alt-space-text', b'\x1b[32;3;32u', b'', 'unbound'),
    ('modifyOtherKeys-alt-dot', b'\x1b[27;3;46~', b'', 'unbound'),
    ('modifyOtherKeys-alt-space', b'\x1b[27;3;32~', b'', 'unbound'),
    ('bound-alt-b', b'\x1bb', b'alpha beta', 'bound'),
    ('bound-alt-f', b'\x01\x1bf', b'alpha beta', 'bound'),
    ('bound-alt-backspace', b'\x1b\x7f', b'alpha beta', 'bound'),
    ('bound-alt-left', b'\x1b[1;3D', b'alpha beta', 'bound'),
    ('bound-alt-right', b'\x01\x1b[1;3C', b'alpha beta', 'bound'),
    ('bound-alt-j', b'\x1bj', b'alpha beta', 'bound'),
    ('plain-dot-space', b'. ', b'', 'plain'),
    ('marked-paste', b'\x1b[200~plain . space\nmore\x1b[201~', b'', 'paste'),
]


class Probe(prior.Probe):
    def trace(self):
        path = self.run_path / f'{self.name}-parser-editor.log'
        return path.read_text() if path.exists() else ''

    @staticmethod
    def marker_visible(frame, marker):
        x, y = frame['cursor']
        lines = frame['screen'].splitlines()
        return y < len(lines) and 0 < x <= len(lines[y]) and lines[y][x - 1] == marker.decode()

    def barrier(self, baseline, marker, instrumented):
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            data = (self.term / 'input.bin').read_bytes()
            if instrumented:
                log = self.trace()
                ingress = bytes(int(x, 16) for x in re.findall(r'PFX stage=before t=\d+ byte=([0-9a-f]+)', log))
                after = re.findall(r'PFX stage=after t=\d+ byte=([0-9a-f]+)', log)
                if (len(data) > baseline and data.endswith(marker) and
                        ingress == data.replace(b'\r', b'\n') and len(after) == len(ingress)):
                    return
            else:
                frames = [f for f in self.frames() if f['t_ns'] >= self.marker['t_ns']]
                # Bound word motion puts the marker inside an existing draft.
                # Observe the cell immediately before its post-input caret,
                # rather than incorrectly requiring it at the end of the row.
                if data[baseline:].endswith(marker) and any(self.marker_visible(f, marker) for f in frames):
                    return
            time.sleep(.015)
        raise TimeoutError({'trace': self.trace()[-3000:], 'frame': self.latest(), 'baseline': baseline})

    def execute_cases(self, instrumented):
        rows = []
        routes = ['client', 'tmux'] if self.surface == 'tmux-attached' else ['tmux']
        for via in routes:
            for number, (label, payload, seed, kind) in enumerate(CASES):
                if via == 'tmux' and self.surface == 'tmux-attached' and kind != 'unbound':
                    continue
                self.start(f'{via}-{number}')
                if seed:
                    self.ordered_draft(seed, '› ' + seed.decode(), label + '-seed', via)
                baseline = (self.term / 'input.bin').stat().st_size
                trace_offset = len(self.trace())
                before = self.latest()
                injection = self.send(payload, via)
                self.marker = self.send(b'Z', via)
                self.barrier(baseline, b'Z', instrumented)
                # The parser trace is an ordered processing witness. It is not
                # replaced with a sleep or a pre-input frame for ignored keys.
                trace = self.trace()[trace_offset:]
                delivered = (self.term / 'input.bin').read_bytes()[baseline:]
                transitions = re.findall(r'PFX stage=after t=(\d+) byte=([0-9a-f]+).*? draft=([0-9a-f]*) cursor=(\d+)', trace)
                row = {'surface': self.surface, 'via': via, 'case': label, 'kind': kind,
                       'terminal': self.name, 'injected_hex': payload.hex(), 'marker_hex': '5a',
                       'injection': injection, 'marker': self.marker, 'delivered_hex': delivered.hex(),
                       'before_frame': before, 'latest_frame': self.latest(),
                       'decoded': [line for line in trace.splitlines() if line.startswith('PFX decoded=')],
                       'transitions': [{'t': t, 'byte': byte, 'draft_hex': draft, 'cursor': int(cursor)}
                                       for t, byte, draft, cursor in transitions],
                       'diagnostic_only': instrumented}
                if transitions:
                    row['final_draft_hex'] = transitions[-1][2]
                if kind == 'unbound' and instrumented:
                    row['decoded_alt_observed'] = any('.alt = true' in line for line in row['decoded'])
                    row['bare_character_inserted'] = row['decoded_alt_observed'] and row.get('final_draft_hex') not in ('', '5a')
                helper.append_jsonl(OUT / 'observations.jsonl', row)
                rows.append(row)
                print(json.dumps({k: row.get(k) for k in ('surface', 'via', 'case', 'delivered_hex',
                                 'final_draft_hex', 'decoded_alt_observed', 'bare_character_inserted') }), flush=True)
                self.send(b'\x03', 'tmux')
                end = time.monotonic() + 10
                while not (self.term / 'exit.json').exists() and time.monotonic() < end:
                    time.sleep(.025)
                assert (self.term / 'exit.json').exists(), self.name
        return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=pathlib.Path, default=prior.DIAG)
    parser.add_argument('--untouched', action='store_true')
    parser.add_argument('--surface', action='append', choices=('tmux-detached', 'tmux-attached'))
    args = parser.parse_args()
    prior.DIAG = args.binary.resolve()
    results = {'base_sha': prior.BASE, 'binary': str(prior.DIAG), 'binary_sha256': prior.digest(prior.DIAG),
               'helper_sha256': prior.digest(prior.HELPER), 'diagnostic_only': not args.untouched, 'surfaces': []}
    output = OUT / ('untouched-summary.json' if args.untouched else 'diagnostic-summary.json')
    for surface in args.surface or ('tmux-detached', 'tmux-attached'):
        probe = None
        result = {'surface': surface, 'completed': False}
        try:
            probe = Probe(surface)
            result['run'] = str(probe.run_path)
            prior.call('doctor', probe.run_path, '--expect-sha', prior.BASE)
            result['rows'] = probe.execute_cases(not args.untouched)
            result['completed'] = True
        except BaseException:
            result['failure'] = traceback.format_exc()
            print(result['failure'], flush=True)
        finally:
            if probe:
                try:
                    result['cleanup'] = prior.call('cleanup', probe.run_path)
                except BaseException:
                    result['cleanup_error'] = traceback.format_exc()
            results['surfaces'].append(result)
            output.write_text(json.dumps(results, indent=1))
    assert all(s['completed'] and 'cleanup_error' not in s for s in results['surfaces']), output


if __name__ == '__main__':
    main()
