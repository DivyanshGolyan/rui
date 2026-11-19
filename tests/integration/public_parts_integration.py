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


def digest(content):
    domain = b"rui/content/v1"
    return hashlib.sha256(len(domain).to_bytes(8, "big") + domain + content).hexdigest()


def refused(*arguments):
    result = subprocess.run([str(fixture.RUI), *arguments], capture_output=True, timeout=15)
    assert result.returncode != 0 and not result.stdout, (arguments, result.stdout, result.stderr)


def INS_10_public_part_cli(store, seed, values):
    # INS-10: the exact list for each owner, the exact bytes of every part, and refusals without payload.
    parts = []
    for ordinal, (kind, content, media) in enumerate(values):
        part = {"ordinal": str(ordinal), "type": kind}
        if media:
            mime, width, height, name = media
            part.update({"mime": mime, "width": str(width), "height": str(height), "name": name})
        part.update({"bytes": str(len(content)), "sha256": digest(content)})
        parts.append(part)
    identities = set()
    for resource, flag, owner, identity in (("session", "--admission", "message", seed["admission"]),
                                            ("action", "--action", "action", seed["action"])):
        base = ["--store", str(store), "--session", seed["session"], flag, identity]
        listed = subprocess.run([str(fixture.RUI), resource, "list-parts", *base], capture_output=True, timeout=15)
        assert listed.returncode == 0, (listed.stdout, listed.stderr)
        reply = json.loads(listed.stdout)
        value = reply.pop("value")
        assert reply == {"version": host_process.WIRE_VERSION, "type": "public_parts", "session": seed["session"], "parts": parts}, reply
        assert value["type"] == "parts" and value["owner"] == {owner: identity}, value
        assert len(value["sha256"]) == 64 and int(value["bytes"]) > 0, value
        identities.add((value["bytes"], value["sha256"]))
        for ordinal, (_, content, _) in enumerate(values):
            result = subprocess.run([str(fixture.RUI), resource, "read-part", *base, "--part", str(ordinal)],
                                    capture_output=True, timeout=15)
            assert result.returncode == 0, (ordinal, result.stdout, result.stderr)
            assert result.stdout == content, (ordinal, len(result.stdout))
        refused(resource, "read-part", *base, "--part", str(len(values)))
        for session in (seed["foreign"], "000000"):
            wrong = ["--store", str(store), "--session", session, flag, identity]
            refused(resource, "list-parts", *wrong)
            refused(resource, "read-part", *wrong, "--part", "1")
    # Both owners hold one deduplicated value.
    assert len(identities) == 1, identities
    text = ["--store", str(store), "--session", seed["session"], "--admission", seed["text_admission"]]
    refused("session", "list-parts", *text)
    refused("session", "read-part", *text, "--part", "0")
    # An Action read projects the parts value with its owner instead of refusing it.
    read = fixture.command("action", "read", "--store", str(store), "--session", seed["session"], "--action", seed["action"])
    content = read["final"]["content"]
    assert content["type"] == "parts" and content["owner"] == {"action": seed["action"]}, read
    assert (content["bytes"], content["sha256"]) in identities, read
    # An offset into a parts value has no text to window.
    refused("action", "read", "--store", str(store), "--session", seed["session"], "--action", seed["action"], "--offset", "1")
    # Keyed observation of a compound Message reports its parts form (CLI-19 owns identity agreement);
    # the Host keeps serving.
    observation = fixture.command("request", "inspect", "--store", str(store),
                                  "--key", "cli-mixed-message")["observation"]
    assert (observation["status"], observation["kind"], observation["target"]) == (
        "accepted", "message", seed["session"]), observation
    assert observation["queue"]["admission"] == seed["admission"], observation
    assert observation["input"]["type"] == "parts", observation
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
              ("image", png, ("image/png", 1, 1, "cat 雪.png")), ("text", b"between", None),
              ("image", jpeg, ("image/jpeg", 3, 2, None)), ("text", b"", None)]
    host = fixture.start_host(store, None)
    try:
        INS_10_public_part_cli(store, seed, values)
        print("INS-10: Message and Action part lists, Text and Image bytes, and refusals")
    finally:
        fixture.stop_host(host)
        directory.cleanup()


if __name__ == "__main__":
    host_process.enter()
    main()
