#!/usr/bin/env python3
"""Opt-in Linux/native PTY + pyte cell/scrollback regression (not check-full).

From the repository root, with a current ReleaseSafe executable:
  uv run --with pyte==0.8.2 python tests/integration/session_terminal_integration.py zig-out/bin/rui
Select isolated experiments with --case presentation|proposal|display|flag|resize|approval|held|lost|rejection|backpressure.
For red-before evidence use the read-only executable:
  uv run --with pyte==0.8.2 python tests/integration/session_terminal_integration.py .amp/data/session-view/before-input-correction --case rejection

Emulator history is bounded to 4096 rows; UTF-8 is decoded incrementally and
strictly. SVG artifacts are renderings of inspected pyte cells, NOT screenshots
of Terminal.app. Disposable Hosts, proxy sockets and PTYs are always cleaned.
Timeouts are failure bounds, not synchronization. Provider release and Action
readiness use events/pipes; durable capture and public Host reads are authority.
The lost case recovers the original identity with Ctrl-R while checking that
the independent next composition and logical cursor survive unchanged.
This does not qualify macOS, power loss, arbitrary TTY writers or native keys.
"""
import argparse
import codecs
import contextlib
import fcntl
import html
import json
import os
import pathlib
import re
import select
import shlex
import shutil
import signal
import socket
import socketserver
import struct
import subprocess
import tempfile
import termios
import threading
import time
import traceback
import unicodedata

import pyte
import dispatch_integration as fixture
import human_cli_integration as human
import codex_integration as codex


ARTIFACTS = pathlib.Path('.amp/in/artifacts/terminal-cleanup')


def assert_restored(fd, original_flags, original_mode):
    flags, mode = fcntl.fcntl(fd, fcntl.F_GETFL), termios.tcgetattr(fd)
    expected, actual = list(original_mode), list(mode)
    flag_mask = 0
    if os.uname().sysname == 'Darwin':
        # XNU write bookkeeping is not settable through F_SETFL. PENDIN
        # reprocesses queued input: this is not exact native-state equality.
        flag_mask = 0x10000  # FWASWRITTEN
        expected[3] &= ~0x20000000  # PENDIN
        actual[3] &= ~0x20000000
    assert (flags & ~flag_mask) == (original_flags & ~flag_mask) and actual == expected, {
        'original_flags': original_flags, 'final_flags': flags,
        'original_mode': original_mode, 'final_mode': mode}


