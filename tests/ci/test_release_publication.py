import copy
import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock
from urllib.parse import parse_qs, urlparse

import release_publication as publication

VERSION = "0.48.3"
TAG = f"v{VERSION}"
ASSETS = {
    "rui-0.48.3-linux-x86_64.tar.gz",
    "rui-0.48.3-linux-arm64.tar.gz",
    "rui-0.48.3-darwin-arm64.tar.gz",
    "rui-0.48.3-linux-x86_64-debug.tar.gz",
    "rui-0.48.3-linux-arm64-debug.tar.gz",
    "rui-0.48.3.tgz",
    "rui-linux-x64-0.48.3.tgz",
    "rui-linux-arm64-0.48.3.tgz",
    "rui-darwin-arm64-0.48.3.tgz",
    "SHA256SUMS",
    "install.sh",
}


def git(*args):
    return subprocess.run(["git", *args], check=True,
                          capture_output=True, text=True).stdout.strip()


def artifacts(label="first"):
    files = {name: f"{label}: {name}\n".encode() for name in ASSETS - {"SHA256SUMS"}}
    files["SHA256SUMS"] = "".join(
        f"{hashlib.sha256(files[name]).hexdigest()}  {name}\n"
        for name in sorted(files) if name.endswith((".tar.gz", ".tgz"))
    ).encode()
    return files


class RepositoryTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.addCleanup(os.chdir, os.getcwd())
        self.root = Path(scratch.name)
        git("init", "--quiet", "--bare", "-b", "main", str(self.root / "remote.git"))
        git("clone", "--quiet", str(self.root / "remote.git"), str(self.root / "work"))
        os.chdir(self.root / "work")
        git("config", "user.name", "test")
        git("config", "user.email", "test@example.invalid")
        self.commit_count = 0
        self.first = self.commit()
        self.second = self.commit()
        self.third = self.commit()
        git("push", "--quiet", "origin", "HEAD:refs/heads/main")

    def commit(self):
        self.commit_count += 1
        git("commit", "--quiet", "--allow-empty", "-m", f"fixture {self.commit_count}")
        return git("rev-parse", "HEAD")

    def tag(self, sha, annotated=False):
        if annotated:
            git("tag", "-a", TAG, sha, "-m", "release")
            git("push", "--quiet", "origin", f"refs/tags/{TAG}")
        else:
            git("push", "--quiet", "origin", f"{sha}:refs/tags/{TAG}")

    def stable(self):
        rows = git("ls-remote", "origin", "refs/heads/stable").split()
        return rows[0] if rows else None


