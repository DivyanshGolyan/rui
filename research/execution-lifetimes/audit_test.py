"""Negative controls for accepting incomplete research evidence; no benchmarks."""
import copy
import json
from pathlib import Path
import unittest

from summarize import audit

HERE = Path(__file__).resolve().parent


class EvidenceAudit(unittest.TestCase):
    def setUp(self):
        self.matrix = json.loads((HERE / 'results.json').read_text())
        self.checks = json.loads((HERE / 'checks.json').read_text())

    def test_recorded_evidence_passes(self):
        self.assertEqual(len(audit(self.matrix, self.checks)), 30)

    def test_early_model_requires_release_without_losing_capture(self):
        mutations = {
            'curl retained': ('curl_live', lambda before, case: before['curl_live'], 'libcurl release'),
            'request handles retained': ('owned_fds', lambda before, case: before['owned_fds'], 'capture descriptors'),
            'request bytes retained': ('scratch_logical', lambda before, case: before['scratch_logical'], 'capture bytes'),
            'capture handles closed': ('owned_fds', lambda before, case: 0, 'capture descriptors'),
            'capture bytes lost': ('scratch_logical', lambda before, case: 0, 'capture bytes'),
            'custody released': ('occupied', lambda before, case: 0, 'Custody released'),
        }
        for index, case in enumerate(self.matrix['cases']):
            if (case['kind'], case['variant']) != ('model', 'early'):
                continue
            for label, (field, value, error) in mutations.items():
                with self.subTest(count=case['count'], size=case['payload_bytes'], mutation=label):
                    changed = copy.deepcopy(self.matrix)
                    stages = {s['stage']: s for s in changed['cases'][index]['samples']}
                    stages['delayed_validation'][field] = value(stages['sealed_waiting'], case)
                    with self.assertRaisesRegex(ValueError, error):
                        audit(changed, self.checks)

    def test_model_release_does_not_require_recorded_allocation_amount(self):
        for case in self.matrix['cases']:
            if (case['kind'], case['variant']) == ('model', 'early'):
                stages = {s['stage']: s for s in case['samples']}
                stages['delayed_validation']['curl_live'] = stages['sealed_waiting']['curl_live'] - 1
        self.assertEqual(len(audit(self.matrix, self.checks)), 30)

    def test_duplicate_model_cell_cannot_replace_missing_cell(self):
        self.matrix['cases'][0] = copy.deepcopy(self.matrix['cases'][1])
        self.assertEqual(len(self.matrix['cases']), 30)
        with self.assertRaisesRegex(ValueError, 'distinct cells'):
            audit(self.matrix, self.checks)

    def test_all_transports_observed_snapshot_is_required(self):
        case = self.matrix['cases'][0]
        case['samples'] = [s for s in case['samples'] if s['stage'] != 'transport_active']
        with self.assertRaisesRegex(ValueError, 'lifecycle snapshot'):
            audit(self.matrix, self.checks)

    def test_empty_callback_results_are_not_a_pass(self):
        self.checks['positive'] = {}
        with self.assertRaisesRegex(ValueError, 'callback control'):
            audit(self.matrix, self.checks)

    def test_missing_production_parser_population_is_rejected(self):
        self.checks['production_capture'] = []
        with self.assertRaisesRegex(ValueError, 'parser population'):
            audit(self.matrix, self.checks)


if __name__ == '__main__':
    unittest.main()
