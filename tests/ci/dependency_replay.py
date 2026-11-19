"""The replayed SQLite pin change (commit 97af141) as build.zig.zon manifests, for selector tests."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = (ROOT / "build.zig.zon").read_text()

# The sqlite entry before and after commit 97af141, the bump that went red on test-store.
SQLITE_BEFORE = ('        .sqlite = .{\n'
                 '            .url = "https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip",\n'
                 '            .hash = "N-V-__8AAGVtrgCcOcmjrOJnagmnRyMrcKaOo09KbU-vu8w8",\n        },\n')
SQLITE_AFTER = ('        .sqlite = .{\n'
                '            .url = "https://www.sqlite.org/2026/sqlite-amalgamation-3540100.zip",\n'
                '            .hash = "N-V-__8AAETTsABEodUZZFAyfdAm9hEyqBXuLw9pRSO0vFh9",\n        },\n')


def with_entry(manifest, name, block):
    """The manifest with the dependency entry `name` replaced by `block`; raises if the entry is absent."""
    replaced, count = re.subn(rf"        \.{name} = \.\{{\n.*?\n        \}},\n", lambda _: block, manifest, count=1, flags=re.S)
    if count != 1:
        raise AssertionError(f"build.zig.zon has no dependency entry {name}")
    return replaced


def sqlite_bump():
    """(before, after) manifests for the replayed SQLite bump, built from the repository's manifest."""
    return with_entry(MANIFEST, "sqlite", SQLITE_BEFORE), with_entry(MANIFEST, "sqlite", SQLITE_AFTER)
