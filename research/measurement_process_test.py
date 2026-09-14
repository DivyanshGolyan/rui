#!/usr/bin/env python3
"""Failure-sensitive checks for the shared production-measurement collector."""

import pathlib
import subprocess
import sys
import unittest
from unittest import mock


sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from measurement_process import macos_footprint


def completed(stdout, returncode=0, stderr=""):
    return subprocess.CompletedProcess(
        ["/usr/bin/footprint", "-p", "1"],
        returncode,
        stdout=stdout,
        stderr=stderr,
    )


class FootprintTest(unittest.TestCase):
    def collect(self, report):
        with mock.patch(
            "measurement_process.subprocess.run",
            return_value=completed(report),
        ):
            return macos_footprint(1)

    def test_mixed_unit_rounding_does_not_invent_an_inconsistency(self):
        result = self.collect(
            "phys_footprint: 2 MB\nphys_footprint_peak: 2047 KB\n"
        )
        self.assertEqual(result["physical_footprint_bytes"], 2 * 1024**2)
        self.assertEqual(
            result["lifetime_peak_physical_footprint_bytes"], 2047 * 1024
        )

    def test_integral_byte_counters_are_exact(self):
        result = self.collect(
            "phys_footprint: 1 B\nphys_footprint_peak: 1 B\n"
        )
        self.assertEqual(result["physical_footprint_rounding_tolerance_bytes"], 0)
        self.assertEqual(
            result[
                "lifetime_peak_physical_footprint_rounding_tolerance_bytes"
            ],
            0,
        )

    def test_missing_malformed_nonpositive_and_inconsistent_counters_fail(self):
        reports = (
            "phys_footprint: 1 MB\n",
            "phys_footprint: 1 MB\nphys_footprint_peak: 1.2.3 MB\n",
            "phys_footprint: 0 B\nphys_footprint_peak: 1 B\n",
            "phys_footprint: 4 MB\nphys_footprint_peak: 1 KB\n",
        )
        for report in reports:
            with self.subTest(report=report):
                with self.assertRaisesRegex(RuntimeError, "stdout="):
                    self.collect(report)

    def test_command_failure_retains_output(self):
        with mock.patch(
            "measurement_process.subprocess.run",
            return_value=completed("raw output", returncode=1, stderr="denied"),
        ):
            with self.assertRaisesRegex(RuntimeError, "raw output"):
                macos_footprint(1)


if __name__ == "__main__":
    unittest.main()
