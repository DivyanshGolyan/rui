#!/usr/bin/env python3
"""List open PRs sharing files with the committed branch before opening a PR,
and those whose added lines use a name the branch renames or removes."""
import argparse
import re
import subprocess
import sys

from conflict_alert import github, pages

# A top-level Zig or Python declaration, or a public Zig member of a nested
# container: the names other files can use.
DECLARATION = re.compile(r"^(?:(?:pub\s+)?(?:inline\s+|export\s+|extern\s+)?(?:fn|const|var)|def|class|\s+pub\s+(?:inline\s+)?(?:fn|const|var))"
                         r"\s+([A-Za-z_]\w*)")
SOURCES = ("*.zig", "*.py")
# The last two path segments of an https, ssh, scp-style or proxy remote URL.
REMOTE = re.compile(r"[:/]([^/:]+)/([^/:]+?)(?:\.git)?/?$")


def repo_from_remote(url):
    """`owner/name` from a remote URL: `gh repo view` uses GraphQL, which cloud sessions are refused."""
    match = REMOTE.search(url.strip())
    if not match:
        raise ValueError(f"Cannot read owner/name from the origin URL {url.strip()!r}")
    return f"{match[1]}/{match[2]}"


def origin_repo():
    return repo_from_remote(subprocess.check_output(["git", "remote", "get-url", "origin"], text=True))


def removed_names(diff, declared):
    """Names a removed line of `diff` declares that nothing in `declared`
    (every name the branch's tree declares) still does."""
    return {match[1] for line in diff.splitlines() if line.startswith("-") and not line.startswith("---")
            for match in [DECLARATION.match(line[1:])] if match} - declared


def used_names(patch, names):
    """The names among `names` an added line of a unified diff uses as a word."""
    added = "\n".join(line[1:] for line in (patch or "").splitlines() if line.startswith("+") and not line.startswith("+++"))
    return {name for name in names if re.search(rf"\b{re.escape(name)}\b", added)}


def overlaps(api, repo, branch, paths, removed=frozenset()):
    """Each other open PR that shares a path or whose added lines use a
    `removed` name: (number, shared paths, names it uses)."""
    result = []
    for pr in pages(api, f"repos/{repo}/pulls?state=open"):
        head = pr["head"]
        if head["ref"] == branch and (head["repo"] or {}).get("full_name") == repo:
            continue
        files = list(pages(api, f"repos/{repo}/pulls/{pr['number']}/files?"))
        if len(files) >= 3000:
            raise ValueError(f"PR #{pr['number']} has at least 3000 files; GitHub's file list may be incomplete")
        their_paths = {name for file in files for name in (file["filename"], file.get("previous_filename")) if name}
        shared = sorted(paths & their_paths)
        uses = sorted(set().union(*(used_names(file.get("patch"), removed) for file in files)))
        if shared or uses:
            result.append((pr["number"], shared, uses))
    return result


def branch_changes(base):
    """The committed branch's changed paths since `base`, and the names it removes."""
    paths = set(subprocess.check_output(
        ["git", "diff", "--name-only", "--no-renames", "-z", f"{base}...HEAD"]).decode().split("\0")) - {""}
    diff = subprocess.check_output(["git", "diff", "--no-renames", "-U0", f"{base}...HEAD", "--", *SOURCES], text=True)
    # git grep exits 1 when nothing matches.
    tree = subprocess.run(["git", "grep", "-h", "-E", r"^\s*(pub\s+)?(inline\s+|export\s+|extern\s+)?(fn|const|var|def|class)\s",
                           "HEAD", "--", *SOURCES], capture_output=True, text=True).stdout
    declared = {match[1] for line in tree.splitlines() for match in [DECLARATION.match(line)] if match}
    return paths, removed_names(diff, declared)


def report(found):
    for number, shared, uses in found:
        if shared:
            print(f"#{number} shares files: {', '.join(shared)}")
        if uses:
            print(f"#{number} uses names this branch renames or removes: {', '.join(uses)}; "
                  "fix it in this PR or land after it")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="origin/main", help="base for the committed branch diff")
    args = parser.parse_args()
    try:
        repo = origin_repo()
        branch = subprocess.check_output(["git", "branch", "--show-current"], text=True).strip()
        paths, removed = branch_changes(args.base)
        found = overlaps(github, repo, branch, paths, removed)
    except (subprocess.CalledProcessError, ValueError, KeyError) as error:
        print(f"Cannot check PR overlap: {error}", file=sys.stderr)
        return 1
    report(found)
    if not found:
        print("No open PR shares files or uses a removed name.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
