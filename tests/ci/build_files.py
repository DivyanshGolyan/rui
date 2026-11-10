#!/usr/bin/env python3
"""The build's Zig files: build.zig and the modules it imports from build/.

Checks that read the build read every file here, so moving code between
build modules cannot hide a target or a call from them.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
STEP = re.compile(r'b\.step\(\s*"([a-z0-9-]+)"')


def files(root=ROOT):
    return [root / "build.zig", *sorted((root / "build").glob("*.zig"))]


def source(root=ROOT):
    """Every build file's text, for checks that look for a call anywhere in the build."""
    return "\n".join(path.read_text() for path in files(root))


def steps(root=ROOT):
    """Each build target and the build file that defines it."""
    defined = {}
    for path in files(root):
        for name in STEP.findall(path.read_text()):
            defined[name] = path.relative_to(root).as_posix()
    return defined