class GitHub:
    """REST collections and immutable resources have independent visibility."""

    def __init__(self):
        self.records = {}
        self.files = {}
        self.asset_ids = {}
        self.asset_states = {}
        self.next_asset_id = 100
        self.calls = []
        self.upload_count = 0
        self.fail_upload_after = None
        self.corrupt_upload = None
        self.fail_after_publish = False
        self.fail_after_create = False
        self.hide_created_from_inventory = False
        self.stale_inventory = None

    def add(self, sha, files=None, draft=True):
        self.records[TAG] = {"id": 1, "tag_name": TAG, "draft": draft,
                             "target_commitish": sha,
                             "upload_url": "https://uploads.github.com/repos/owner/rui/releases/1/assets{?name,label}"}
        self.files[TAG] = dict(files or {})
        self.asset_ids.clear()
        self.asset_states.clear()

    def record(self):
        record = copy.deepcopy(self.records[TAG])
        for name in self.files[TAG]:
            if name not in self.asset_ids:
                self.next_asset_id += 1
                self.asset_ids[name] = self.next_asset_id
        record["assets"] = [{"id": self.asset_ids[name], "name": name,
                             "state": self.asset_states.get(name, "uploaded"), "size": len(data)}
                            for name, data in self.files[TAG].items()]
        return record

    @staticmethod
    def action(args):
        if "--paginate" in args:
            return "inventory"
        method = args[args.index("--method") + 1] if "--method" in args else "GET"
        if method == "DELETE":
            return "delete"
        if method == "PATCH":
            return "edit"
        if method == "POST":
            return "upload" if any("uploads.github.com" in str(arg) for arg in args) else "create"
        return "download" if "Accept: application/octet-stream" in args else "get"

    def __call__(self, *args, input=None, output=None):
        self.calls.append(args)
        action = self.action(args)
        if action == "inventory":
            if self.stale_inventory is not None:
                return json.dumps([self.stale_inventory])
            records = [self.record()] if TAG in self.records and not self.hide_created_from_inventory else []
            return json.dumps([records])
        if args[0] != "api":
            raise AssertionError(f"lifecycle must use REST resources: {args}")
        path = next(arg for arg in args[1:] if str(arg).startswith(("repos/", "https://")))
        if action == "create":
            if TAG in self.records:
                raise AssertionError("release was created twice")
            payload = json.loads(input)
            if path != "repos/owner/rui/releases" or payload["tag_name"] != TAG or payload["draft"] is not True:
                raise AssertionError("invalid REST draft creation")
            self.add(payload["target_commitish"])
            if self.fail_after_create:
                self.fail_after_create = False
                raise subprocess.CalledProcessError(1, ["gh", *args])
            return json.dumps(self.record())
        if action in ("upload", "delete", "edit") and not self.records[TAG]["draft"]:
            raise AssertionError("attempted to mutate public release")
        if action == "upload":
            url = urlparse(path)
            if url.scheme != "https" or url.netloc != "uploads.github.com" or url.path != "/repos/owner/rui/releases/1/assets":
                raise AssertionError("upload must use the acknowledged release resource")
            name = parse_qs(url.query)["name"][0]
            if name in self.files[TAG]:
                raise AssertionError("asset replacement must delete its asset ID first")
            filename = Path(args[args.index("--input") + 1])
            self.files[TAG][name] = filename.read_bytes()
            self.upload_count += 1
            if self.corrupt_upload == name:
                self.files[TAG][name] = b"corrupted transfer"
            result = next(asset for asset in self.record()["assets"] if asset["name"] == name)
            if self.fail_upload_after == self.upload_count:
                self.fail_upload_after = None
                raise subprocess.CalledProcessError(1, ["gh", *args])
            return json.dumps(result)
        if action in ("delete", "download"):
            asset_id = int(str(path).rsplit("/", 1)[1])
            name = next(name for name, identity in self.asset_ids.items() if identity == asset_id)
            if action == "delete":
                del self.files[TAG][name]
                del self.asset_ids[name]
                self.asset_states.pop(name, None)
            else:
                Path(output).write_bytes(self.files[TAG][name])
            return ""
        if path != "repos/owner/rui/releases/1":
            raise AssertionError(f"unexpected release resource {path}")
        if action == "edit":
            payload = json.loads(input)
            if payload["draft"] is not False or payload["make_latest"] != "true":
                raise AssertionError("publication must set latest and clear draft")
            target = self.records[TAG]["target_commitish"]
            if not git("ls-remote", "origin", f"refs/tags/{TAG}"):
                git("push", "--quiet", "origin", f"{target}:refs/tags/{TAG}")
            self.records[TAG]["draft"] = False
            if self.fail_after_publish:
                self.fail_after_publish = False
                raise subprocess.CalledProcessError(1, ["gh", *args])
        return json.dumps(self.record())

    def mutations(self):
        return [self.action(call) for call in self.calls if self.action(call) in ("create", "upload", "delete", "edit")]