class Terminal:
    def __init__(self, env, session, rows=18, columns=80, environment=None, pass_fds=()):
        self.master, slave = human.open_terminal()
        self.slave = slave
        self.original_mode = termios.tcgetattr(slave)
        self.original_flags = fcntl.fcntl(slave, fcntl.F_GETFL)
        self.final_native = None
        self.screen = pyte.HistoryScreen(columns, rows, history=4096)
        self.stream = pyte.Stream(self.screen)
        self.decoder = codecs.getincrementaldecoder('utf-8')('strict')
        self.raw = bytearray()
        self.resize(rows, columns)
        self.child = subprocess.Popen(
            [str(fixture.RUI), '--resume', session, '--store', str(env.store)],
            env={**os.environ, 'HOME': str(env.home),
                 'RUI_TEST_ACTION_READY_FD': str(env.ready_write), **(environment or {})},
            stdin=slave, stdout=slave, stderr=slave, pass_fds=(env.ready_write, *pass_fds))

    def resize(self, rows, columns):
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))
        self.screen.resize(lines=rows, columns=columns)

    def send(self, value):
        payload = value.encode() if isinstance(value, str) else value
        assert len(payload) <= 4096, 'use small independently synchronized input steps'
        assert os.write(self.master, payload) == len(payload)

    def read_until(self, predicate, description, timeout=15):
        deadline = time.monotonic() + timeout
        while not predicate():
            remaining = deadline - time.monotonic()
            assert remaining > 0, (description, self.snapshot())
            assert select.select([self.master], [], [], remaining)[0], (description, self.snapshot())
            self.ingest()

    def ingest(self):
        chunk = os.read(self.master, 4096)
        assert chunk, 'PTY EOF'
        self.raw.extend(chunk)
        assert len(self.raw) <= 8 * 1024 * 1024, 'bounded experiment output exceeded'
        self.stream.feed(self.decoder.decode(chunk))

    def action_ready(self, ready_read):
        deadline = time.monotonic() + 15
        while True:
            remaining = deadline - time.monotonic()
            assert remaining > 0, ('Action readiness timeout', self.snapshot())
            ready = select.select([ready_read, self.master], [], [], remaining)[0]
            assert ready, ('Action readiness timeout', self.snapshot())
            if ready_read in ready:
                assert os.read(ready_read, 1) == b'x', 'invalid Action readiness marker'
                return
            # Only explicit fresh-choice waits drain output; detach and
            # intentional backpressure witnesses never call this method.
            self.ingest()

    def text(self):
        return '\n'.join(self.screen.display)

    def collect(self):
        while select.select([self.master], [], [], 0)[0]:
            self.ingest()

    def history(self):
        return [''.join(row[x].data for x in range(self.screen.columns)).rstrip()
                for row in self.screen.history.top]

    def all_text(self):
        return '\n'.join(self.history() + self.screen.display)

    def draft(self, lines, cursor_column=None):
        expected = [unicodedata.normalize('NFC', ('> ' if i == 0 else '  ') + line).rstrip()
                    for i, line in enumerate(lines)]
        def matches():
            rows = [i for i, line in enumerate(self.screen.display)
                    if line.startswith('> ')]
            if len(rows) != 1:
                return False
            start = rows[0]
            if [line.rstrip() for line in self.screen.display[start:start+len(expected)]] != expected:
                return False
            return cursor_column is None or (self.screen.cursor.y == start+len(expected)-1
                                            and self.screen.cursor.x == cursor_column)
        self.read_until(matches, ('draft cells/cursor', expected, cursor_column))
        status_rows = [line for line in self.screen.display
                       if line.startswith(('Working...', 'Ctrl-G:', 'Sending...',
                                           'Ctrl-R: submission unconfirmed',
                                           '/discard: rejected original'))
                       or (' message queued' in line or ' messages queued' in line)]
        assert len(expected) + len(status_rows) <= 6, self.snapshot()

    def snapshot(self):
        flags, mode = self.final_native or (fcntl.fcntl(self.slave, fcntl.F_GETFL),
                                           termios.tcgetattr(self.slave))
        return {'display': self.screen.display, 'history': self.history(),
                'cursor': [self.screen.cursor.x, self.screen.cursor.y],
                'original_flags': self.original_flags,
                'current_flags': flags,
                'original_mode': repr(self.original_mode),
                'current_mode': repr(mode)}

    def save(self, name):
        ARTIFACTS.mkdir(parents=True, exist_ok=True)
        (ARTIFACTS / (name + '.json')).write_text(json.dumps(self.snapshot(), ensure_ascii=False, indent=2))
        (ARTIFACTS / (name + '.pty')).write_bytes(self.raw)
        width, height = self.screen.columns * 10 + 20, self.screen.lines * 20 + 50
        elements = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}">',
                    '<rect width="100%" height="100%" fill="#111"/>',
                    '<text x="10" y="18" fill="#aaa" font-size="12">pyte cells from production PTY (not native terminal screenshot)</text>']
        for y in range(self.screen.lines):
            for x in range(self.screen.columns):
                cell = self.screen.buffer[y][x]
                if cell.data.strip():
                    elements.append(f'<text x="{10+x*10}" y="{42+y*20}" fill="#eee" font-family="Noto Sans Mono CJK SC,monospace" font-size="16">{html.escape(cell.data)}</text>')
        elements.append(f'<rect x="{10+self.screen.cursor.x*10}" y="{27+self.screen.cursor.y*20}" width="9" height="18" fill="none" stroke="#55ff55" stroke-width="2"/>')
        elements.append('</svg>')
        (ARTIFACTS / (name + '.svg')).write_text('\n'.join(elements))

    def close(self):
        try:
            if self.child.poll() is None:
                self.send('\x03')
                deadline = time.monotonic() + 5
                while self.child.poll() is None and time.monotonic() < deadline:
                    if select.select([self.master], [], [], 0.1)[0]:
                        try:
                            os.read(self.master, 4096)
                        except OSError:
                            break
                if self.child.poll() is None:
                    self.child.kill()
            self.child.wait(timeout=5)
            assert_restored(self.slave, self.original_flags, self.original_mode)
        finally:
            # Failure artifacts are saved after Environment closes the PTYs.
            self.final_native = (fcntl.fcntl(self.slave, fcntl.F_GETFL), termios.tcgetattr(self.slave))
            os.close(self.slave)
            os.close(self.master)


