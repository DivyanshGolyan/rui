"""Capture the upgrade cancellation/retry seam; never submit the retry."""
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

import host_process
from host_process import canonical_fixture_root, dispose_all, wait_for
from terminal_process import terminal_process
from upgrade_integration import Releases, TerminalScreen, case, terminal_setup


class EvidenceScreen(TerminalScreen):
    LIMIT = 4 * 1024 * 1024
    MAX_EVENTS = 20000

    def __init__(self, master, process):
        super().__init__(master, process)
        self.raw = bytearray()
        self.events = []
        self.capture.listener = self.frame

    def event(self, kind, **extra):
        assert len(self.events) < self.MAX_EVENTS, "evidence event limit"
        cursor = self.capture.screen.cursor
        self.events.append(dict(kind=kind, offset=len(self.raw), generation=self.capture.generation,
                                cursor=[cursor.x, cursor.y], row=self.capture.screen.display[cursor.y], **extra))

    def frame(self, _text, x, y):
        self.event("frame", committed_cursor=[x, y])

    def read_output(self):
        try:
            data = os.read(self.master, 65536)
        except BlockingIOError:
            return False
        if not data:
            return False
        assert len(self.raw) + len(data) <= self.LIMIT, "evidence byte limit"
        start = len(self.raw)
        self.raw.extend(data)  # Before parsing, including when parsing fails.
        self.event("read", start=start, end=len(self.raw))
        self.capture.feed(data)
        self.tail.extend(data)
        del self.tail[:-16384]
        return True

    def send(self, text):
        self.event("send", text=text)
        super().send(text)

    def save_evidence(self, artifacts):
        (artifacts / "terminal.raw").write_bytes(self.raw)
        (artifacts / "events.json").write_text(json.dumps(self.events, ensure_ascii=True, indent=2) + "\n")


def run(root, binary, releases, artifacts):
    with case(root, binary, releases, "terminal-overview-evidence") as c:
        c.old_selection()
        old_host, previous = c.start_host()
        _, credential = terminal_setup(c)
        gate = releases.gate_archive()
        args = [str(binary), "--store", str(c.store), "--provider", "codex", "--model", "gpt-6-luna"]
        with terminal_process(args, env=c.env, cwd=c.root) as (process, master):
            screen = EvidenceScreen(master, process)
            try:
                screen.contains("›")
                screen.send("/upgrade\r")
                screen.until(gate.entered.is_set, "terminal installation archive gate without a second Enter")
                screen.contains("preparing")
                screen.send("\x1b[?2027;3$y\x1b[200~XYZ\x1b[201~\x1b[DQ")
                prompt = " › "
                wait_for(screen.observe, "draft edited during upgrade", ready=lambda _: screen.capture.draft("/upgradeXYQZ", len(prompt) + 11, prompt=prompt))
                screen.send("\x1b")
                wait_for(screen.observe, "cancelled terminal preparation", timeout=15, ready=lambda text: "Upgrade cancelled" in text)
                gate.release.set()
                c.assert_unchanged()
                assert old_host.poll() is None and c.status()["instance"] == previous["instance"]
                screen.contains("›")
                wait_for(screen.observe, "retained edited draft after cancellation", ready=lambda _: screen.capture.draft("/upgradeXYQZ", len(prompt) + 11, prompt=prompt))
                screen.send("\x05\x15")
                wait_for(screen.observe, "cleared edited draft before Unicode paste", ready=lambda _: screen.capture.draft("Type a task to start a Session", len(prompt), prompt=prompt))
                screen.event("empty")
                screen.send("\x1b[200~A❤️B\x1b[201~")
                def unicode_draft(_):
                    capture = screen.capture
                    cursor = capture.screen.cursor
                    return not capture.synchronized and "A❤" in capture.screen.display[cursor.y] and cursor.x == len(prompt) + 4
                wait_for(screen.observe, "Unicode width after upgrade cancellation", ready=unicode_draft)
                screen.event("unicode")
                screen.send("\x05\x15/upgrade")
                wait_for(screen.observe, "exact retry command before submission", ready=lambda _: screen.capture.draft("/upgrade", len(prompt) + 8, prompt=prompt))
                screen.event("retry")
                c.assert_unchanged()
                assert old_host.poll() is None and c.status()["instance"] == previous["instance"]
                assert (c.home / ".config/rui/codex.json").read_bytes() == credential
            finally:
                dispose_all(lambda: screen.save_evidence(artifacts))


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: upgrade_raw_evidence.py NATIVE_RELEASE_BINARY ARTIFACT_DIRECTORY")
    binary = pathlib.Path(sys.argv[1]).resolve(strict=True)
    artifacts = pathlib.Path(sys.argv[2]).resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    root = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-upgrade-raw-"))
    assert not artifacts.is_relative_to(root)
    try:
        home = root / "version-home"
        home.mkdir()
        output = subprocess.check_output([str(binary), "--version"], env={**os.environ, "HOME": str(home)}, text=True, timeout=5)
        match = re.match(r"rui (0\.[0-9]+\.[0-9]+) \(", output)
        assert match, "supply a native release-identity actor"
        releases = Releases(binary, match[1])
        try:
            run(root, binary, releases, artifacts)
        finally:
            dispose_all(releases.close)
    finally:
        dispose_all(lambda: shutil.rmtree(root))


if __name__ == "__main__":
    host_process.enter()
    main()