class ProcessBoundaryTest(unittest.TestCase):
    def test_asset_download_preserves_binary_stdout_without_decoding(self):
        payload = b"\xff\x00\xfe\r\n"
        with tempfile.TemporaryDirectory() as scratch:
            output = Path(scratch) / "asset.tar.gz"

            def run(command, **kwargs):
                kwargs["stdout"].write(payload)
                return subprocess.CompletedProcess(command, 0)

            with mock.patch.object(subprocess, "run", side_effect=run) as process:
                publication.gh("api", "repos/owner/rui/releases/assets/123", output=output)
            self.assertEqual(output.read_bytes(), payload)
            self.assertEqual(process.call_args.args[0], ["gh", "api", "repos/owner/rui/releases/assets/123"])
            self.assertNotIn("text", process.call_args.kwargs)
            self.assertNotIn("stderr", process.call_args.kwargs)

    def test_json_request_forwards_text_stdin_and_checks_exit(self):
        with mock.patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout='{"id":123}')) as process:
            self.assertEqual(publication._json("--method", "POST", "repos/owner/rui/releases", payload={"draft": True}), {"id": 123})
        self.assertEqual(process.call_args.kwargs["input"], '{"draft": true}')
        self.assertTrue(process.call_args.kwargs["check"])
        self.assertNotIn("stderr", process.call_args.kwargs)
        self.assertEqual(process.call_args.args[0][-2:], ["--input", "-"])


class InventoryTest(unittest.TestCase):
    def setUp(self):
        environment = mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": "owner/rui"})
        environment.start()
        self.addCleanup(environment.stop)

    def test_includes_drafts_across_all_pages(self):
        public = {"tag_name": "v0.48.1", "draft": False}
        draft = {"tag_name": "v0.48.2", "draft": True}
        with mock.patch.object(publication, "gh", return_value=json.dumps([[public], [draft], []])) as gh:
            self.assertEqual(publication.inventory(), [public, draft])
        gh.assert_called_once_with("api", "--paginate", "--slurp", "repos/owner/rui/releases")

    def test_api_failure_is_not_an_empty_inventory(self):
        with (
            mock.patch.object(publication, "gh", side_effect=subprocess.CalledProcessError(1, ["gh"])),
            self.assertRaises(subprocess.CalledProcessError),
        ):
            publication.inventory()

    def test_invalid_api_shape_fails_closed(self):
        for payload in ("{}", "[{}]", "[[null]]", '[[{"tag_name":"v1"}]]', "invalid"):
            with (
                self.subTest(payload=payload),
                mock.patch.object(publication, "gh", return_value=payload),
                self.assertRaises(SystemExit),
            ):
                publication.inventory()

    def test_exact_public_asset_contract(self):
        self.assertEqual(publication.expected_assets(VERSION), ASSETS)
        self.assertEqual(len(ASSETS), 11)