class Environment:
    def __enter__(self):
        self.state = pathlib.Path(tempfile.mkdtemp(prefix='rui-session-pty-'))
        self.home, self.workspace, self.store = [self.state / n for n in ('home', 'workspace', 'store')]
        self.home.mkdir()
        self.workspace.mkdir()
        config = self.home / '.config/rui'
        config.mkdir(parents=True, mode=0o700)
        codex.credentials(config / 'codex.json')
        self.endpoint = fixture.SuccessEndpoint([])
        self.thread = threading.Thread(target=self.endpoint.serve_forever, daemon=True)
        self.thread.start()
        self.host = fixture.start_host(self.store, f'http://127.0.0.1:{self.endpoint.server_port}')
        self.ready_read, self.ready_write = os.pipe()
        self.terminals, self.gates = [], []
        self.proxy = None
        self.serial = 0
        return self

    def __exit__(self, *exc):
        for gate in self.gates:
            gate.set()
        if self.proxy:
            self.proxy.release.set()
        with contextlib.ExitStack() as cleanup:
            cleanup.callback(shutil.rmtree, self.state)
            cleanup.callback(os.close, self.ready_write)
            cleanup.callback(os.close, self.ready_read)
            cleanup.callback(self.thread.join, timeout=5)
            cleanup.callback(self.endpoint.server_close)
            cleanup.callback(self.endpoint.shutdown)
            cleanup.callback(fixture.stop_host, self.host)
            if self.proxy:
                cleanup.callback(self.proxy.close)
            for terminal in self.terminals:
                cleanup.callback(terminal.close)

    def configure(self, session, *extra):
        human.run(self.home, 'configure', '--store', self.store, '--session', session,
                  '--workspace', self.workspace, '--provider', 'codex', '--model', 'model-a', *extra)

    def terminal(self, session):
        terminal = Terminal(self, session)
        self.terminals.append(terminal)
        terminal.draft([''], 2)
        return terminal

    def answer(self, text, held=False):
        self.serial += 1
        tag = f'pty-{self.serial}'
        payload = fixture.sse_answer(tag, tag+'-reason', tag+'-message', text)[0]
        if held:
            gate = threading.Event()
            self.gates.append(gate)
            self.endpoint.responses.append((payload, gate))
            return gate
        self.endpoint.responses.append(payload)

    def message(self, session, text):
        return human.admit(self.home, 'message', '--store', self.store, '--session', session, text)['request']

    def facts(self, session):
        return fixture.command('inspect-session', '--store', self.store, '--session', session)

    def completed(self, key):
        fixture.wait_for(lambda: fixture.completed_observation(self.store, key), 'durable completion')

    def records(self):
        return {p.stem: p.read_bytes() for p in (self.home / '.config/rui/requests').glob('*.json')}

    def user_text(self):
        return next(item['content'][0]['text'] for item in reversed(json.loads(self.endpoint.requests[-1])['input'])
                    if item.get('role') == 'user')


def presentation_case(env):
    session = 'pty/presentation'
    env.configure(session)
    # Startup alone is not the assertion: allow either prompt in this setup so
    # the old binary fails at unwanted user-visible metadata, not fixture setup.
    terminal = Terminal(env, session)
    env.terminals.append(terminal)
    terminal.read_until(lambda: '/help' in terminal.text(), 'opening rendered')
    terminal.send('\x1b[200~中e\u0301\nsecond尾\x1b[201~\x1b[D')
    release = env.answer('The parser expects another value after a comma.\n'
                         'Allow a closing bracket there to accept trailing commas.', held=True)
    key = env.message(session, 'Why does the parser reject a trailing comma?')
    terminal.read_until(lambda: 'Why does the parser reject' in terminal.all_text(), 'applied input')
    release.set()
    env.completed(key)
    terminal.read_until(lambda: 'accept trailing commas.' in terminal.all_text(), 'answer rendered')
    raw = terminal.raw.decode()
    assert not any(marker in raw for marker in ('Message ', 'Operation ', 'position ', 'cutoff ', '[status]', '[draft]')), 'internal metadata reached ordinary presentation'
    terminal.draft(['中e\u0301', 'second尾'], 8)
    # Applied input and unsent composition are visibly different; one divider
    # introduces the complete answer. Neither success nor idle needs a receipt.
    assert 'You: Why does the parser reject a trailing comma?' in terminal.all_text()
    assert raw.count('────────') == 1, raw
    terminal.read_until(lambda: 'Working...' not in terminal.text(), 'idle presentation')
    assert 'Work completed.' not in terminal.all_text(), terminal.snapshot()
    terminal.save('presentation-after')

    # A failed earlier Turn must not disappear beside a later visible answer.
    env.endpoint.responses.append(fixture.ResponseSpec(b'rejected', {}, status=422))
    failed = env.message(session, 'failure remains visible')
    fixture.wait_for(lambda: human.run(env.home, 'result', failed).startswith('result: failed'), 'failure committed')
    terminal.read_until(lambda: 'Work failed: provider_http_422' in terminal.all_text(), 'failure rendered')
    env.answer('later answer')
    later = env.message(session, 'later input')
    env.completed(later)
    terminal.read_until(lambda: 'later answer' in terminal.all_text(), 'success after failure')
    assert 'Work failed: provider_http_422' in terminal.all_text(), terminal.snapshot()

    # Stops and cancellation remain visible, without claiming physical cleanup.
    release = env.answer('must not be displayed', held=True)
    running = env.message(session, 'stop this work')
    terminal.read_until(lambda: 'You: stop this work' in terminal.all_text(), 'running input displayed')
    fixture.command('stop-session', '--store', env.store, '--session', session,
                    '--record', env.state / 'stop.json', '--key', 'presentation-stop')
    release.set()
    fixture.wait_for(lambda: human.run(env.home, 'result', running).startswith('result: cancelled'), 'cancellation committed')
    terminal.read_until(lambda: 'Session stop accepted.' in terminal.all_text()
                        and 'Work cancelled.' in terminal.all_text(), 'stop and cancellation rendered')
    assert 'must not be displayed' not in terminal.all_text(), terminal.snapshot()
    terminal.draft(['中e\u0301', 'second尾'], 8)
    terminal.save('presentation-outcomes')


