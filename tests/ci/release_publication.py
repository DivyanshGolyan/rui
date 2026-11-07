"""Publish complete immutable releases, then repair the stable compatibility pointer."""
import hashlib
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path
from urllib.parse import quote


def gh(*args, input=None, output=None):
    command = ["gh", *map(str, args)]
    if output is not None:
        with Path(output).open("wb") as destination:
            subprocess.run(command, check=True, stdout=destination)
        return ""
    return subprocess.run(command, check=True, stdout=subprocess.PIPE, text=True, input=input).stdout


def _json(*args, payload=None):
    options = {} if payload is None else {"input": json.dumps(payload)}
    if payload is not None:
        args = (*args, "--input", "-")
    try:
        return json.loads(gh("api", *args, **options))
    except json.JSONDecodeError as error:
        raise SystemExit(f"invalid GitHub resource response: {error}") from error


def _release_path(release_id):
    if type(release_id) is not int or release_id <= 0:
        raise SystemExit("release resource must have a positive integer ID")
    return f"repos/{_repository()}/releases/{release_id}"


def git(*args):
    return subprocess.run(["git", *args], check=True,
                          capture_output=True, text=True).stdout.strip()


def _repository():
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise SystemExit("GITHUB_REPOSITORY must name the release repository")
    return repository


def expected_assets(version):
    if not re.fullmatch(r"0\.[0-9]+\.[0-9]+", version):
        raise SystemExit(f"invalid release version: {version}")
    return {
        *(f"rui-{version}-{platform}.tar.gz"
          for platform in ("linux-x86_64", "linux-arm64", "darwin-arm64")),
        *(f"rui-{version}-linux-{arch}-debug.tar.gz" for arch in ("x86_64", "arm64")),
        f"rui-{version}.tgz",
        *(f"rui-{platform}-{version}.tgz"
          for platform in ("linux-x64", "linux-arm64", "darwin-arm64")),
        "SHA256SUMS", "install.sh",
    }


def inventory():
    """Read every release, including drafts; API errors must not become absence."""
    try:
        pages = json.loads(gh("api", "--paginate", "--slurp",
                              f"repos/{_repository()}/releases"))
    except json.JSONDecodeError as error:
        raise SystemExit(f"invalid release inventory: {error}") from error
    if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
        raise SystemExit("release inventory must be paginated REST release arrays")
    records = [record for page in pages for record in page]
    if any(not isinstance(record, dict) or not isinstance(record.get("tag_name"), str)
           or type(record.get("draft")) is not bool for record in records):
        raise SystemExit("release inventory contains an invalid REST release record")
    return records


def _record(version):
    matches = [record for record in inventory() if record["tag_name"] == f"v{version}"]
    if len(matches) > 1:
        raise SystemExit(f"multiple releases claim v{version}")
    return matches[0] if matches else None


def _asset_names(version, record, *, unfinished=False):
    _release_path(record.get("id"))
    if record.get("tag_name") != f"v{version}" or type(record.get("draft")) is not bool:
        raise SystemExit(f"invalid release record for v{version}")
    assets = record.get("assets")
    if not isinstance(assets, list) or any(
        not isinstance(asset, dict) or not isinstance(asset.get("name"), str)
        or type(asset.get("id")) is not int or asset["id"] <= 0
        or (not unfinished and asset.get("state") != "uploaded") for asset in assets
    ):
        raise SystemExit(f"v{version} has invalid or unfinished assets")
    names = [asset["name"] for asset in assets]
    if len(names) != len(set(names)) or len({asset["id"] for asset in assets}) != len(assets):
        raise SystemExit(f"v{version} has duplicate asset names or IDs")
    return set(names)


def _check_names(version, names):
    expected = expected_assets(version)
    if names != expected:
        raise SystemExit(f"v{version} incomplete asset set; "
                         f"missing={sorted(expected - names)}, unexpected={sorted(names - expected)}")


