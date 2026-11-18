#!/usr/bin/env python3
"""Read a Store seeded by the `seed CLI mixed parts fixture` unit test."""
import hashlib
import json
import pathlib
import os
import tempfile
import subprocess
import sys

# Both build artifacts must remain addressable after the seed changes cwd.
sys.argv[1:3] = [str(pathlib.Path(arg).resolve()) for arg in sys.argv[1:3]]

import host_process
import model_fixture as fixture


def INS_10_public_part_selection(store, seed, values):
    # INS-10: selected typed metadata, image bytes, and refusals.
    for resource, flag, identity in (("session", "--admission", seed["admission"]),
                                     ("action", "--action", seed["action"])):
        base = ["--store", str(store), "--session", seed["session"], flag, identity]
        for ordinal, (kind, content, mime) in enumerate(values):
            domain = b"rui/content/v1"
            digest = hashlib.sha256(len(domain).to_bytes(8, "big") + domain + content).hexdigest()
            expected = {"ordinal": str(ordinal), "type": kind, "bytes": str(len(content)), "sha256": digest}
            if mime:
                expected["mime"] = mime
            assert fixture.command(resource, "inspect-part", *base, "--ordinal", str(ordinal))["part"] == expected
            result = subprocess.run([str(fixture.RUI), resource, "read-image-part", *base,
                                     "--ordinal", str(ordinal)], capture_output=True, timeout=15)
            if kind == "image":
                assert result.returncode == 0, (result.stdout, result.stderr)
                assert result.stdout == content
            else:
                assert result.returncode != 0 and not result.stdout, (result.stdout, result.stderr)
        assert fixture.command(resource, "inspect-part", *base, "--ordinal", "5")["part"] is None
        for wrong in (["--store", str(store), "--session", seed["session"], flag, identity, "--ordinal", "5"],
                      ["--store", str(store), "--session", "000000", flag, identity, "--ordinal", "1"]):
            result = subprocess.run([str(fixture.RUI), resource, "read-image-part", *wrong], capture_output=True, timeout=15)
            assert result.returncode != 0 and not result.stdout, (result.stdout, result.stderr)
    result = subprocess.run([str(fixture.RUI), "action", "read", "--store", str(store),
                             "--session", seed["session"], "--action", seed["action"]],
                            capture_output=True, timeout=15)
    assert result.returncode != 0 and not result.stdout, (result.stdout, result.stderr)
    # Keyed observation answers the Store's ordinary refusal of a compound input as its error record;
    # the Host keeps serving (SH-51).
    result = subprocess.run([str(fixture.RUI), "request", "inspect", "--store", str(store),
                             "--key", "cli-mixed-message"], capture_output=True, timeout=15)
    assert result.returncode != 0, (result.stdout, result.stderr)
    assert json.loads(result.stdout) == {"key": "cli-mixed-message", "error": {
        "status": 500, "type": "observation_error", "code": "InputPartsNotSupported"}}, result.stdout
    assert fixture.command("host", "status", "--store", str(store))["status"] == "ready"


def main():
    directory = tempfile.TemporaryDirectory(prefix="rui-public-parts.")
    store = pathlib.Path(host_process.canonical_fixture_root(directory.name))
    seed_run = subprocess.run([sys.argv[2]], env={**os.environ, "RUI_PARTS_SEED_DIR": str(store)}, cwd=store, capture_output=True, timeout=60)
    assert seed_run.returncode == 0, (seed_run.stdout, seed_run.stderr)
    (store / "store.sqlite3").rename(store / "rui.sqlite3")
    seed = json.loads((store / "parts-seed.json").read_text())
    png = (fixture.ROOT / "src/codecs/fixtures/image-input/pixel.png").read_bytes()
    jpeg = (fixture.ROOT / "src/testing/fixtures/input-baseline.jpg").read_bytes()
    values = [("text", b'before "quoted"\n\xe9\x9b\xaa\0', None),
              ("image", png, "image/png"), ("text", b"between", None),
              ("image", jpeg, "image/jpeg"), ("text", b"", None)]
    host = fixture.start_host(store, None)
    try:
        INS_10_public_part_selection(store, seed, values)
        print("INS-10: selected Message and Action image bytes and refusals")
    finally:
        fixture.stop_host(host)
        directory.cleanup()


if __name__ == "__main__":
    host_process.enter()
    main()