def proposal_case(env):
    session = 'pty/large-proposal'
    env.configure(session, '--tools', 'bash', '--permission-mode', 'ask')
    arguments = json.dumps({'cmd': 'printf '+('x'*9000)+' proposal-tail', 'timeout_ms': None}, separators=(',', ':'))
    env.endpoint.responses.append(fixture.sse_tool_calls('large-proposal', [('bash', 'large-call', arguments)]))
    env.message(session, 'inspect the complete proposal on resume')
    fixture.wait_for(lambda: env.facts(session)['actionable_permissions'], 'large proposal committed')
    terminal = env.terminal(session)
    output = terminal.raw.decode().replace('\r\r\n', '\n').replace('\r\n', '\n')
    assert 'Proposed tool: bash\n'+arguments+'\n' in output, 'historical proposal arguments lost behind an unusable omission/export'
    assert '[content omitted:' not in output and 'rui conversation-content' not in output
    assert 'Ctrl-G: inspect approval' in terminal.text(), terminal.snapshot()


def opening_stream_case(env):
    library = env.state/'terminal-scratch.so'
    subprocess.run(['cc', '-shared', '-fPIC',
                    str(pathlib.Path(__file__).with_name('terminal_scratch_probe.c')),
                    '-ldl', '-o', str(library)], check=True)
    maxima = []
    for size in (131072, 2097152):
        session = 'pty/opening-stream/'+str(size)
        env.configure(session, '--tools', 'bash', '--permission-mode', 'ask')
        arguments = json.dumps({'cmd': 'printf '+('x'*size)+' opening-tail', 'timeout_ms': None}, separators=(',', ':'))
        env.endpoint.responses.append(fixture.sse_tool_calls(session, [('bash', session, arguments)]))
        env.message(session, 'opening scratch measurement')
        fixture.wait_for(lambda: env.facts(session)['actionable_permissions'], 'proposal committed')
        env.proxy = Proxy(env.host.rui_ready_fields['socket'], 'read')
        read, write = os.pipe()
        measurements = [0, 0]

        def observe():
            while sample := os.read(read, 8):
                assert len(sample) == 8, sample
                measurements[0] = max(measurements[0], struct.unpack('q', sample)[0])
                measurements[1] += 1

        observer = threading.Thread(target=observe)
        observer.start()
        terminal = None
        try:
            terminal = Terminal(env, session, environment={
                'LD_PRELOAD': str(library), 'RUI_SCRATCH_NOTICE_FD': str(write)}, pass_fds=(write,))
            env.terminals.append(terminal)
            os.close(write)
            write = None
            terminal.read_until(lambda: b'/help for commands' in terminal.raw,
                                'complete large proposal opening', timeout=60)
            terminal.draft([''], 2)
            output = terminal.raw.decode().replace('\r\r\n', '\n').replace('\r\n', '\n')
            assert 'Proposed tool: bash\n'+arguments+'\n' in output, 'single-stream proposal output incomplete'
            assert env.proxy.argument_reads == 1, 'opening reread the complete proposal'
            terminal.send('\x03')
            terminal.child.wait(timeout=5)
            assert terminal.child.returncode == 0
            observer.join(timeout=5)
            assert not observer.is_alive() and measurements[1] > 0, 'scratch observer did not see real writes'
            maxima.append(measurements[0])
            print(f'proposal={size} bytes: largest CLI regular file={measurements[0]} bytes; observed writes={measurements[1]}', flush=True)
        finally:
            if write is not None:
                os.close(write)
            if observer.is_alive():
                if terminal is not None:
                    terminal.close()
                    env.terminals.remove(terminal)
                observer.join(timeout=5)
            os.close(read)
            env.proxy.close()
            env.proxy = None
    # One delivery window is tolerance, not a new semantic payload quota.
    assert maxima[1] <= maxima[0]+4096, ('proposal-proportional staging copy', maxima)

    old, target = 'pty/opening-old', 'pty/opening-target'
    env.configure(old)
    env.configure(target, '--tools', 'bash', '--permission-mode', 'ask')
    arguments = json.dumps({'cmd': 'printf '+('y'*32768)+' late-tail', 'timeout_ms': None})
    env.endpoint.responses.append(fixture.sse_tool_calls(target, [('bash', target, arguments)]))
    env.message(target, 'fault boundary')
    fixture.wait_for(lambda: env.facts(target)['actionable_permissions'], 'fault proposal committed')
    terminal = env.terminal(old)
    before = env.records()
    env.proxy = Proxy(env.host.rui_ready_fields['socket'], 'read')
    env.proxy.fault_arguments_at = 1
    start = len(terminal.raw)
    terminal.send('/resume '+target+'\n')
    terminal.child.wait(timeout=15)
    terminal.collect()
    output = terminal.raw[start:].decode()
    assert terminal.child.returncode == 1, ('post-header failure became successful detach', terminal.child.returncode)
    assert 'HistoryDisplayFailed' in output and 'Session: '+target in output, output
    assert 'Proposed tool: bash' in output and 'yyy' in output and 'late-tail' not in output, output
    assert 'active Session unchanged' not in output and '\r> ' not in output.split('HistoryDisplayFailed', 1)[1], output
    assert_restored(terminal.slave, terminal.original_flags, terminal.original_mode)
    assert env.proxy.argument_faults == 1 and env.proxy.argument_reads == 1
    assert env.records() == before and not env.proxy.commands, 'opening authorized work or altered captures'
    print('single postcommit stream fault restored and exited without rollback, retry or prompt', flush=True)


