"""Provider error bodies in the corpus classify by their kind, and every refusal code the Responses codec names has a body or is listed as uncaptured."""
import json
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CORPUS = ROOT / 'src/testing/fixtures/provider-errors'
SOURCE = ROOT / 'src/model_adapter.zig'
CODEC = ROOT / 'src/codecs/responses.zig'
TABLE = re.search(r'const provider_error_corpus = \[_\]struct \{.*?\n\};', SOURCE.read_text(), re.DOTALL)
ENTRY = re.compile(r'\.file = "([^"]+)",\s*\.body = @embedFile\("testing/fixtures/provider-errors/([^"]+)"\)', re.DOTALL)
PROVENANCE = re.compile(r'\.provenance = \.(\w+),\s*\.source = ')
PROVENANCES = {'captured', 'captured_redacted', 'documented', 'reconstructed'}
REFUSAL_ENUM = re.search(r'const RefusalCode = enum \{(.*?)\n\};', CODEC.read_text(), re.DOTALL)
# Refusal codes with no corpus body yet. This list may only shrink: when a body lands for a code, delete the code here.
UNCAPTURED = {
    'organization_spend_limit_exceeded', 'project_spend_limit_exceeded', 'subscription_sharing_usage_limit_exceeded',
    'subscription_sharing_usage_unavailable', 'credit_balance_exhausted', 'cyber_policy', 'bio_policy',
    'misalignment_policy_violation', 'invalid_prompt', 'model_not_found',
}
# Codes the Responses codec reads that are not RefusalCode members but still classify a body.
EXTRA_CODES = {'context_length_exceeded'}


def refusal_codes():
    return set(re.findall(r'^\s*([a-z_][a-z0-9_]*),', REFUSAL_ENUM.group(1), re.MULTILINE)) | EXTRA_CODES


def named_codes(body):
    error = body.get('error', body) if isinstance(body, dict) else {}
    if not isinstance(error, dict):
        return set()
    return {error[field] for field in ('code', 'type') if isinstance(error.get(field), str)}


class ProviderErrorCorpus(unittest.TestCase):
    def test_corpus_files_and_table_entries_match(self):
        self.assertIsNotNone(TABLE, 'provider_error_corpus table not found in src/model_adapter.zig')
        entries = ENTRY.findall(TABLE.group(0))
        for name, embedded in entries:
            self.assertEqual(name, embedded, f'table file {name} embeds {embedded}')
        table = sorted(name for name, _ in entries)
        self.assertEqual(len(table), len(set(table)), 'duplicate table entries')
        corpus = sorted(path.name for path in CORPUS.iterdir() if path.is_file())
        self.assertEqual(corpus, table, 'corpus files and table entries differ')

    def test_every_entry_states_a_known_provenance(self):
        provenances = PROVENANCE.findall(TABLE.group(0))
        self.assertEqual(len(provenances), len(ENTRY.findall(TABLE.group(0))))
        for value in provenances:
            self.assertIn(value, PROVENANCES)

    def test_every_refusal_code_has_a_body_or_is_uncaptured(self):
        self.assertIsNotNone(REFUSAL_ENUM, 'RefusalCode enum not found in src/codecs/responses.zig')
        required = refusal_codes()
        self.assertGreater(len(required), 10, 'RefusalCode names were not parsed')
        covered = set()
        for path in CORPUS.iterdir():
            if path.is_file():
                covered |= named_codes(json.loads(path.read_text())) & required
        self.assertEqual(covered & UNCAPTURED, set(), 'covered codes must leave UNCAPTURED')
        self.assertEqual(UNCAPTURED - required, set(), 'UNCAPTURED names a code the codec does not read')
        missing = required - covered - UNCAPTURED
        self.assertEqual(missing, set(), 'refusal codes with no corpus body; capture one or add to UNCAPTURED')


if __name__ == '__main__':
    unittest.main()
