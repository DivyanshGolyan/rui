#!/usr/bin/env python3
"""Plan and assemble a GitHub Release for an admitted main SHA.

Versions are 0.S.N: S is the Store schema version at the released commit and
N counts earlier releases with that schema. The target build owns its supported
startup migration range; version punctuation is not migration policy. Runs from trusted main code.
"""
import argparse
import re
import subprocess
import sys
from itertools import pairwise
from pathlib import Path

import release_publication as publication
from release_numbers import digest_rows, drifted_row_fix

TAG = re.compile(r"v0\.([0-9]+)\.([0-9]+)")
SCHEMA = re.compile(r"^pub const schema_version: u32 = ([0-9]+);$", re.MULTILINE)
PUBLISH = re.compile(r"^@PUBLISH@\n", re.MULTILINE)
PLATFORMS = ("darwin-arm64", "linux-x86_64")


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout.strip()


def contains(sha, ancestor):
    return subprocess.run(["git", "merge-base", "--is-ancestor", ancestor, sha],
                          check=False, stderr=subprocess.DEVNULL).returncode == 0


def resolve_sha(sha):
    if not re.fullmatch(r"[0-9a-fA-F]{7,40}", sha):
        raise SystemExit("release source must be a commit SHA, not a ref")
    return git("rev-parse", "--verify", "--end-of-options", f"{sha}^{{commit}}")


def release_state(sha):
    git("fetch", "--quiet", "--tags", "origin", "+refs/heads/main:refs/remotes/origin/main")
    sha = resolve_sha(sha)
    main = git("rev-parse", "origin/main")
    if not contains(main, sha):
        raise SystemExit(f"{sha} is not on main; only admitted commits are released")
    releases = {}
    for line in git("ls-remote", "--tags", "origin", "refs/tags/v0.*").splitlines():
        target, ref = line.split()
        tag = ref.removeprefix("refs/tags/")
        if match := TAG.fullmatch(tag):
            releases[tag] = (int(match[1]), int(match[2]), git("rev-parse", f"{target}^{{commit}}"))
    records = {}
    for record in publication.inventory():
        tag = record["tag_name"]
        if not (match := TAG.fullmatch(tag)):
            continue
        if tag in records:
            raise SystemExit(f"duplicate release records for {tag}")
        records[tag] = record
        if tag not in releases:
            if not record["draft"]:
                raise SystemExit(f"published release {tag} has no tag")
            target = record["target_commitish"]
            if not re.fullmatch(r"[0-9a-f]{40}", target):
                raise SystemExit(f"draft {tag} must name an immutable full commit SHA")
            releases[tag] = (int(match[1]), int(match[2]), resolve_sha(target))
        elif record["draft"] and record["target_commitish"] != releases[tag][2]:
            raise SystemExit(f"draft {tag} target does not match its tag SHA")
    for tag, (_, _, commit) in releases.items():
        if not contains(main, commit):
            raise SystemExit(f"{tag} at {commit} has divergent history outside main")
        if not contains(sha, commit) and not contains(commit, sha):
            raise SystemExit(f"{tag} at {commit} has divergent history from {sha}")
    ordered = sorted(releases, key=lambda tag: releases[tag][:2])
    for previous, current in pairwise(ordered):
        if not contains(releases[current][2], releases[previous][2]):
            raise SystemExit(f"release history rewinds from {previous} to {current}")
    return sha, releases, records


def covering_release(sha, releases, records):
    published = [tag for tag, record in records.items()
                 if not record["draft"] and not record["prerelease"]
                 and contains(releases[tag][2], sha)]
    if not published:
        return None
    tag = max(published, key=lambda tag: releases[tag][:2])
    publication.verify_release(tag[1:], records[tag])
    return tag


def plan(sha):
    """Number admitted main commits, reusing an interrupted release's reservation."""
    sha, releases, records = release_state(sha)
    if tag := covering_release(sha, releases, records):
        print(f"{tag} at {releases[tag][2]} already includes {sha}; nothing to release", file=sys.stderr)
        return None
    for tag, (_, _, commit) in releases.items():
        if commit != sha and contains(commit, sha):
            raise SystemExit(f"{sha} would rewind pending release {tag} at {commit}")
    path = "src/store/schema.zig" if git("ls-tree", "--name-only", sha, "--", "src/store/schema.zig") else "src/store.zig"
    match = SCHEMA.search(git("show", f"{sha}:{path}"))
    if not match:
        raise SystemExit(f"{path} has no schema_version declaration")
    schema = int(match[1])
    if releases and schema < max(minor for minor, _, _ in releases.values()):
        raise SystemExit(f"{sha} would release a lower schema and rewind the release channel")
    published = {tag: releases[tag] for tag, record in records.items() if not record["draft"]}
    refuse_drifted_schema(sha, path, schema, published)
    reserved = [tag for tag, (_, _, commit) in releases.items() if commit == sha]
    if reserved:
        if len(reserved) != 1:
            raise SystemExit(f"{sha} has multiple release versions reserved")
        tag = reserved[0]
        if releases[tag][0] != schema:
            raise SystemExit(f"{tag} does not match {sha}'s schema {schema}")
        if releases[tag][:2] != max(value[:2] for value in releases.values()):
            raise SystemExit(f"{tag} would rewind a newer release version")
        if tag in records and records[tag]["prerelease"]:
            raise SystemExit(f"{tag} is a prerelease, not the main release channel")
        return tag[1:]
    patch = max((patch + 1 for minor, patch, _ in releases.values() if minor == schema), default=0)
    return f"0.{schema}.{patch}"


