#!/usr/bin/env python3
"""Fetch this promotion run's release executable for the native platform.

Promote's Release build uploads one archive per platform (release-build.yml).
The upgrade check and renderer contracts test that executable instead of
compiling their own ReleaseSafe rui, so the promotion tests the bytes it
publishes. Prints only the executable's path, after checking its release identity;
every diagnostic goes to stderr, and any failure exits non-zero.
"""
import argparse
import os
from pathlib import Path
import platform
import subprocess
import sys
import time

# Child output joins the diagnostics on file descriptor 2; stdout carries only the path.
STDERR = 2
PLATFORMS = {("Linux", "x86_64"): "linux-x86_64", ("Darwin", "arm64"): "darwin-arm64"}


# Transient artifact-service errors only: Release build has finished before
# any job that calls this starts, so the artifact already exists.
RETRY_DELAYS = (10, 30)


def download(run_id, repository, name, destination, sleep=time.sleep):
    for delay in (*RETRY_DELAYS, None):
        result = subprocess.run(["gh", "run", "download", run_id, "--repo", repository, "--name", name,
                                 "--dir", str(destination)], check=False, stdout=STDERR)
        if result.returncode == 0:
            return
        if delay is None:
            raise SystemExit(f"could not download artifact {name}")
        print(f"::warning::Artifact download failed; retrying in {delay}s", file=sys.stderr, flush=True)
        sleep(delay)


def fetch(run_id, repository, target, version, sha, destination, sleep=time.sleep):
    """Download, extract and identify one platform's release executable; return its path."""
    name = f"rui-{version}-{target}"
    destination.mkdir(parents=True, exist_ok=True)
    download(run_id, repository, f"rui-{target}", destination, sleep)
    extracted = subprocess.run(["tar", "-xzf", str(destination / f"{name}.tar.gz"), "-C", str(destination)],
                               check=False, stdout=STDERR)
    if extracted.returncode != 0:
        raise SystemExit(f"could not extract {name}.tar.gz")
    executable = (destination / name / "bin/rui").resolve()
    reported = subprocess.run([str(executable), "--version"], check=True, capture_output=True, text=True,
                              timeout=10).stdout
    if reported != f"rui {version} ({sha})\n":
        raise SystemExit(f"{executable} reports {reported!r}, not release {version} at {sha}")
    return executable


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("sha")
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    target = PLATFORMS.get((platform.system(), platform.machine()))
    if target is None:
        raise SystemExit(f"no release archive for {platform.system()} {platform.machine()}")
    # Stdout carries only the path; callers capture it, so diagnostics go to stderr.
    print(fetch(os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_REPOSITORY"], target, args.version, args.sha,
                args.destination))
    return 0


if __name__ == "__main__":
    sys.exit(main())