def request_write_case(env):
    session = 'pty/request-write'
    env.configure(session)
    env.proxy = Proxy(env.host.rui_ready_fields['socket'], 'read')
    library = env.state/'terminal-request.so'
    subprocess.run(['cc', '-shared', '-fPIC',
                    str(pathlib.Path(__file__).with_name('terminal_request_probe.c')),
                    '-ldl', '-o', str(library)], check=True)
    armed = env.state/'request-armed'
    with contextlib.ExitStack() as cleanup:
        notice_read, notice_write = os.pipe()
        gate_read, gate_write = os.pipe()
        for fd in (notice_read, notice_write, gate_read, gate_write):
            cleanup.callback(os.close, fd)
        cleanup.callback(os.write, gate_write, b'x')
        terminal = Terminal(env, session, environment={
            'LD_PRELOAD': str(library), 'RUI_REQUEST_ARMED': str(armed),
            'RUI_REQUEST_NOTICE_FD': str(notice_write),
            'RUI_REQUEST_GATE_FD': str(gate_read)}, pass_fds=(notice_write, gate_read))
        env.terminals.append(terminal)
        terminal.draft([''], 2)
        before = env.records()
        env.proxy.mode = 'request-reset'
        armed.touch()
        terminal.send('/status\n')
        assert select.select([notice_read], [], [], 15)[0], 'real request body write was not reached'
        assert os.read(notice_read, 1) == b'w'
        assert env.proxy.held.wait(15), 'real peer was not closed before write release'
        assert env.proxy.request_resets == 1
        env.proxy.mode = 'read'
        os.write(gate_write, b'x')
        terminal.read_until(lambda: b'rui: status: RequestWriteFailed' in terminal.raw, 'request write failure remained recoverable')
        terminal.draft([''], 2)
        assert terminal.child.poll() is None, 'request error detached a healthy frontend'
        terminal.send('still composing')
        terminal.draft(['still composing'], 17)
        assert env.records() == before and not env.proxy.commands
        terminal.send('\x03')
        terminal.child.wait(timeout=5)
        assert terminal.child.returncode == 0
        assert_restored(terminal.slave, terminal.original_flags, terminal.original_mode)


