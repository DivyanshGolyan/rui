import copy
import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

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
    """Only the gh process boundary is replaced; tag and branch operations use Git."""

    def __init__(self):
        self.records = {}
        self.files = {}
        self.calls = []
        self.fail_upload_after = None
        self.corrupt_upload = None
        self.fail_after_publish = False
        self.fail_after_create = False

    def add(self, sha, files=None, draft=True):
        self.records[TAG] = {"id": 1, "tag_name": TAG, "draft": draft,
                             "target_commitish": sha}
        self.files[TAG] = dict(files or {})

    def record(self):
        record = copy.deepcopy(self.records[TAG])
        record["assets"] = [{"name": name, "state": "uploaded", "size": len(data)}
                            for name, data in self.files[TAG].items()]
        return record

    def __call__(self, *args):
        self.calls.append(args)
        if args[:1] == ("api",):
            return json.dumps([[self.record()] if TAG in self.records else []])
        action, tag = args[1:3]
        if action == "create":
            if tag in self.records:
                raise AssertionError("release was created twice")
            if "--verify-tag" in args and not git("ls-remote", "origin", f"refs/tags/{tag}"):
                raise AssertionError("orphan tag was not verified")
            self.add(args[args.index("--target") + 1])
            if self.fail_after_create:
                self.fail_after_create = False
                raise subprocess.CalledProcessError(1, ["gh", *args])
            return ""
        if action == "upload":
            if not self.records[tag]["draft"]:
                raise AssertionError("attempted to overwrite public assets")
            for index, filename in enumerate(args[args.index("--clobber") + 1:], 1):
                path = Path(filename)
                self.files[tag][path.name] = path.read_bytes()
                if self.fail_upload_after == index:
                    self.fail_upload_after = None
                    raise subprocess.CalledProcessError(1, ["gh", *args])
            if self.corrupt_upload:
                self.files[tag][self.corrupt_upload] = b"corrupted transfer"
            return ""
        if action == "download":
            directory = Path(args[args.index("--dir") + 1])
            for name, data in self.files[tag].items():
                (directory / name).write_bytes(data)
            return ""
        if action == "edit":
            if "--draft=false" not in args or "--latest" not in args:
                raise AssertionError("publication must set latest and clear draft")
            target = self.records[tag]["target_commitish"]
            if not git("ls-remote", "origin", f"refs/tags/{tag}"):
                git("push", "--quiet", "origin", f"{target}:refs/tags/{tag}")
            self.records[tag]["draft"] = False
            if self.fail_after_publish:
                self.fail_after_publish = False
                raise subprocess.CalledProcessError(1, ["gh", *args])
            return ""
        raise AssertionError(f"unexpected gh invocation {args}")

    def mutations(self):
        return [call[1] for call in self.calls if call[:1] == ("release",)
                and call[1] in ("create", "upload", "edit")]


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
        create = next(call for call in self.github.calls if call[1:2] == ("create",))
        self.assertIn("--draft", create)
        self.assertNotIn("--verify-tag", create)
        self.assertEqual(create[create.index("--target") + 1], self.second)
        actions = [call[1] for call in self.github.calls if call[0] == "release"]
        self.assertEqual(actions, ["create", "upload", "download", "edit", "download"])
        self.assertIsNone(self.stable(), "publication helper must not advance stable itself")

    def test_orphan_lightweight_and_annotated_tags_are_reused(self):
        for annotated in (False, True):
            with self.subTest(annotated=annotated):
                self.tag(self.second, annotated=annotated)
                self.github = GitHub()
                publication.gh.side_effect = self.github
                self.publish()
                create = next(call for call in self.github.calls if call[1:2] == ("create",))
                self.assertIn("--verify-tag", create)
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
        self.assertEqual(self.github.mutations(), ["upload", "edit"])
        self.assertEqual(self.github.files[TAG], self.local)

    def test_existing_complete_public_release_never_overwrites_cold_build_bytes(self):
        self.tag(self.second)
        published = artifacts("published")
        self.github.add(self.second, published, draft=False)
        self.assertIsNone(self.publish())
        self.assertEqual(self.github.files[TAG], published)
        self.assertEqual(self.github.mutations(), [])
        self.assertIn("download", [call[1] for call in self.github.calls if call[0] == "release"])

    def test_draft_published_before_upload_is_rechecked_without_overwrite(self):
        self.github.add(self.second, {"install.sh": b"partial"})
        published = artifacts("external publisher")
        reads = 0

        def publish_on_second_inventory(*args):
            nonlocal reads
            if args[0] == "api":
                reads += 1
                if reads == 2:
                    self.tag(self.second)
                    self.github.add(self.second, published, draft=False)
            return self.github(*args)

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
        def replace_tag_after_publication(*args):
            result = self.github(*args)
            if args[:2] == ("release", "edit"):
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
