"""Synthetic-only diagnostic; instrumented binary is never qualification evidence."""
import argparse
import ast
import hashlib
import importlib.machinery
import importlib.util
import json
import os
import pathlib
import re
import subprocess
import sys
import termios
import time
import traceback

ROOT = pathlib.Path(__file__).resolve().parents[4]
OUT = pathlib.Path(__file__).resolve().parent
HELPER = ROOT / '.cursor/skills/verify-rui/scripts/verify-rui'
BASE = '55bfd65b43ac240223283e4f35312eba5f44012a'
CACHE = ROOT / '.amp/in/prefix-diagnosis-cache'
DIAG = ROOT / '.amp/in/prefix-diagnostic-source/zig-out/bin/rui'
PYTHON = CACHE / 'venv/bin/python'
os.environ['VERIFY_RUI_CACHE'] = str(CACHE)
os.environ['PYTHONDONTWRITEBYTECODE'] = '1'
loader = importlib.machinery.SourceFileLoader('prefix_verify', str(HELPER))
spec = importlib.util.spec_from_loader(loader.name, loader)
helper = importlib.util.module_from_spec(spec)
loader.exec_module(helper)


def digest(p):
    with open(p, 'rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def call(*args):
    result = subprocess.run([str(PYTHON), str(HELPER), *map(str, args)],
                            capture_output=True, text=True, start_new_session=True, timeout=120)
    helper.append_jsonl(OUT / 'prefix-driver-commands.jsonl', {
        't_ns': time.monotonic_ns(), 'args': list(map(str, args)),
        'rc': result.returncode, 'out': result.stdout, 'err': result.stderr})
    if result.returncode:
        raise RuntimeError(f'{args}: rc={result.returncode}: {result.stdout} {result.stderr}')
    return result.stdout


class Probe:
    def __init__(self, surface):
        self.surface = surface
        self.run_path = pathlib.Path(call('new', BASE, '--seed', '3', '--label', 'prefix-' + surface).strip())
        self.run = helper.Run(self.run_path)
        self.name = 'p'
        self.results = []
        helper.append_jsonl(OUT / 'prefix-runs.jsonl', {'surface': surface, 'run': str(self.run_path)})

    @property
    def term(self):
        return self.run.term_dir(self.name)

    def frames(self):
        return helper.read_jsonl(self.term / 'frames.jsonl')

    def latest(self):
        fs = self.frames()
        return fs[-1] if fs else {'gen': 0, 't_ns': 0, 'screen': '', 'cursor': [0, 0]}

    def wait(self, predicate, after=0):
        end = time.monotonic() + 12
        while time.monotonic() < end:
            for f in self.frames():
                if f['gen'] > after and predicate(f):
                    return f
            if (self.term / 'exit.json').exists():
                raise RuntimeError('Rui exited before effect: ' + (self.term / 'exit.json').read_text())
            time.sleep(.025)
        raise TimeoutError(str(self.latest()))

    @staticmethod
    def draft(f):
        return f['screen'].splitlines()[f['cursor'][1]].rstrip()

    def send(self, payload, via=None):
        args = ('--via', via) if via else ()
        return json.loads(call('send', self.run_path, self.name, '--hex', payload.hex(), *args))

    def start(self, name):
        self.name = name
        trace = self.run_path / f'{name}-parser-editor.log'
        # Only this diagnostic invocation's stderr goes to the synthetic trace.
        argv = ['/bin/sh', '-c', 'exec "$@" 2>"$PREFIX_TRACE"', 'prefix-diagnostic',
                str(DIAG), 'session', 'resume', '--store', str(self.run.store), '--', 'demo']
        wrapper = self.run_path / f'{name}-wrapper.sh'
        wrapper.write_text('#!/bin/sh\nPREFIX_TRACE=' + str(trace) + '\nexport PREFIX_TRACE\nexec ' +
                           __import__('shlex').join(argv) + '\n')
        # Match the helper CLI's launcher lifetime: the tap must not become
        # this driver's unreaped child during the helper's liveness cleanup.
        subprocess.run([str(PYTHON), __file__, '_term', str(self.run_path), name,
                        self.surface, str(wrapper)], check=True, start_new_session=True, timeout=30)
        f = self.wait(lambda f: self.draft(f) == '›')
        self.note('fresh-composer', frame=f)
        return f

    def note(self, label, **facts):
        record = {'surface': self.surface, 'terminal': self.name, 'label': label, **facts}
        self.results.append(record)
        helper.append_jsonl(OUT / 'prefix-observations.jsonl', record)
        print(self.surface, label, {k: v for k, v in facts.items() if k != 'frame'}, flush=True)

    def ordered_draft(self, payload, expected, label, via=None):
        before = self.latest()
        start_offset = (self.term / 'input.bin').stat().st_size
        inj = self.send(payload, via)
        f = self.wait(lambda f: self.draft(f) == expected and f['t_ns'] >= inj['t_ns'], before['gen'])
        received = (self.term / 'input.bin').read_bytes()[start_offset:]
        self.note(label, input=inj, received_hex=received.hex(), frame=f)
        return f

    def execute(self):
        self.start('p')
        # Recreate the pre-/status navigation using no printable prefix.
        self.send(b'\x1b[A' * 5)
        self.send(b'\x1b[B' * 5)
        self.send(b'\x1b[5~')
        self.ordered_draft(b'\x07z', '› z', 'navigation-no-dot')
        packets = [
            ('x10-dot', b'\x1b[M ..'),
            ('x10-is', b'\x1b[M is'),
            ('sgr-dot-coordinates', b'\x1b[<0;14;14M\x1b[<0;14;14m'),
            ('focus', b'\x1b[I\x1b[O'),
            ('width-scroll-replies', b'\x1b[?2027;0$y\x1b[?1007;0$y'),
            ('kitty-dot-release', b'\x1b[46;1:3u'),
            ('unhandled-csi', b'\x1b[999~'),
        ]
        for label, payload in packets:
            before = self.latest()
            offset = (self.term / 'input.bin').stat().st_size
            via = 'client' if self.surface == 'tmux-attached' else 'tmux'
            injection = self.send(payload, via)
            sentinel = self.send(b'q', via)
            f = self.wait(lambda f: self.draft(f) == '› zq' and f['t_ns'] >= sentinel['t_ns'], before['gen'])
            self.note(label, input=injection,
                      received_hex=(self.term / 'input.bin').read_bytes()[offset:].hex(), frame=f)
            self.ordered_draft(b'\x7f', '› z', label + '-reset')
        # Also force reports into the attached pane so tmux filtering is not
        # mistaken for successful parsing by Rui.
        self.ordered_draft(b'\x1b[M ..\x1b[M is\x1b[I\x1b[Oq', '› zq', 'pane-direct-reports')
        self.ordered_draft(b'\x15/status\r', '›', 'clean-status-dispatch')
        self.wait(lambda f: 'Session: demo' in f['screen'] and 'Work:' in f['screen'])
        self.ordered_draft(b'\x07', '›', 'leave-status')
        # A positive control: a real encoded dot *key*, without a literal dot
        # in the injected bytes, must insert a dot. This is not a mouse/reply.
        via = 'client' if self.surface == 'tmux-attached' else 'tmux'
        self.ordered_draft(b'\x1b[46;1;46u', '› .', 'encoded-dot-positive', via)
        self.send(b'\x1b[5~')
        self.ordered_draft(b'\x07', '› .', 'navigation-retains-known-dot')
        before = self.latest()
        self.send(b' /status\r')
        self.wait(lambda f: 'received \\". /status\\"' in f['screen'] or
                            'received ". /status"' in f['screen'], before['gen'])
        provider = [r for r in helper.read_jsonl(self.run.evidence / 'provider.jsonl') if 'kind' in r]
        assert provider[-1]['user_text'] == '. /status', provider[-1]
        self.note('known-dot-turns-status-into-message', provider=provider[-1], frame=self.latest())
        # Draft retention while one invocation lives versus resume from Store.
        self.ordered_draft(b'.', '› .', 'draft-before-exit')
        self.send(b'\x03')
        end = time.monotonic() + 10
        while not (self.term / 'exit.json').exists() and time.monotonic() < end:
            time.sleep(.05)
        assert (self.term / 'exit.json').exists()
        self.start('reopened')
        self.note('same-store-resume-does-not-restore-dot', frame=self.latest())
        self.send(b'/exit\r')

    def verify_chain(self):
        for term in ('p', 'reopened'):
            trace = self.run_path / f'{term}-parser-editor.log'
            text = trace.read_text()
            parser = bytes(int(x, 16) for x in re.findall(r'PFX stage=before t=\d+ byte=([0-9a-f]+)', text))
            tap = (self.run.term_dir(term) / 'input.bin').read_bytes()
            meta = json.loads((self.run.term_dir(term) / 'meta.json').read_text())
            flags = ast.literal_eval(meta['attrs_before'])[0]
            # Rui preserves the inherited ICRNL. A tap records writes to the
            # PTY master; the kernel maps CR to LF before Rui reads fd 0.
            assert flags & termios.ICRNL and not flags & (termios.IGNCR | termios.INLCR | termios.ISTRIP)
            assert parser == tap.replace(b'\r', b'\n'), (term, parser.hex(), tap.hex())
            self.note('tap-to-parser-icrnl-chain', term=term, bytes=len(tap),
                      icrnl_offsets=[i for i, b in enumerate(tap) if b == 13],
                      input_sha256=digest(self.run.term_dir(term) / 'input.bin'),
                      parser_trace_sha256=digest(trace))


def main():
    summary = {'base': BASE, 'diagnostic_binary_sha256': digest(DIAG),
               'helper_sha256': digest(HELPER), 'qualification': False, 'surfaces': []}
    for surface in ('tmux-detached', 'tmux-attached'):
        probe = None
        result = {'surface': surface, 'completed': False}
        try:
            probe = Probe(surface)
            result['run'] = str(probe.run_path)
            call('doctor', probe.run_path, '--expect-sha', BASE)
            probe.execute()
            probe.verify_chain()
            result['completed'] = True
        except BaseException:
            result['failure'] = traceback.format_exc()
            print(result['failure'], flush=True)
        finally:
            if probe:
                try:
                    result['cleanup'] = call('cleanup', probe.run_path)
                except BaseException:
                    result['cleanup_error'] = traceback.format_exc()
            summary['surfaces'].append(result)
            (OUT / 'prefix-chain-summary.json').write_text(json.dumps(summary, indent=1))
    assert all(s['completed'] and 'cleanup_error' not in s for s in summary['surfaces']), summary


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '_term':
        _, _, run, name, surface, wrapper = sys.argv
        helper.cmd_term(argparse.Namespace(run=run, name=name, session='demo',
            surface=surface, size='100x30', no_tap=False, argv=['/bin/sh', wrapper]))
    else:
        main()