def resume_selection_case(env):
    old, target = 'pty/selection-old', 'pty/selection-target'
    env.configure(old)
    env.configure(target)
    before = env.records()
    for stopped, erase in ((True, True), (True, False), (False, True), (False, False)):
        terminal = env.terminal(old)
        for defer_choice in (True, False):
            start = len(terminal.raw)
            terminal.send('/resume\n')
            terminal.read_until(lambda: b'\x1b[?2004h> ' in terminal.raw[start:], 'actual resume chooser prompt')
            if defer_choice:
                if erase:
                    terminal.send('é')
                    terminal.read_until(lambda: 'é'.encode() in terminal.raw[start:], 'chooser echoed Unicode draft')
                    # Each read is one byte: the replacement's UTF-8 prefix
                    # arrives while deletion paint is pending, then completes.
                    terminal.send('\x7fé\x7fl\n')
                else:
                    terminal.send('l\n')
                # A redrawn chooser line legitimately remains in scrollback;
                # identify the active footer by its current physical cursor.
                terminal.read_until(lambda: terminal.screen.display[terminal.screen.cursor.y].rstrip() == '>'
                                    and terminal.screen.cursor.x == 2, 'composing footer after chooser defer')
                terminal.send('/status\n')
                terminal.read_until(lambda: re.search(r'Session:\s+'+re.escape(old), terminal.raw[start:].decode()), 'defer preserved entered Session')
                terminal.read_until(lambda: terminal.screen.display[terminal.screen.cursor.y].rstrip() == '>'
                                    and terminal.screen.cursor.x == 2, 'composing footer after status')
            else:
                if erase:
                    terminal.send('é')
                    terminal.read_until(lambda: 'é'.encode() in terminal.raw[start:], 'chooser echoed Unicode draft')
                if stopped:
                    termios.tcflow(terminal.slave, termios.TCOOFF)
                try:
                    terminal.send('\x7f\x03' if erase else '\x03')
                    try:
                        terminal.child.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        raise AssertionError(('pending-deletion ' if erase else '')+'chooser detach waited for output release') from None
                    assert terminal.child.returncode == 0
                    assert_restored(terminal.slave, terminal.original_flags, terminal.original_mode)
                finally:
                    if stopped:
                        termios.tcflow(terminal.slave, termios.TCOON)
                terminal.collect()
                after = terminal.raw[start:]
                assert b'active Session unchanged' not in after, 'Ctrl-C was demoted to recoverable selection failure'
                assert after.count(b'\x1b[?2004h') == 1, 'fatal chooser exit reacquired Session terminal custody'
            assert env.records() == before


def display_case(env):
    session = 'pty/display'
    env.configure(session)
    terminal = env.terminal(session)
    # Force real normal-screen scrolling before composition, not just a short
    # transcript which happens to fit in the viewport.
    prelude = '\n'.join(f'permanent-{i:03}' for i in range(45))
    env.answer(prelude)
    key = env.message(session, 'independent-prelude')
    env.completed(key)
    terminal.read_until(lambda: 'permanent-044' in terminal.text(), 'prelude displayed')
    terminal.draft([''], 2)
    assert any('permanent-000' in line for line in terminal.history()), terminal.snapshot()
    terminal.send('\x1b[200~中e\u0301\nsecond尾\x1b[201~\x1b[D')
    terminal.draft(['中e\u0301', 'second尾'], 8)
    release = env.answer('independent-completion', held=True)
    key = env.message(session, 'external-admission')
    terminal.read_until(lambda: 'external-admission' in terminal.all_text(), 'independent application')
    terminal.draft(['中e\u0301', 'second尾'], 8)
    release.set()
    env.completed(key)
    terminal.read_until(lambda: 'independent-completion' in terminal.all_text(), 'independent completion')
    terminal.draft(['中e\u0301', 'second尾'], 8)
    # A second scrolling append must move permanent content, not the footer.
    env.answer('\n'.join(f'after-{i:03}' for i in range(30)))
    key = env.message(session, 'external-after')
    env.completed(key)
    terminal.read_until(lambda: 'after-029' in terminal.text(), 'scrolling append')
    terminal.draft(['中e\u0301', 'second尾'], 8)
    transcript = terminal.all_text()
    for marker in ('external-admission', 'independent-completion', 'permanent-000'):
        assert transcript.count(marker) == 1, (marker, terminal.snapshot())
    assert not any(row.startswith('> ') or any(status in row for status in
                   ('Working...', 'Ctrl-G:', 'message queued', 'messages queued',
                    'Sending...', 'Ctrl-R: submission unconfirmed',
                    '/discard: rejected original', '[draft]', '[status]', '[admission'))
                   for row in terminal.history()), terminal.snapshot()
    # Independent cell oracle: CJK occupies two cells and combining accent
    # belongs to its base, not a cursor column of its own.
    row = next(i for i, line in enumerate(terminal.screen.display) if line.startswith('> 中'))
    assert terminal.screen.buffer[row][2].data == '中'
    assert terminal.screen.buffer[row][3].data == ''
    assert terminal.screen.buffer[row][4].data == 'é'
    terminal.save('display-preserved')
    env.answer('draft-admitted')
    terminal.send('X\n')
    terminal.read_until(lambda: 'draft-admitted' in terminal.all_text(), 'edited draft completes')
    assert env.user_text() == '中e\u0301\nsecondX尾', env.user_text()
    assert b'request: ' not in terminal.raw, 'successful interactive send leaked a protocol receipt'


