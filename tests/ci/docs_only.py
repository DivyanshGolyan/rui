"""Conservative documentation classification from the selector's resolved Git trees."""

from dataclasses import dataclass
from enum import Enum
import re
import subprocess


class ChangeKind(str, Enum):
    NORMAL = 'normal'
    DOCUMENTATION = 'documentation'


@dataclass(frozen=True)
class ChangedEntry:
    path: str
    status: str
    old_mode: str
    new_mode: str


_ROOT_DOCS = {'README.md', 'ARCHITECTURE.md', 'CODING_STANDARDS.md',
              'VERIFICATION.md', 'THIRD_PARTY_NOTICES.md', 'AGENTS.md', 'CLAUDE.md'}
_HEADER = re.compile(rb':([0-7]{6}) ([0-7]{6}) (?:[0-9a-f]{40}|[0-9a-f]{64}) (?:[0-9a-f]{40}|[0-9a-f]{64}) ([AMD])')
_MODES = {'A': ('000000', '100644'), 'M': ('100644', '100644'),
          'D': ('100644', '000000')}


def _entries(raw: bytes) -> list[ChangedEntry] | None:
    if not raw:
        return []
    fields = raw.split(b'\0')
    if fields.pop() != b'' or len(fields) % 2:
        return None
    entries = []
    for header, path in zip(fields[::2], fields[1::2]):
        match = _HEADER.fullmatch(header)
        if not match or not path:
            return None
        try:
            old, new, status = (part.decode('ascii') for part in match.groups())
            entries.append(ChangedEntry(path.decode('utf-8'), status, old, new))
        except UnicodeDecodeError:
            return None
    return entries


def _documentation_path(path: str) -> bool:
    if path in _ROOT_DOCS:
        return True
    parts = path.split('/')
    if len(parts) < 2 or any(not p or p.startswith('.') for p in parts[1:]):
        return False
    # Skills; .claude/ also holds hooks, settings and scripts, which run.
    if parts[0] == '.claude':
        return path.endswith('.md')
    # Research evidence and prototypes: no build target, workflow or test reads them.
    if parts[0] == 'research':
        return True
    if parts[0] != 'docs':
        return False
    if path.endswith('.md'):
        return True
    return ((parts[1] == 'assets' and path.endswith('.svg'))
            or (parts[1] == 'images' and path.endswith(('.png', '.svg'))))


def classify(base: str, head: str) -> ChangeKind:
    raw = subprocess.check_output([
        'git', 'diff', '--no-renames', '-z', '--raw', '--no-ext-diff', '--no-abbrev',
        base, head, '--',
    ])
    entries = _entries(raw)
    if entries and all((entry.old_mode, entry.new_mode) == _MODES[entry.status]
                       and _documentation_path(entry.path) for entry in entries):
        return ChangeKind.DOCUMENTATION
    return ChangeKind.NORMAL
