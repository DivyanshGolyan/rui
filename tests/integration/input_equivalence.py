#!/usr/bin/env python3
"""TD2 recovery equivalence through TD4's real, direct-PTY frontend driver.

Run with a built Rui and --output FRESH_DIRECTORY. TD3 owns Linux CI wiring;
TD4 owns the reusable harness. No parser or raw-Ctrl-R interception is copied
here. An unchanged renderer is expected to FAIL encoded recovery, not xfail it.
"""

import argparse
import json
import os
from pathlib import Path
import sys

import host_process  # noqa: F401, admits this fixture and builds its environment


def vectors():
    # Literal control/kitty/modifyOtherKeys vectors. ESC-prefix cannot encode
    # Ctrl-R without adding Alt; it is not an equivalent recovery gesture.
    # TD4 independently fixes original="original éZ", edited next draft/caret
    # and expected next submission="next cafXYé!" for this scenario.
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
        for split in range(1, len(data)):
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
    # Each row owns isolated HOME/Store/processes through TD4. Its manifest
    # retains vectors and binary/source identity along with exact wire bodies.
    # Chunk boundaries request separate writes, not separate OS read promises.
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
    # Transfer process/signal ownership to the shared driver, rather than
    # letting a wrapper die while its PTY workers continue. Keep vectors beside
    # the row evidence, including on interruption or assertion failure.
    os.execv(sys.executable, [
        sys.executable, str(args.harness.resolve()), str(args.binary.resolve()),
        "--vectors", str(path.resolve()), "--output", str(args.output.resolve()),
        "--jobs", str(args.jobs), "--surface", "direct",
    ])


if __name__ == "__main__":
    sys.exit(main())