class PublicationTest(RepositoryTest):
    def setUp(self):
        super().setUp()
        self.github = GitHub()
        gh = mock.patch.object(publication, "gh", side_effect=self.github)
        gh.start()
        self.addCleanup(gh.stop)
        environment = mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": "owner/rui"})
        environment.start()
        self.addCleanup(environment.stop)
        self.directory = self.root / "dist"
        self.directory.mkdir()
        self.notes = self.root / "notes.md"
        self.notes.write_text("Release notes\n")
        self.local = artifacts()
        self.write_local()

    def write_local(self):
        for path in self.directory.iterdir():
            path.unlink()
        for name, data in self.local.items():
            (self.directory / name).write_bytes(data)

    def publish(self, sha=None):
        return publication.publish(VERSION, sha or self.second, self.directory, self.notes)

    def test_new_release_is_verified_as_draft_before_publication(self):
        self.assertIsNone(self.publish())
        self.assertFalse(self.github.record()["draft"])
        self.assertEqual(self.github.files[TAG], self.local)
        self.assertEqual(git("ls-remote", "origin", f"refs/tags/{TAG}").split()[0], self.second)
        actions = [self.github.action(call) for call in self.github.calls]
        self.assertEqual(actions.count("inventory"), 1)
        self.assertEqual(actions.count("create"), 1)
        self.assertEqual(actions.count("upload"), len(ASSETS))
        self.assertEqual(actions.count("download"), 2 * len(ASSETS))
        self.assertEqual(actions.count("edit"), 1)
        self.assertLess(max(i for i, action in enumerate(actions) if action == "upload"), actions.index("download"))
        self.assertLess(actions.index("download"), actions.index("edit"))
        self.assertIsNone(self.stable(), "publication helper must not advance stable itself")

    def test_created_release_does_not_require_collection_index_visibility(self):
        self.github.hide_created_from_inventory = True
        self.assertIsNone(self.publish())
        self.assertFalse(self.github.record()["draft"])
        self.assertEqual(self.github.files[TAG], self.local)
        self.assertEqual(sum(self.github.action(call) == "inventory" for call in self.github.calls), 1)

    def test_stale_draft_index_after_publication_cannot_hide_patch_acknowledgement(self):
        self.github.add(self.second)
        self.github.stale_inventory = [self.github.record()]
        self.publish()
        self.assertTrue(self.github.stale_inventory[0]["draft"])
        self.assertEqual(self.github.stale_inventory[0]["assets"], [])
        self.assertFalse(self.github.record()["draft"])
        self.assertEqual(sum(self.github.action(call) == "inventory" for call in self.github.calls), 1)
        self.assertEqual(self.github.mutations().count("edit"), 1)

    def test_direct_resource_identity_is_revalidated_before_mutation(self):
        self.github.add(self.second)
        for key, value, error in (("id", 99, "resource ID changed"),
                                  ("tag_name", "v0.48.4", "invalid release identity"),
                                  ("target_commitish", self.first, "draft target is not immutable"),
                                  ("draft", None, "invalid release identity")):
            with self.subTest(key=key):
                def malformed_resource(*args, key=key, value=value, **kwargs):
                    result = self.github(*args, **kwargs)
                    if self.github.action(args) == "get":
                        record = json.loads(result)
                        record[key] = value
                        return json.dumps(record)
                    return result

                publication.gh.side_effect = malformed_resource
                with self.assertRaisesRegex(SystemExit, error):
                    self.publish()
                self.assertEqual(self.github.mutations(), [])

    def test_creation_response_must_acknowledge_a_valid_resource_id(self):
        def missing_create_id(*args, **kwargs):
            result = self.github(*args, **kwargs)
            if self.github.action(args) == "create":
                record = json.loads(result)
                del record["id"]
                return json.dumps(record)
            return result

        publication.gh.side_effect = missing_create_id
        with self.assertRaisesRegex(SystemExit, "positive integer ID"):
            self.publish()
        self.assertEqual(self.github.mutations(), ["create"])

    def test_unfinished_draft_asset_is_replaced_by_asset_id(self):
        self.github.add(self.second, {"install.sh": b"unfinished"})
        self.github.asset_states["install.sh"] = "starter"
        original_id = self.github.record()["assets"][0]["id"]
        self.publish()
        self.assertFalse(self.github.record()["draft"])
        self.assertEqual(self.github.files[TAG], self.local)
        deletes = [call for call in self.github.calls if self.github.action(call) == "delete"]
        self.assertEqual(len(deletes), 1)
        self.assertIn(f"repos/owner/rui/releases/assets/{original_id}", deletes[0])
        self.assertNotEqual(self.github.asset_ids["install.sh"], original_id)

    def test_upload_acknowledgement_must_name_completed_asset_resource(self):
        def malformed_upload(*args, **kwargs):
            result = self.github(*args, **kwargs)
            if self.github.action(args) == "upload":
                asset = json.loads(result)
                asset["state"] = "starter"
                return json.dumps(asset)
            return result

        publication.gh.side_effect = malformed_upload
        with self.assertRaisesRegex(SystemExit, "acknowledge completed asset"):
            self.publish()
        self.assertTrue(self.github.record()["draft"])
        self.assertNotIn("edit", self.github.mutations())

    def test_unexpected_upload_url_fails_before_asset_deletion(self):
        self.github.add(self.second, {"SHA256SUMS": b"old"})
        self.github.records[TAG]["upload_url"] = "https://untrusted.example/upload{?name,label}"
        with self.assertRaisesRegex(SystemExit, "unexpected upload URL"):
            self.publish()
        self.assertEqual(self.github.mutations(), [])

    def test_orphan_lightweight_and_annotated_tags_are_reused(self):
        for annotated in (False, True):
            with self.subTest(annotated=annotated):
                self.tag(self.second, annotated=annotated)
                self.github = GitHub()
                publication.gh.side_effect = self.github
                self.publish()
                self.assertEqual(self.github.mutations().count("create"), 1)
                self.assertEqual(git("ls-remote", "origin", f"refs/tags/{TAG}^{{}}").split()[0]
                                 if annotated else git("ls-remote", "origin", f"refs/tags/{TAG}").split()[0], self.second)
                self.assertEqual(self.github.files[TAG], self.local)
                git("push", "--quiet", "origin", f":refs/tags/{TAG}")
                if annotated:
                    git("tag", "-d", TAG)

    def test_partial_upload_retries_draft_with_new_cold_build_bytes(self):
        self.github.fail_upload_after = 3
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.assertTrue(self.github.record()["draft"])
        self.assertEqual(len(self.github.files[TAG]), 3)
        self.assertNotIn("edit", self.github.mutations())
        self.local = artifacts("rebuilt")
        self.write_local()
        self.publish()
        self.assertEqual(self.github.files[TAG], self.local)
        self.assertFalse(self.github.record()["draft"])
        self.assertEqual(self.github.mutations().count("create"), 1)

    def test_draft_creation_response_failure_reuses_created_draft(self):
        self.github.fail_after_create = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.assertTrue(self.github.record()["draft"])
        self.publish()
        self.assertEqual(self.github.mutations().count("create"), 1)
        self.assertFalse(self.github.record()["draft"])

    def test_existing_partial_draft_without_tag_is_resumed(self):
        self.github.add(self.second, {"install.sh": b"old partial installer"})
        self.publish()
        self.assertEqual(self.github.mutations().count("upload"), len(ASSETS))
        self.assertEqual(self.github.mutations().count("delete"), 1)
        self.assertEqual(self.github.mutations().count("edit"), 1)
        self.assertNotIn("create", self.github.mutations())
        self.assertEqual(self.github.files[TAG], self.local)

    def test_existing_complete_public_release_never_overwrites_cold_build_bytes(self):
        self.tag(self.second)
        published = artifacts("published")
        self.github.add(self.second, published, draft=False)
        self.assertIsNone(self.publish())
        self.assertEqual(self.github.files[TAG], published)
        self.assertEqual(self.github.mutations(), [])
        self.assertIn("download", [self.github.action(call) for call in self.github.calls])

    def test_draft_published_before_upload_is_rechecked_without_overwrite(self):
        self.github.add(self.second, {"install.sh": b"partial"})
        published = artifacts("external publisher")
        reads = 0

        def publish_on_second_inventory(*args, **kwargs):
            nonlocal reads
            if self.github.action(args) == "get":
                reads += 1
                if reads == 1:
                    self.tag(self.second)
                    self.github.add(self.second, published, draft=False)
            return self.github(*args, **kwargs)

        publication.gh.side_effect = publish_on_second_inventory
        self.publish()
        self.assertEqual(self.github.mutations(), [])
        self.assertEqual(self.github.files[TAG], published)

    def test_public_release_without_tag_fails_before_mutation(self):
        self.github.add(self.second, self.local, draft=False)
        with self.assertRaisesRegex(SystemExit, "has no remote tag"):
            self.publish()
        self.assertEqual(self.github.mutations(), [])

    def test_tag_changed_while_publishing_is_rejected_before_success(self):
        def replace_tag_after_publication(*args, **kwargs):
            result = self.github(*args, **kwargs)
            if self.github.action(args) == "edit":
                git("push", "--quiet", "--force", "origin", f"{self.first}:refs/tags/{TAG}")
            return result

        publication.gh.side_effect = replace_tag_after_publication
        with self.assertRaisesRegex(SystemExit, "tag points to"):
            self.publish()
        self.assertFalse(self.github.record()["draft"])
        self.assertIsNone(self.stable())

    def test_publication_response_failure_recovers_without_overwriting(self):
        self.github.fail_after_publish = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        published = dict(self.github.files[TAG])
        self.assertFalse(self.github.record()["draft"])
        self.local = artifacts("new rebuild")
        self.write_local()
        self.github.calls.clear()
        self.publish()
        self.assertEqual(self.github.mutations(), [])
        self.assertEqual(self.github.files[TAG], published)

    def test_wrong_remote_tag_sha_blocks_orphan_draft_and_public(self):
        self.tag(self.first)
        for state in ("orphan", "draft", "public"):
            with self.subTest(state=state):
                if state != "orphan":
                    self.github.add(self.second, self.local, draft=state == "draft")
                with self.assertRaisesRegex(SystemExit, "tag points to"):
                    self.publish()
                self.assertEqual(self.github.mutations(), [])

    def test_unpinned_or_wrong_draft_target_is_rejected_even_with_matching_tag(self):
        for tagged in (False, True):
            if tagged:
                self.tag(self.second)
            for target in ("main", self.first):
                with self.subTest(tagged=tagged, target=target):
                    self.github.add(target)
                    with self.assertRaisesRegex(SystemExit, "draft target is not immutable"):
                        self.publish()
                    self.assertEqual(self.github.mutations(), [])

    def test_corrupt_remote_upload_stays_draft_and_never_publishes(self):
        self.github.corrupt_upload = "rui-0.48.3-linux-arm64.tar.gz"
        with self.assertRaisesRegex(SystemExit, "digest mismatch"):
            self.publish()
        self.assertTrue(self.github.record()["draft"])
        self.assertNotIn("edit", self.github.mutations())
        self.assertIsNone(self.stable())

    def test_incomplete_or_corrupt_public_release_fails_without_overwrite(self):
        self.tag(self.second)
        for fault in ("missing", "digest", "extra"):
            with self.subTest(fault=fault):
                files = dict(self.local)
                if fault == "missing":
                    del files["rui-0.48.3-linux-arm64-debug.tar.gz"]
                elif fault == "digest":
                    files["rui-0.48.3.tgz"] = b"bad bytes"
                else:
                    files["unreviewed.txt"] = b"extra"
                self.github.add(self.second, files, draft=False)
                with self.assertRaisesRegex(SystemExit, "asset set|digest mismatch"):
                    self.publish()
                self.assertEqual(self.github.mutations(), [])

    def test_missing_archive_digest_duplicate_digest_and_extra_digest_fail(self):
        for fault in ("missing", "duplicate", "extra", "malformed"):
            with self.subTest(fault=fault):
                files = dict(self.local)
                rows = files["SHA256SUMS"].decode().splitlines()
                if fault == "missing":
                    rows.pop()
                elif fault == "duplicate":
                    rows.append(rows[0])
                elif fault == "extra":
                    rows.append(f"{'0' * 64}  install.sh")
                else:
                    rows[0] = "not a checksum"
                files["SHA256SUMS"] = ("\n".join(rows) + "\n").encode()
                self.github.add(self.second, files)
                with self.assertRaisesRegex(SystemExit, "SHA256SUMS"):
                    publication.verify_release(VERSION, self.github.record())

    def test_missing_installer_and_duplicate_asset_records_fail(self):
        self.github.add(self.second, self.local)
        record = self.github.record()
        for fault in ("missing", "duplicate", "unfinished"):
            with self.subTest(fault=fault):
                damaged = copy.deepcopy(record)
                if fault == "missing":
                    damaged["assets"] = [row for row in damaged["assets"] if row["name"] != "install.sh"]
                elif fault == "duplicate":
                    damaged["assets"].append(damaged["assets"][0])
                else:
                    damaged["assets"][0]["state"] = "new"
                with self.assertRaisesRegex(SystemExit, "asset|duplicate"):
                    publication.verify_release(VERSION, damaged)

    def test_bad_local_artifacts_fail_before_remote_mutation(self):
        for fault in ("missing", "digest", "unexpected", "symlink"):
            with self.subTest(fault=fault):
                self.write_local()
                if fault == "missing":
                    (self.directory / "install.sh").unlink()
                elif fault == "digest":
                    (self.directory / "rui-0.48.3.tgz").write_bytes(b"changed")
                elif fault == "unexpected":
                    (self.directory / "notes.md").write_text("not public")
                else:
                    (self.directory / "install.sh").unlink()
                    (self.directory / "install.sh").symlink_to(self.notes)
                with self.assertRaises(SystemExit):
                    self.publish()
                self.assertEqual(self.github.calls, [])