def flag_case(env):
    session = 'pty/flag'
    env.configure(session)
    terminal = env.terminal(session)
    terminal.send('🇺🇸Z\x1b[D')
    terminal.draft(['🇺🇸Z'], 4)
    env.answer('flag-independent-output')
    key = env.message(session, 'flag-external')
    env.completed(key)
    terminal.read_until(lambda: 'flag-independent-output' in terminal.all_text(), 'output during flag composition')
    terminal.draft(['🇺🇸Z'], 4)
    terminal.send('X')
    terminal.draft(['🇺🇸XZ'], 5)
    terminal.send('\x01\x0b' + 'x'*76 + '🇺🇸Z\x1b[D')
    # There are 77 usable cells after the two-cell prefix and spare column.
    # A two-cell flag cannot occupy the one cell left after 76 ASCII cells.
    terminal.draft(['x'*76, '🇺🇸Z'], 4)
    env.answer('flag-wrapped-output')
    key = env.message(session, 'flag-external-wrapped')
    env.completed(key)
    terminal.read_until(lambda: 'flag-wrapped-output' in terminal.all_text(), 'output during wrapped flag composition')
    terminal.draft(['x'*76, '🇺🇸Z'], 4)
    assert not any(row.startswith('> ') or 'Working...' in row or 'Ctrl-G:' in row
                   or '[draft]' in row or '[status]' in row for row in terminal.history()), terminal.snapshot()
    terminal.save('flag-preserved')
    env.answer('flag-draft-admitted')
    terminal.send('X\n')
    terminal.read_until(lambda: 'flag-draft-admitted' in terminal.all_text(), 'flag draft completes')
    assert env.user_text() == 'x'*76 + '🇺🇸XZ', env.user_text()


def resize_case(env):
    session = 'pty/resize'
    env.configure(session)
    terminal = env.terminal(session)
    env.answer('\n'.join(f'resize-permanent-{i:03}' for i in range(35)))
    prior = env.message(session, 'resize-history')
    env.completed(prior)
    terminal.read_until(lambda: 'resize-permanent-034' in terminal.text(), 'history before resize')
    terminal.draft([''], 2)
    assert 'resize-permanent-000' in '\n'.join(terminal.history())
    terminal.send('\x1b[200~中e\u0301\nsecond尾\x1b[201~\x1b[D')
    terminal.draft(['中e\u0301', 'second尾'], 8)
    for rows, columns in ((10, 40), (22, 100)):
        before = len(terminal.raw)
        terminal.resize(rows, columns)
        terminal.read_until(lambda: b'[display restarted after resize]' in terminal.raw[before:], 'resize notice')
        terminal.draft(['中e\u0301', 'second尾'], 8)
        assert terminal.all_text().count('resize-permanent-000') == 1, 'resize erased/replayed permanent scrollback'
        # VT resize may retain indented continuation fragments in history;
        # it cannot retrospectively mark every old row. Live draft/cursor and
        # permanent history above remain the preservation oracle.
    terminal.save('resize-preserved')
    env.answer('resized-draft-admitted')
    terminal.send('X\n')
    terminal.read_until(lambda: 'resized-draft-admitted' in terminal.all_text(), 'resize edited draft completes')
    assert env.user_text() == '中e\u0301\nsecondX尾', env.user_text()


def rejection_case(env):
    session = 'pty/rejection'
    env.configure(session)
    terminal = env.terminal(session)
    before = env.records()
    terminal.send(b'invalid\x00suffix\n')
    terminal.read_until(lambda: 'Input rejected; nothing sent.' in terminal.all_text(), 'rejection')
    terminal.draft([''], 2)
    assert env.records() == before, 'rejected input captured intent'
    env.answer('fresh-after-rejection')
    terminal.send('fresh\n')
    terminal.read_until(lambda: 'fresh-after-rejection' in terminal.all_text(), 'fresh input completes')
    assert env.user_text() == 'fresh', 'rejected prefix survived reset'
    terminal.save('rejection-reset')


