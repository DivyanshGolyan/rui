#!/usr/bin/env python3

import argparse
import json
import os
from pathlib import Path
import sys

import host_process


def vectors():
    for encoding, data in (
        ("raw", b"\x12"),
        ("kitty", b"\x1b[114;5u"),
        ("case27", b"\x1b[27;5;114~"),
    ):
        yield {
            "name": f"TD2-recovery-{encoding}",
            "scenario": "recovery",
            "chunks": [{"hex": data.hex(), "delay_before": 0}],
        }
        for split in range(2, len(data)):
            yield {
                "name": f"TD2-recovery-{encoding}-split-{split}",
                "scenario": "recovery",
                "chunks": [
                    {"hex": data[:split].hex(), "delay_before": 0},
                    {"hex": data[split:].hex(), "delay_before": 0},
                ],
            }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--jobs", default=2, type=int, choices=range(1, 5))
    parser.add_argument(
        "--harness",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "qualification/direct-pty/matrix.py",
        help="TD4 matrix.py (may be in its separately published checkout)",
    )
    args = parser.parse_args()
    for path in (args.binary, args.harness):
        if not path.is_file():
            parser.error(f"required artifact is unavailable: {path}")
    if args.output.exists():
        parser.error(f"output must be fresh: {args.output}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    path = args.output.with_name(args.output.name + ".vectors.json")
    if path.exists():
        parser.error(f"vector evidence must be fresh: {path}")
    rows = list(vectors())
    with path.open("x", encoding="utf-8") as stream:
        stream.write(json.dumps(rows, ensure_ascii=False, indent=2) + "\n")
    print(
        f"TD2: {len(rows)} direct-PTY recovery rows; "
        "raw, kitty CSI-u and modifyOtherKeys case27 must replay the same "
        "original and preserve the edited next draft/caret.",
        flush=True,
    )
    os.execv(sys.executable, [
        sys.executable, str(args.harness.resolve()), str(args.binary.resolve()),
        "--vectors", str(path.resolve()), "--output", str(args.output.resolve()),
        "--jobs", str(args.jobs),
    ])


if __name__ == "__main__":
    host_process.enter()
    sys.exit(main())
