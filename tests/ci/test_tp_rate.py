"""The weekly true-positive rate counts labelled causes only, by the ISO week each issue closed."""
from pathlib import Path
import re
import unittest

from tp_rate import CAUSES, PREFIX, table, weeks

LANDING = Path(__file__).resolve().parents[2] / "docs/agents/landing.md"


def issue(number, closed_at, *causes, extra=("ci-red",)):
    return {"number": number, "closedAt": closed_at,
            "labels": [{"name": name} for name in (*extra, *(f"cause:{cause}" for cause in causes))]}


class WeeksTest(unittest.TestCase):
    def test_rates_exclude_unlabelled_and_ambiguous_issues(self):
        rows = weeks([
            issue(1, "2026-11-02T00:00:00Z", "real"),
            issue(2, "2026-11-03T10:00:00Z", "compile"),
            issue(3, "2026-11-04T10:00:00Z", "stale"),
            issue(4, "2026-11-05T10:00:00Z", "flake"),
            issue(5, "2026-11-06T10:00:00Z"),
            issue(6, "2026-11-07T10:00:00Z", "real", "flake"),
            issue(7, "2026-11-07T11:00:00Z", extra=("ci-red", "cause:unknown")),
        ])
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual((row["closed"], row["labelled"], row["real"], row["compile"]), (7, 4, 1, 1))
        self.assertEqual(row["unlabelled"], [5, 6, 7])
        self.assertEqual((row["strict"], row["broad"]), (0.25, 0.5))

    def test_weeks_are_iso_weeks_of_the_close_in_utc(self):
        # Sunday 2026-11-08 23:59 UTC is still W45; Monday 00:00 starts W46.
        rows = weeks([
            issue(1, "2026-11-08T23:59:59Z", "real"),
            issue(2, "2026-11-09T00:00:00Z", "stale"),
            issue(3, "2026-12-31T12:00:00Z", "infra"),  # ISO week 53 of 2026
            issue(4, None, "real"),  # still open: no week
        ])
        self.assertEqual([row["week"] for row in rows], ["2026-W45", "2026-W46", "2026-W53"])
        self.assertEqual([row["strict"] for row in rows], [1.0, 0.0, 0.0])

    def test_a_week_with_nothing_labelled_has_no_rate_rather_than_zero(self):
        rows = weeks([issue(9, "2026-11-10T00:00:00Z")])
        self.assertIsNone(rows[0]["strict"])
        self.assertIn("| 2026-W46 | 1 | 0 | 0 | 0 | - | - | #9 |", table(rows))

    def test_the_landing_guide_names_exactly_the_counted_causes(self):
        named = set(re.findall(re.escape(PREFIX) + r"([a-z]+)", LANDING.read_text()))
        self.assertEqual(named, set(CAUSES))


if __name__ == "__main__":
    unittest.main()
