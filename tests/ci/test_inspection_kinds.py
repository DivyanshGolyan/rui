"""INS-13: inspection.md names every Activity row kind."""
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ACTIVITY = ROOT / 'src/activity_read.zig'
CONTRACT = ROOT / 'docs/contracts/inspection.md'
SECTION = '### Public Session activity'
KIND_ENUM = re.compile(r'pub const Kind = enum \{(.*?)\};', re.DOTALL)
COMMENT = re.compile(r'//[^\n]*')


def kinds(zig):
    """The tag names of the Activity `Kind` enum, in declaration order."""
    match = KIND_ENUM.search(zig)
    if match is None:
        raise ValueError('no `pub const Kind = enum { ... };` in src/activity_read.zig')
    body = COMMENT.sub('', match.group(1))
    return [tag.strip() for tag in body.split(',') if tag.strip()]


def section(text):
    """The Public Session activity section, up to the next heading of level 2 or 3."""
    lines = text.splitlines()
    start = next((n for n, line in enumerate(lines) if line.rstrip() == SECTION), None)
    if start is None:
        raise ValueError(f'no `{SECTION}` section in docs/contracts/inspection.md')
    end = next((n for n in range(start + 1, len(lines))
                if lines[n].startswith(('### ', '## '))), len(lines))
    return '\n'.join(lines[start:end])


def unnamed(tags, text):
    """Tags with no backtick-quoted mention in the section text; prose such as 'tool result' does not count."""
    return [tag for tag in tags if f'`{tag}`' not in text]


class InspectionKindsTest(unittest.TestCase):
    def test_every_activity_kind_is_named(self):
        cases = (
            ('all named', ['a', 'b'], '### Public Session activity\n`a` and `b`\n', []),
            ('one missing', ['a', 'b'], '### Public Session activity\n`a` only\n', ['b']),
            ('prose is not a name', ['tool_result'], '### Public Session activity\ntool result\n', ['tool_result']),
            ('stops at next heading', ['a', 'b'],
             '### Public Session activity\n`a`\n### Work state\n`b`\n', ['b']),
            ('empty enum', [], '### Public Session activity\n', []),
        )
        for name, tags, text, expected in cases:
            with self.subTest(case=name):
                self.assertEqual(unnamed(tags, section(text)), expected)
        self.assertEqual(kinds('pub const Kind = enum {\n    a, // note\n    b,\n};'), ['a', 'b'])
        self.assertEqual(kinds('pub const Kind = enum {};'), [])

        tags = kinds(ACTIVITY.read_text())
        self.assertTrue(tags, 'the Activity Kind enum has no tags')
        missing = unnamed(tags, section(CONTRACT.read_text()))
        self.assertEqual(missing, [], f'Activity kinds missing from {SECTION}: {", ".join(missing)}')


if __name__ == '__main__':
    unittest.main()