def repair(sha):
    """Repair only from verified public releases, never from an unshipped tag."""
    sha, releases, records = release_state(sha)
    tag = covering_release(sha, releases, records)
    if tag is None:
        raise SystemExit(f"{sha} has no completed public release to repair stable from")
    publication.repair_stable(releases[tag][2])


def publish(version, sha, directory, notes):
    planned = plan(sha)
    if planned is None:
        repair(sha)
        return
    if planned != version:
        raise SystemExit(f"release identity changed: planned {version}, now {planned}")
    sha = resolve_sha(sha)
    publication.publish(version, sha, directory, notes)
    publication.repair_stable(sha)


def refuse_drifted_schema(sha, path, schema, releases):
    """Refuse to ship schema S again with a different bootstrap than its last release.

    Schema PRs share main's unreleased number and update its digest in place,
    so a promotion between two such edits ships S with one digest while main
    holds another. Releasing main as S again would publish a Store format that
    refuses the Stores S already created.
    """
    shipped = [tag for tag, (minor, _, _) in releases.items() if minor == schema]
    if not shipped:
        return
    last = max(shipped, key=lambda tag: releases[tag][1])
    released_sha = releases[last][2]
    if not git("ls-tree", "--name-only", released_sha, "--", path):
        return
    released = digest_rows(git("show", f"{released_sha}:{path}")).get(schema)
    current = digest_rows(git("show", f"{sha}:{path}")).get(schema)
    if released is not None and current is not None and released != current:
        raise SystemExit(f"{sha} would ship {last}'s schema with another bootstrap; "
                         + drifted_row_fix(schema, released, current))


def installer(template, version, digests, publish):
    """Fill the release installer template: its version, archive digests and
    the shared publication fragment (release/publish.sh) at @PUBLISH@."""
    if re.search(r"@[A-Z0-9_]+@", publish):
        raise SystemExit("release/publish.sh must not contain placeholders")
    text, count = PUBLISH.subn(lambda _: publish, template)
    if count != 1:
        raise SystemExit("installer template must contain @PUBLISH@ exactly once")
    text = text.replace("@VERSION@", version)
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
    planned = commands.add_parser("plan", help="print version and immutable main SHA, or an empty version to skip")
    planned.add_argument("sha")
    published = commands.add_parser("publish", help="resume and publish a complete release, then advance stable")
    published.add_argument("version")
    published.add_argument("sha")
    published.add_argument("directory", type=Path)
    published.add_argument("notes", type=Path)
    repaired = commands.add_parser("repair", help="repair stable after an already completed release")
    repaired.add_argument("sha")
    assembled = commands.add_parser("installer", help="fill release/install.sh from SHA256SUMS")
    assembled.add_argument("version")
    assembled.add_argument("sums", type=Path)
    assembled.add_argument("output", type=Path)
    assembled.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[2],
                           help="checkout whose executable assets the installer will publish")
    args = parser.parse_args()
    if args.command == "plan":
        print(f"version={plan(args.sha) or ''}")
        print(f"sha={resolve_sha(args.sha)}")
        return
    if args.command == "publish":
        publish(args.version, args.sha, args.directory, args.notes)
        return
    if args.command == "repair":
        repair(args.sha)
        return
    digests = {}
    for line in args.sums.read_text().splitlines():
        digest, name = line.split(maxsplit=1)
        for platform in PLATFORMS:
            if name.lstrip("*") == f"rui-{args.version}-{platform}.tar.gz":
                digests[platform] = digest
    if set(digests) != set(PLATFORMS):
        raise SystemExit(f"SHA256SUMS must list every platform archive for {args.version}")
    root = args.source_root
    template = (root / "release/install.sh").read_text()
    fragment = (root / "release/publish.sh").read_text()
    args.output.write_text(installer(template, args.version, digests, fragment))
    args.output.chmod(0o755)


if __name__ == "__main__":
    main()