class StableRepairTest(RepositoryTest):
    def test_creates_missing_stable_and_records_tracking_ref(self):
        publication.repair_stable(self.second)
        self.assertEqual(self.stable(), self.second)
        self.assertEqual(git("rev-parse", "origin/stable"), self.second)

    def test_missing_stable_ignores_stale_local_tracking_ref(self):
        git("update-ref", "refs/remotes/origin/stable", self.third)
        publication.repair_stable(self.second)
        self.assertEqual(self.stable(), self.second)
        self.assertEqual(git("rev-parse", "origin/stable"), self.second)

    def test_shallow_checkout_fetches_candidate_ancestry_before_repair(self):
        shallow = self.root / "shallow"
        git("clone", "--quiet", "--depth=1", (self.root / "remote.git").as_uri(), str(shallow))
        os.chdir(shallow)
        publication.repair_stable(self.second)
        self.assertEqual(self.stable(), self.second)

    def test_fast_forwards_after_publication_and_is_idempotent(self):
        git("push", "--quiet", "origin", f"{self.first}:refs/heads/stable")
        publication.repair_stable(self.second)
        self.assertEqual(self.stable(), self.second)
        publication.repair_stable(self.second)
        self.assertEqual(self.stable(), self.second)

    def test_newer_stable_is_not_rewound(self):
        git("push", "--quiet", "origin", f"{self.third}:refs/heads/stable")
        with mock.patch.object(publication, "git", wraps=publication.git) as observed:
            publication.repair_stable(self.second)
        self.assertEqual(self.stable(), self.third)
        self.assertFalse(any(call.args[0] == "push" for call in observed.call_args_list))

    def test_candidate_not_on_main_cannot_be_promoted(self):
        unpublished = self.commit()
        with self.assertRaisesRegex(SystemExit, "not on origin/main"):
            publication.repair_stable(unpublished)
        self.assertIsNone(self.stable())

    def test_divergent_stable_fails_even_if_it_contains_candidate(self):
        git("checkout", "--quiet", "--detach", self.first)
        divergent = self.commit()
        git("push", "--quiet", "origin", f"{divergent}:refs/heads/stable")
        for candidate in (self.first, self.second):
            with self.subTest(candidate=candidate):
                with self.assertRaisesRegex(SystemExit, "stable diverges"):
                    publication.repair_stable(candidate)
                self.assertEqual(self.stable(), divergent)

    def test_concurrent_stable_advance_rejects_push_without_force_or_local_ref_update(self):
        git("push", "--quiet", "origin", f"{self.first}:refs/heads/stable")
        original = publication.git
        pushes = []

        def advance_before_push(*args):
            if args[0] == "push":
                pushes.append(args)
                git("--git-dir", str(self.root / "remote.git"), "update-ref",
                    "refs/heads/stable", self.third)
            return original(*args)

        with (
            mock.patch.object(publication, "git", side_effect=advance_before_push),
            self.assertRaises(subprocess.CalledProcessError),
        ):
            publication.repair_stable(self.second)
        self.assertEqual(pushes, [("push", "origin", f"{self.second}:refs/heads/stable")])
        self.assertEqual(self.stable(), self.third)
        self.assertEqual(git("rev-parse", "origin/stable"), self.first)

    def test_missing_remote_main_fails_closed(self):
        git("--git-dir", str(self.root / "remote.git"), "update-ref", "-d", "refs/heads/main")
        with self.assertRaisesRegex(SystemExit, "origin/main is missing"):
            publication.repair_stable(self.second)
        self.assertIsNone(self.stable())


if __name__ == "__main__":
    unittest.main()
