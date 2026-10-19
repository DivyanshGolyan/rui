"""Four short synthetic tmux integration rows. Full landing gates stay intact."""
import json
import shlex
import subprocess
import time

from host_process import dispose_all
from scenarios import assert_submitted


def smoke(fixture, row):
    socket = fixture.root / "tmux.sock"
    command = ["tmux", "-S", str(socket), "-f", "/dev/null"]

    def tmux(*args, check=True):
        result = subprocess.run([*command, *args], env=fixture.env,
                                capture_output=True, timeout=5)
        if check:
            assert result.returncode == 0, ("tmux setup/control", args, result.stderr)
        return result

    def wait(predicate, label):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            result = tmux("capture-pane", "-p", "-t", "td4:0.0", check=False)
            if result.returncode == 0:
                (fixture.output / "pane.txt").write_bytes(result.stdout)
                if predicate(result.stdout.decode()):
                    return
            time.sleep(0.02)
        raise TimeoutError(f"tmux smoke {label}: no matching pane; see pane.txt")

    fixture.answer("TD4 tmux answer")
    rui = shlex.join([fixture.binary, "session", "resume", "--store", str(fixture.store), "--", "td4"])
    shell = (f"stty -g > {shlex.quote(str(fixture.root / 'before'))}; {rui}; "
             f"code=$?; stty -g > {shlex.quote(str(fixture.root / 'after'))}; "
             f"printf '%s' \"$code\" > {shlex.quote(str(fixture.root / 'exit'))}")
    try:
        tmux("new-session", "-d", "-s", "td4", "-x", "80", "-y", "24", "-c", str(fixture.root), shell)
        tmux("pipe-pane", "-o", "-t", "td4:0.0", "cat > " + shlex.quote(str(fixture.output / "output.bin")))
        wait(lambda text: "›" in text and "Opening" not in text, "empty composer")
        payload = bytes.fromhex(row["chunks"][0]["hex"])
        (fixture.output / "input.bin").write_bytes(payload)
        if row["name"] == "tmux-paste":
            # -p asks tmux to retain marked-paste provenance for its pane.
            tmux("set-buffer", "--", payload.decode())
            tmux("paste-buffer", "-p", "-t", "td4:0.0")
            tmux("send-keys", "-t", "td4:0.0", "Enter")
        else:
            if row["name"] == "tmux-resize":
                tmux("resize-window", "-t", "td4:0", "-x", "32", "-y", "12")
            tmux("send-keys", "-t", "td4:0.0", "-H", *(f"{byte:02x}" for byte in payload))
        wait(lambda text: "TD4 tmux answer" in text, "answer")
        assert_submitted(fixture.endpoint.requests, [row["expected"]])
        tmux("send-keys", "-t", "td4:0.0", "-l", "/exit")
        tmux("send-keys", "-t", "td4:0.0", "Enter")
        deadline = time.monotonic() + 10
        while not (fixture.root / "exit").exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert (fixture.root / "exit").read_text() == "0", "tmux caller failed"
        assert (fixture.root / "before").read_bytes() == (fixture.root / "after").read_bytes(), "tmux termios not restored"
        (fixture.output / "tmux.json").write_text(json.dumps({
            "version": tmux("-V").stdout.decode().strip(), "restored": True, "exit": 0}))
    finally:
        dispose_all(lambda: tmux("kill-server", check=False))
