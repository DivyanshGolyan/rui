#!/usr/bin/env python3
"""Plan and assemble a GitHub Release for a promoted stable SHA.

Versions are 0.S.N: S is the Store schema version at the released commit and
N counts earlier releases with that schema. Equal S means an existing Store
opens; a new S means the Store must be reset. Runs from trusted main code.
"""
import argparse
from pathlib import Path
import re
import subprocess
import sys

TAG = re.compile(r"v0\.([0-9]+)\.([0-9]+)")
SCHEMA = re.compile(r"^pub const schema_version: u32 = ([0-9]+);$", re.M)
PLATFORMS = ("darwin-arm64", "linux-x86_64")


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout.strip()


def contains(sha, ancestor):
    return subprocess.run(["git", "merge-base", "--is-ancestor", ancestor, sha],
                          stderr=subprocess.DEVNULL).returncode == 0


def plan(sha):
    """The version to publish for sha, or None when it must not be released.

    Only commits stable contains are released. A SHA that already has a
    release tag, or that an existing release descends from, is skipped:
    releases never repeat or move backward.
    """
    git("fetch", "--quiet", "--tags", "origin", "+refs/heads/stable:refs/remotes/origin/stable")
    sha = git("rev-parse", "--verify", f"{sha}^{{commit}}")
    if not contains(git("rev-parse", "origin/stable"), sha):
        raise SystemExit(f"{sha} is not on stable; only promoted commits are released")
    releases = {}
    for tag in git("tag", "--list", "v0.*").split():
        if match := TAG.fullmatch(tag):
            releases[tag] = (int(match[1]), int(match[2]), git("rev-parse", f"{tag}^{{commit}}"))
    for tag, (_, _, commit) in releases.items():
        if contains(commit, sha):
            print(f"{tag} at {commit} already includes {sha}; nothing to release", file=sys.stderr)
            return None
    match = SCHEMA.search(git("show", f"{sha}:src/store.zig"))
    if not match:
        raise SystemExit("src/store.zig has no schema_version declaration")
    schema = int(match[1])
    patch = max((patch + 1 for minor, patch, _ in releases.values() if minor == schema), default=0)
    return f"0.{schema}.{patch}"


def installer(template, version, digests):
    """Fill the release installer template with its version and archive digests."""
    text = template.replace("@VERSION@", version)
    for platform in PLATFORMS:
        digest = digests[platform]
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise SystemExit(f"{platform} digest is not SHA-256 hex")
        text = text.replace(f"@SHA256_{platform.upper().replace('-', '_')}@", digest)
    if re.search(r"@[A-Z0-9_]+@", text):
        raise SystemExit("installer template has an unfilled placeholder")
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    planned = commands.add_parser("plan", help="print version=0.S.N for a stable SHA, or version= to skip")
    planned.add_argument("sha")
    assembled = commands.add_parser("installer", help="fill release/install.sh from SHA256SUMS")
    assembled.add_argument("version")
    assembled.add_argument("sums", type=Path)
    assembled.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.command == "plan":
        print(f"version={plan(args.sha) or ''}")
        return
    digests = {}
    for line in args.sums.read_text().splitlines():
        digest, name = line.split(maxsplit=1)
        for platform in PLATFORMS:
            if name.lstrip("*") == f"rui-{args.version}-{platform}.tar.gz":
                digests[platform] = digest
    if set(digests) != set(PLATFORMS):
        raise SystemExit(f"SHA256SUMS must list every platform archive for {args.version}")
    template = (Path(__file__).resolve().parents[2] / "release/install.sh").read_text()
    args.output.write_text(installer(template, args.version, digests))
    args.output.chmod(0o755)


if __name__ == "__main__":
    main()
