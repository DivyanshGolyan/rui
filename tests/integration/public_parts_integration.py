#!/usr/bin/env python3
"""Read a Store seeded by the `seed CLI mixed parts fixture` unit test."""
import hashlib
import json
import pathlib
import os
import tempfile
import subprocess
import sys

import host_process
import model_fixture as fixture


def digest(value):
    domain = b"rui/content/v1"
    return hashlib.sha256(len(domain).to_bytes(8, "big") + domain + value).hexdigest()


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
        for resource, flag, identity in (("session", "--admission", seed["admission"]),
                                         ("action", "--action", seed["action"])):
            base = ["--store", str(store), "--session", seed["session"], flag, identity]
            for ordinal, (kind, content, mime) in enumerate(values):
                args = [resource, "inspect-part", *base, "--ordinal", str(ordinal)]
                actual = fixture.command(*args)["part"]
                expected = {"ordinal": str(ordinal), "type": kind, "bytes": str(len(content)), "sha256": digest(content)}
                if mime:
                    expected["mime"] = mime
                assert actual == expected, (args, actual, expected)
                if kind == "image":
                    exported = subprocess.run([str(fixture.RUI), resource, "read-image-part", *base,
                                               "--ordinal", str(ordinal)], capture_output=True, timeout=15)
                    assert exported.returncode == 0, (exported.stdout, exported.stderr)
                    assert exported.stdout == content
            assert fixture.command(resource, "inspect-part", *base, "--ordinal", "5")["part"] is None
            text_export = subprocess.run([str(fixture.RUI), resource, "read-image-part", *base,
                                          "--ordinal", "0"], capture_output=True, timeout=15)
            assert text_export.returncode != 0 and not text_export.stdout
        print("Seeded Message and Action: ordered Text, PNG and JPEG metadata and exact image bytes")
    finally:
        fixture.stop_host(host)
        directory.cleanup()


if __name__ == "__main__":
    host_process.enter()
    main()