def approval_case(env):
    session = 'pty/approval'
    env.configure(session, '--tools', 'bash', '--permission-mode', 'ask')
    command = 'printf x >> effect-count'
    arguments = json.dumps({'cmd': command, 'timeout_ms': None}, separators=(',', ':'))
    env.endpoint.responses.append(fixture.sse_tool_calls('pty-call', [('bash', 'pty-bash', arguments)]))
    env.answer('approved-completion')
    terminal = env.terminal(session)
    key = env.message(session, 'propose-exact-action')
    facts = fixture.wait_for(lambda: (f if (f := env.facts(session))['actionable_permissions'] else None), 'Action proposed')
    action = facts['actionable_permissions'][0]['action']
    terminal.read_until(lambda: 'Ctrl-G: inspect approval' in terminal.text(), 'attention footer')
    terminal.send('\x1b[200~中e\u0301\nsecond尾\x1b[201~\x1b[D')
    terminal.draft(['中e\u0301', 'second尾'], 8)
    captures = env.records()
    effect = env.workspace / 'effect-count'
    terminal.save('approval-attention')
    # Typeahead included in the SAME write must be discarded before prompt.
    inspection_start = len(terminal.raw)
    terminal.send('\x07a\n')
    terminal.read_until(lambda: 'Allow once, deny, or later?' in terminal.text(), 'exact approval prompt')
    terminal.action_ready(env.ready_read)
    inspection = terminal.raw[inspection_start:]
    assert ('Command: "'+command+'"').encode() in inspection, inspection.decode()
    assert command in terminal.text(), terminal.snapshot()
    assert env.facts(session)['actionable_permissions'][0]['action'] == action
    assert not effect.exists() and env.records() == captures
    # Resize while explicit choice parser, not composition, owns input.
    terminal.resize(12, 64)
    terminal.send('l\n')
    terminal.read_until(lambda: 'No decision sent' in terminal.all_text(), 'later without decision')
    terminal.draft(['中e\u0301', 'second尾'], 8)
    assert '[display restarted after resize]' in terminal.all_text()
    assert not effect.exists() and env.records() == captures
    terminal.send('\x07')
    terminal.action_ready(env.ready_read)
    terminal.resize(22, 100)
    start = len(terminal.raw)
    terminal.send('l\n')
    terminal.read_until(lambda: b'No decision sent' in terminal.raw[start:], 'later after growing during approval')
    terminal.draft(['中e\u0301', 'second尾'], 8)
    assert not effect.exists() and env.records() == captures
    terminal.send('\x07')
    terminal.action_ready(env.ready_read)
    start = len(terminal.raw)
    terminal.send('\x1b[200~a\x1b[201~\n')
    terminal.read_until(lambda: b'No decision sent' in terminal.raw[start:], 'paste rejects decision')
    terminal.draft(['中e\u0301', 'second尾'], 8)
    assert not effect.exists() and env.records() == captures
    terminal.send('\x07')
    terminal.action_ready(env.ready_read)
    terminal.send('a\n')
    env.completed(key)
    terminal.read_until(lambda: 'approved-completion' in terminal.all_text(), 'real allow completes')
    terminal.draft(['中e\u0301', 'second尾'], 8)
    assert effect.read_text() == 'x'
    decision, = set(env.records()) - set(captures)
    record = json.loads(env.records()[decision])
    assert record['kind'] == 'permission_decision', record
    assert str(record['action']) == str(action), record
    assert len(env.facts(session)['recent_messages']) == 1, env.facts(session)
    assert b'request: ' not in terminal.raw, 'successful approval leaked a protocol receipt'
    terminal.save('approval-preserved')
    env.answer('composition-after-allow')
    terminal.send('X\n')
    terminal.read_until(lambda: 'composition-after-allow' in terminal.all_text(), 'ordinary composition completes')
    assert env.user_text() == '中e\u0301\nsecondX尾'
    assert effect.read_text() == 'x'


def approval_detach_case(env):
    for route, entry in (('shortcut', '\x07'), ('command', '/approve\n')):
        for signal, key in (('interrupt', '\x03'), ('eof', '\x04')):
            session = 'pty/approval-detach/'+route+'/'+signal
            env.configure(session, '--tools', 'bash', '--permission-mode', 'ask')
            arguments = json.dumps({'cmd': 'printf forbidden > detach-effect', 'timeout_ms': None})
            env.endpoint.responses.append(fixture.sse_tool_calls(session, [('bash', session, arguments)]))
            env.message(session, 'propose but do not authorize')
            facts = fixture.wait_for(lambda: (f if (f := env.facts(session))['actionable_permissions'] else None), 'Action proposed')
            action = facts['actionable_permissions'][0]['action']
            terminal = env.terminal(session)
            captures = env.records()
            terminal.send(entry)
            terminal.read_until(lambda: 'Allow once, deny, or later?' in terminal.text(), 'approval prompt')
            terminal.action_ready(env.ready_read)
            terminal.send(key)
            try:
                terminal.child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                # Release the old prompt before raising the intended oracle;
                # fixture teardown must not replace it with a raw-mode error.
                terminal.send('l\n')
                terminal.read_until(lambda: 'No decision sent' in terminal.all_text(), 'baseline prompt released')
                terminal.send('\x03')
                terminal.child.wait(timeout=3)
                raise AssertionError(f'{route}/{signal}: approval detach did not exit')
            assert terminal.child.returncode == 0, (route, signal, terminal.child.returncode)
            flags = termios.tcgetattr(terminal.master)[3]
            assert flags & termios.ICANON and flags & termios.ECHO and flags & termios.ISIG, (route, signal, 'TTY not restored')
            assert env.records() == captures, (route, signal, 'interrupted approval captured authority')
            assert env.facts(session)['actionable_permissions'][0]['action'] == action
            assert not (env.workspace / 'detach-effect').exists()
