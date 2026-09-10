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
