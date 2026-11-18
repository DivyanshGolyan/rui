#!/usr/bin/env python3
"""Fetch this promotion run's release executable for the native platform.

Promote's Release build uploads one archive per platform (release-build.yml).
The upgrade check and renderer contracts test that executable instead of
compiling their own ReleaseSafe rui, so the promotion tests the bytes it
publishes. Prints the executable's path after checking its release identity.
"""
import argparse
import os
from pathlib import Path
import platform
import subprocess
import sys
import time

PLATFORMS = {("Linux", "x86_64"): "linux-x86_64", ("Darwin", "arm64"): "darwin-arm64"}


def download(name, destination):
    for delay in (10, 30, None):
        result = subprocess.run(["gh", "run", "download", os.environ["GITHUB_RUN_ID"],
                                 "--repo", os.environ["GITHUB_REPOSITORY"], "--name", name,
                                 "--dir", str(destination)], check=False)
        if result.returncode == 0:
            return
        if delay is None:
            raise SystemExit(f"could not download artifact {name}")
        print(f"::warning::Artifact download failed; retrying in {delay}s", flush=True)
        time.sleep(delay)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("sha")
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    target = PLATFORMS.get((platform.system(), platform.machine()))
    if target is None:
        raise SystemExit(f"no release archive for {platform.system()} {platform.machine()}")
    name = f"rui-{args.version}-{target}"
    args.destination.mkdir(parents=True, exist_ok=True)
    download(f"rui-{target}", args.destination)
    subprocess.run(["tar", "-xzf", str(args.destination / f"{name}.tar.gz"), "-C", str(args.destination)], check=True)
    executable = (args.destination / name / "bin/rui").resolve()
    reported = subprocess.run([str(executable), "--version"], check=True, capture_output=True, text=True,
                              timeout=10).stdout
    if reported != f"rui {args.version} ({args.sha})\n":
        raise SystemExit(f"{executable} reports {reported!r}, not release {args.version} at {args.sha}")
    print(executable)
    return 0


if __name__ == "__main__":
    sys.exit(main())