def _verify_directory(version, directory):
    _check_names(version, {path.name for path in directory.iterdir()})
    for name in expected_assets(version):
        path = directory / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
            raise SystemExit(f"v{version} asset is not a nonempty regular file: {name}")
    archives = {name for name in expected_assets(version) if name.endswith((".tar.gz", ".tgz"))}
    digests = {}
    for line in (directory / "SHA256SUMS").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-fA-F]{64}) [ *](\S+)", line)
        if not match or match[2] in digests:
            raise SystemExit(f"v{version} has malformed or duplicate SHA256SUMS entries")
        digests[match[2]] = match[1].lower()
    if set(digests) != archives:
        raise SystemExit(f"v{version} SHA256SUMS must cover every archive exactly")
    for name, expected in digests.items():
        digest = hashlib.sha256()
        with (directory / name).open("rb") as asset:
            for chunk in iter(lambda: asset.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != expected:
            raise SystemExit(f"v{version} digest mismatch: {name}")


def verify_release(version, record):
    """Check the full remote asset set and its bytes, whether public or draft."""
    _check_names(version, _asset_names(version, record))
    with tempfile.TemporaryDirectory(prefix="rui-release-") as scratch:
        for asset in record["assets"]:
            gh("api", f"repos/{_repository()}/releases/assets/{asset['id']}",
               "--header", "Accept: application/octet-stream", output=Path(scratch) / asset["name"])
        _verify_directory(version, Path(scratch))


def _commit(sha):
    if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", sha):
        raise SystemExit("release target must be a full immutable commit SHA")
    if git("rev-parse", "--verify", f"{sha}^{{commit}}") != sha:
        raise SystemExit(f"release target is not a commit: {sha}")
    return sha


def _remote_tag(version):
    tag = f"refs/tags/v{version}"
    refs = {}
    for line in git("ls-remote", "origin", tag, f"{tag}^{{}}").splitlines():
        value, ref = line.split()
        refs[ref] = value
    return refs.get(f"{tag}^{{}}", refs.get(tag))


def _guard_target(version, sha, record):
    tag_sha = _remote_tag(version)
    if tag_sha is not None and tag_sha != sha:
        raise SystemExit(f"v{version} tag points to {tag_sha}, not {sha}")
    if record is not None:
        if record["draft"]:
            # Draft releases need not create their tag until they become public.
            if record.get("target_commitish") != sha:
                raise SystemExit(f"v{version} draft target is not immutable SHA {sha}")
        elif tag_sha is None:
            raise SystemExit(f"published v{version} has no remote tag")
    return tag_sha


def _identity(version, sha, record, release_id=None):
    if not isinstance(record, dict):
        raise SystemExit(f"invalid release resource for v{version}")
    _release_path(record.get("id"))
    if release_id is not None and record["id"] != release_id:
        raise SystemExit(f"v{version} release resource ID changed")
    if record.get("tag_name") != f"v{version}" or type(record.get("draft")) is not bool:
        raise SystemExit(f"invalid release identity for v{version}")
    _guard_target(version, sha, record)
    return record


def _refresh(version, sha, release_id):
    return _identity(version, sha, _json(_release_path(release_id)), release_id)


def _upload_url(record, name):
    base = f"https://uploads.github.com/{_release_path(record['id'])}/assets"
    if record.get("upload_url") != base + "{?name,label}":
        raise SystemExit("release resource has an unexpected upload URL")
    return base + "?name=" + quote(name, safe="")


def publish(version, sha, directory, notes):
    """Use the acknowledged release ID, never a collection index, during publication."""
    _verify_directory(version, directory)
    sha = _commit(sha)
    record = _record(version)
    _guard_target(version, sha, record)
    if record is None:
        record = _json("--method", "POST", f"repos/{_repository()}/releases", payload={
            "tag_name": f"v{version}", "target_commitish": sha, "draft": True,
            "name": f"Rui {version}", "body": notes.read_text(),
        })
    record = _identity(version, sha, record)
    release_id = record["id"]
    record = _refresh(version, sha, release_id)
    if not record["draft"]:
        verify_release(version, record)
        return
    unexpected = _asset_names(version, record, unfinished=True) - expected_assets(version)
    if unexpected:
        raise SystemExit(f"v{version} draft has unexpected assets: {sorted(unexpected)}")
    for name in sorted(expected_assets(version)):
        record = _refresh(version, sha, release_id)
        if not record["draft"]:
            verify_release(version, record)
            return
        _asset_names(version, record, unfinished=True)
        upload_url = _upload_url(record, name)
        for asset in record["assets"]:
            if asset["name"] == name:
                gh("api", "--method", "DELETE", f"repos/{_repository()}/releases/assets/{asset['id']}")
        asset = _json("--method", "POST", upload_url,
                      "--header", "Content-Type: application/octet-stream", "--input", directory / name)
        if (not isinstance(asset, dict) or type(asset.get("id")) is not int or asset["id"] <= 0
                or asset.get("name") != name or asset.get("state") != "uploaded"):
            raise SystemExit(f"v{version} upload did not acknowledge completed asset {name}")
    record = _refresh(version, sha, release_id)
    verify_release(version, record)
    if record["draft"]:
        record = _json("--method", "PATCH", _release_path(release_id),
                       payload={"draft": False, "make_latest": "true", "body": notes.read_text()})
        record = _identity(version, sha, record, release_id)
    if record["draft"]:
        raise SystemExit(f"v{version} is not public after publication")
    verify_release(version, record)


def _ancestor(ancestor, commit):
    result = subprocess.run(["git", "merge-base", "--is-ancestor", ancestor, commit],
                            check=False, capture_output=True, text=True)
    if result.returncode not in (0, 1):
        result.check_returncode()
    return result.returncode == 0


def repair_stable(sha):
    """Fast-forward stable after a verified publication, never rewind or force it."""
    remote = git("ls-remote", "--heads", "origin", "refs/heads/main", "refs/heads/stable")
    refs = dict(reversed(line.split()) for line in remote.splitlines())
    if "refs/heads/main" not in refs:
        raise SystemExit("origin/main is missing")
    refspecs = ["+refs/heads/main:refs/remotes/origin/main"]
    if "refs/heads/stable" in refs:
        refspecs.append("+refs/heads/stable:refs/remotes/origin/stable")
    fetch = ["fetch", "--quiet", "--no-tags"]
    if git("rev-parse", "--is-shallow-repository") == "true":
        fetch.append("--unshallow")
    git(*fetch, "origin", *refspecs)
    sha = _commit(sha)
    main = git("rev-parse", "refs/remotes/origin/main")
    if not _ancestor(sha, main):
        raise SystemExit(f"{sha} is not on origin/main")
    if "refs/heads/stable" in refs:
        stable = git("rev-parse", "refs/remotes/origin/stable")
        if not _ancestor(stable, main):
            raise SystemExit("stable diverges from origin/main")
        if _ancestor(sha, stable):
            return
        if not _ancestor(stable, sha):
            raise SystemExit("stable diverges from the published commit")
    git("push", "origin", f"{sha}:refs/heads/stable")
    git("update-ref", "refs/remotes/origin/stable", sha)
