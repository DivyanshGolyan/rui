"""Every recorded provider error body is named by the model_adapter.zig table, and every table entry has a body."""
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CORPUS = ROOT / 'src/testing/fixtures/provider-errors'
SOURCE = ROOT / 'src/model_adapter.zig'
TABLE = re.search(r'const recorded_provider_errors = \[_\]struct \{.*?\n\};', SOURCE.read_text(), re.DOTALL)
ENTRY = re.compile(r'\.file = "([^"]+)",\s*\.body = @embedFile\("testing/fixtures/provider-errors/([^"]+)"\)', re.DOTALL)


class ProviderErrorCorpus(unittest.TestCase):
    def test_corpus_files_and_table_entries_match(self):
        self.assertIsNotNone(TABLE, 'recorded_provider_errors table not found in src/model_adapter.zig')
        entries = ENTRY.findall(TABLE.group(0))
        for name, embedded in entries:
            self.assertEqual(name, embedded, f'table file {name} embeds {embedded}')
        table = sorted(name for name, _ in entries)
        self.assertEqual(len(table), len(set(table)), 'duplicate table entries')
        corpus = sorted(path.name for path in CORPUS.iterdir() if path.is_file())
        self.assertEqual(corpus, table, 'corpus files and table entries differ')


if __name__ == '__main__':
    unittest.main()
