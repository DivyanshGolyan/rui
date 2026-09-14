"""Shared macOS physical-footprint collection for production measurement runners."""

import decimal
import pathlib
import re
import subprocess


HELPER_PATH = pathlib.Path(__file__).resolve()
REQUIREMENTS_PATH = HELPER_PATH.with_name("measurement-requirements.txt")
_SCALES = {"B": 1, "KB": 1024, "MB": 1024**2, "GB": 1024**3}


def macos_footprint(pid):
    result = subprocess.run(
        ["/usr/bin/footprint", "-p", str(pid)],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            "macOS footprint collection failed: "
            f"returncode={result.returncode} stdout={result.stdout!r} "
            f"stderr={result.stderr!r}"
        )

    def counter(name):
        match = re.search(
            rf"^\s*{re.escape(name)}:\s+([0-9]+(?:\.[0-9]+)?) "
            rf"({'|'.join(_SCALES)})\s*$",
            result.stdout,
            re.MULTILINE,
        )
        if match is None:
            raise RuntimeError(
                f"macOS footprint counter {name!r} is unavailable or malformed: "
                f"stdout={result.stdout!r} stderr={result.stderr!r}"
            )
        number = decimal.Decimal(match.group(1))
        if not number.is_finite() or number <= 0:
            raise RuntimeError(
                f"macOS footprint counter {name!r} is not positive and finite: "
                f"stdout={result.stdout!r} stderr={result.stderr!r}"
            )
        scale = _SCALES[match.group(2)]
        decimals = len(match.group(1).partition(".")[2])
        quantum = decimal.Decimal(scale) / (10**decimals)
        rounding_tolerance = (
            0
            if scale == 1 and decimals == 0
            else int(
                (quantum / 2).to_integral_value(rounding=decimal.ROUND_CEILING)
            )
        )
        return {
            "bytes": int(
                (number * scale).to_integral_value(
                    rounding=decimal.ROUND_HALF_UP
                )
            ),
            "rounding_tolerance_bytes": rounding_tolerance,
        }

    current = counter("phys_footprint")
    peak = counter("phys_footprint_peak")
    if (
        peak["bytes"] + peak["rounding_tolerance_bytes"]
        < current["bytes"] - current["rounding_tolerance_bytes"]
    ):
        raise RuntimeError(
            "macOS lifetime peak footprint is below current footprint beyond "
            f"display-rounding tolerance: stdout={result.stdout!r} "
            f"stderr={result.stderr!r}"
        )
    return {
        "physical_footprint_bytes": current["bytes"],
        "physical_footprint_rounding_tolerance_bytes": current[
            "rounding_tolerance_bytes"
        ],
        "lifetime_peak_physical_footprint_bytes": peak["bytes"],
        "lifetime_peak_physical_footprint_rounding_tolerance_bytes": peak[
            "rounding_tolerance_bytes"
        ],
    }
