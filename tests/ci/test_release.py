import contextlib
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qs, urlparse

import release

ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = (ROOT / "release/install.sh").read_text()
PUBLISH = (ROOT / "release/publish.sh").read_text()


def git(*args, cwd=None):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class PlanTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.addCleanup(os.chdir, os.getcwd())
        root = Path(scratch.name)
        git("init", "-q", "--bare", "-b", "main", str(root / "remote.git"))
        git("clone", "-q", str(root / "remote.git"), str(root / "work"))
        os.chdir(root / "work")
        self.records = []
        self.assets = {}
        self.gh_calls = []
        self.next_asset_id = 1000
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, {"GITHUB_REPOSITORY": "test/rui"}).start()
        patch("release.publication.gh", side_effect=self.gh).start()

    def gh(self, *args, input=None, output=None):
        self.gh_calls.append(args)
        if "--paginate" in args:
            return json.dumps([self.records])
        self.assertEqual(args[0], "api")
        path = next(str(arg) for arg in args[1:] if str(arg).startswith(("repos/", "https://")))
        method = args[args.index("--method") + 1] if "--method" in args else "GET"
        if method == "POST" and path == "repos/test/rui/releases":
            record = json.loads(input)
            record.update(id=len(self.records) + 1, prerelease=False, assets=[])
            record["upload_url"] = f"https://uploads.github.com/repos/test/rui/releases/{record['id']}/assets{{?name,label}}"
            self.records.append(record)
            self.assets[record["tag_name"]] = {}
            return json.dumps(record)
        if "/releases/assets/" in path:
            identity = int(path.rsplit("/", 1)[1])
            record, asset = next((record, asset) for record in self.records
                                 for asset in record["assets"] if asset["id"] == identity)
            if method == "DELETE":
                self.assertTrue(record["draft"])
                record["assets"].remove(asset)
                del self.assets[record["tag_name"]][asset["name"]]
            else:
                Path(output).write_bytes(self.assets[record["tag_name"]][asset["name"]])
            return ""
        if path.startswith("https://uploads.github.com/"):
            url = urlparse(path)
            identity = int(url.path.split("/")[-2])
            record = next(record for record in self.records if record["id"] == identity)
            self.assertTrue(record["draft"])
            name = parse_qs(url.query)["name"][0]
            filename = Path(args[args.index("--input") + 1])
            self.assets[record["tag_name"]][name] = filename.read_bytes()
            self.next_asset_id += 1
            asset = {"id": self.next_asset_id, "name": name, "state": "uploaded"}
            record["assets"].append(asset)
            return json.dumps(asset)
        identity = int(path.rsplit("/", 1)[1])
        record = next(record for record in self.records if record["id"] == identity)
        if method == "PATCH":
            self.tag(record["tag_name"], record["target_commitish"])
            record.update(json.loads(input))
        return json.dumps(record)

    def commit(self, schema, path="src/store/schema.zig", digest=None):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        row = "" if digest is None else f"    .{{ .schema_version = {schema}, .digest = 0x{digest:016x} }},\n"
        Path(path).write_text(f"const x = 1;\npub const schema_version: u32 = {schema};\n{row}")
        with open("history", "a") as history:
            history.write(f"{schema}\n")
        git("add", "-A")
        git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", f"schema {schema}")
        return git("rev-parse", "HEAD")

    def main(self, sha):
        git("push", "-q", "-f", "origin", f"{sha}:refs/heads/main")

    def tag(self, tag, sha):
        git("push", "-q", "origin", f"{sha}:refs/tags/{tag}")

    def published(self, tag, sha, *, draft=False, tagged=True):
        if tagged:
            self.tag(tag, sha)
        version = tag[1:]
        names = release.publication.expected_assets(version)
        payload = {name: f"{name} bytes".encode() for name in names - {"SHA256SUMS", "install.sh"}}
        payload["SHA256SUMS"] = "".join(
            f"{hashlib.sha256(data).hexdigest()}  {name}\n" for name, data in sorted(payload.items())).encode()
        payload["install.sh"] = b"#!/bin/sh\nexit 0\n"
        self.assets[tag] = payload
        identity = len(self.records) + 1
        assets = []
        for name in names:
            self.next_asset_id += 1
            assets.append({"id": self.next_asset_id, "name": name, "state": "uploaded"})
        self.records.append({"id": identity, "tag_name": tag, "draft": draft, "prerelease": False,
                             "target_commitish": sha,
                             "upload_url": f"https://uploads.github.com/repos/test/rui/releases/{identity}/assets{{?name,label}}",
                             "assets": assets})

    def plan(self, sha):
        with contextlib.redirect_stderr(io.StringIO()):
            return release.plan(sha)

    def test_versions_count_releases_within_a_schema(self):
        first = self.commit(35)
        second = self.commit(35)
        third = self.commit(36)
        self.main(second)
        self.assertEqual(self.plan(first), "0.35.0")
        with self.assertRaisesRegex(SystemExit, "not on main"):
            self.plan(third)
        self.main(third)
        self.published("v0.35.0", first)
        self.assertEqual(self.plan(second), "0.35.1")
        self.published("v0.35.1", second)
        self.assertEqual(self.plan(third), "0.36.0")
        self.assertIsNone(self.plan(second))
        self.assertIsNone(self.plan(first))
        self.tag("v0.36.x", second)
        self.tag("w0.36.4", second)
        self.assertEqual(self.plan(third), "0.36.0")

    def test_orphan_tag_and_tagless_draft_resume_the_same_version(self):
        first = self.commit(48)
        self.main(first)
        self.tag("v0.48.0", first)
        self.assertEqual(self.plan(first), "0.48.0")
        second = self.commit(48)
        self.main(second)
        self.published("v0.48.1", second, draft=True, tagged=False)
        self.assertEqual(self.plan(second), "0.48.1")
        self.assertEqual(self.plan(second), "0.48.1")

    def test_duplicate_published_release_is_verified_not_republished(self):
        sha = self.commit(48)
        self.main(sha)
        self.published("v0.48.0", sha)
        self.assertIsNone(self.plan(sha))
        self.assertTrue(any("Accept: application/octet-stream" in call for call in self.gh_calls))
        self.assets["v0.48.0"].pop("install.sh")
        self.records[0]["assets"] = [asset for asset in self.records[0]["assets"] if asset["name"] != "install.sh"]
        with self.assertRaises(SystemExit):
            self.plan(sha)

    def test_newer_publication_skips_a_stale_candidate_and_repairs_latest_pointer(self):
        first = self.commit(48)
        second = self.commit(48)
        self.main(second)
        self.published("v0.48.0", first)
        self.published("v0.48.1", second)
        self.assertIsNone(self.plan(first))
        release.repair(first)
        self.assertEqual(git("ls-remote", "origin", "refs/heads/stable").split()[0], second)
        release.repair(first)
        self.assertEqual(git("ls-remote", "origin", "refs/heads/stable").split()[0], second)

    def test_published_release_with_failed_pointer_update_retries_without_asset_mutation(self):
        sha = self.commit(48)
        self.main(sha)
        self.published("v0.48.0", sha, draft=True, tagged=False)
        payload = self.assets.pop("v0.48.0")
        self.records.clear()
        directory = Path("dist")
        directory.mkdir()
        for name, data in payload.items():
            (directory / name).write_bytes(data)
        notes = Path("notes.md")
        notes.write_text("Release notes\n")
        with patch("release.publication.repair_stable", side_effect=SystemExit("pointer update failed")), \
                self.assertRaisesRegex(SystemExit, "pointer update failed"):
            release.publish("0.48.0", sha, directory, notes)
        self.assertFalse(self.records[0]["draft"])
        self.assertEqual(git("ls-remote", "origin", "refs/heads/stable"), "")
        mutations = [call for call in self.gh_calls if "--method" in call]
        with contextlib.redirect_stderr(io.StringIO()):
            release.publish("0.48.0", sha, directory, notes)
        self.assertEqual(git("ls-remote", "origin", "refs/heads/stable").split()[0], sha)
        self.assertEqual(mutations, [call for call in self.gh_calls if "--method" in call])

    def test_refuses_divergent_release_history_and_outside_main_candidate(self):
        first = self.commit(48)
        second = self.commit(48)
        git("checkout", "-q", "--detach", first)
        divergent = self.commit(49)
        self.main(second)
        with self.assertRaisesRegex(SystemExit, "not on main"):
            self.plan(divergent)
        self.tag("v0.48.0", divergent)
        with self.assertRaisesRegex(SystemExit, "divergent history"):
            self.plan(second)

    def test_refuses_lower_schema_and_pending_release_rewind(self):
        first = self.commit(48)
        second = self.commit(47)
        self.main(second)
        self.published("v0.48.0", first)
        with self.assertRaisesRegex(SystemExit, "lower schema"):
            self.plan(second)
        self.records.clear()
        self.tag("v0.48.1", second)
        with self.assertRaisesRegex(SystemExit, "pending release"):
            self.plan(first)

    def test_release_number_order_must_not_rewind_main_history(self):
        first = self.commit(48)
        second = self.commit(48)
        self.main(second)
        self.tag("v0.48.1", first)
        self.tag("v0.48.0", second)
        with self.assertRaisesRegex(SystemExit, "release history rewinds"):
            self.plan(second)

    def test_draft_and_tag_must_agree_on_immutable_sha(self):
        first = self.commit(48)
        second = self.commit(48)
        self.main(second)
        self.published("v0.48.0", first, draft=True)
        self.records[0]["target_commitish"] = second
        with self.assertRaisesRegex(SystemExit, "does not match its tag SHA"):
            self.plan(second)
        self.records[0]["target_commitish"] = "main"
        with self.assertRaises(SystemExit):
            self.plan(second)

    def test_revalidates_version_before_publisher_mutations(self):
        first = self.commit(48)
        second = self.commit(48)
        self.main(second)
        self.published("v0.48.0", first)
        with self.assertRaisesRegex(SystemExit, "identity changed"):
            release.publish("0.48.0", second, Path("missing"), Path("missing"))
        self.assertFalse(any("--method" in call for call in self.gh_calls))

    def test_refuses_to_ship_a_released_schema_whose_bootstrap_changed(self):
        shipped = self.commit(48, digest=0xaa)
        drifted = self.commit(48, digest=0xbb)
        self.main(drifted)
        self.published("v0.48.0", shipped)
        with self.assertRaisesRegex(SystemExit, "restore row 48 to 0x00000000000000aa, set schema_version to 49"):
            self.plan(drifted)
        repaired = self.commit(48, digest=0xaa)
        self.main(repaired)
        self.assertEqual(self.plan(repaired), "0.48.1")

    def test_pending_draft_cannot_mask_drift_from_last_public_schema(self):
        shipped = self.commit(48, digest=0xaa)
        drifted = self.commit(48, digest=0xbb)
        self.main(drifted)
        self.published("v0.48.0", shipped)
        self.published("v0.48.1", drifted, draft=True)
        with self.assertRaisesRegex(SystemExit, "restore row 48"):
            self.plan(drifted)

    def test_local_only_tag_does_not_reserve_a_release_version(self):
        sha = self.commit(48)
        self.main(sha)
        git("tag", "v0.48.9", sha)
        self.assertEqual(self.plan(sha), "0.48.0")

    def test_revisions_before_the_store_split_read_the_format_from_src_store_zig(self):
        before = self.commit(35, "src/store.zig")
        after = self.commit(36)
        self.main(after)
        self.assertEqual(self.plan(before), "0.35.0")
        self.assertEqual(self.plan(after), "0.36.0")

    def test_schema_must_be_declared_and_refs_are_not_release_sources(self):
        Path("src/store").mkdir(parents=True)
        Path("src/store/schema.zig").write_text("const schema_version = 35;\n")
        git("add", "-A")
        git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "no schema")
        sha = git("rev-parse", "HEAD")
        self.main(sha)
        with self.assertRaisesRegex(SystemExit, "src/store/schema.zig has no schema_version"):
            self.plan(sha)
        for ref in ("main", "refs/pull/1/head", "--all"):
            with self.subTest(ref=ref), self.assertRaisesRegex(SystemExit, "commit SHA"):
                self.plan(ref)


class CommandTest(unittest.TestCase):
    def test_publish_command_delegates_with_paths(self):
        with patch.object(sys, "argv", ["release.py", "publish", "0.48.0", "a" * 40, "dist", "notes.md"]), \
                patch("release.publish") as publish:
            release.main()
        publish.assert_called_once_with("0.48.0", "a" * 40, Path("dist"), Path("notes.md"))


class InstallerTemplateTest(unittest.TestCase):
    def test_fills_every_placeholder_with_checked_digests(self):
        digests = {"darwin-arm64": "a" * 64, "linux-x86_64": "b" * 64}
        text = release.installer(TEMPLATE, "0.35.2", digests, PUBLISH)
        self.assertIn("version='0.35.2'", text)
        self.assertIn("digest_darwin_arm64='" + "a" * 64 + "'", text)
        self.assertIn("digest_linux_x86_64='" + "b" * 64 + "'", text)
        self.assertIn("rui_publish() {", text)
        self.assertNotRegex(text, r"@[A-Z0-9_]+@")
        with self.assertRaisesRegex(SystemExit, "SHA-256"):
            release.installer(TEMPLATE, "0.35.2", dict(digests, **{"linux-x86_64": "x"}), PUBLISH)
        with self.assertRaisesRegex(SystemExit, "unfilled"):
            release.installer(TEMPLATE + "@NEW_FIELD@\n", "0.35.2", digests, PUBLISH)
        with self.assertRaisesRegex(SystemExit, "placeholders"):
            release.installer(TEMPLATE, "0.35.2", digests, PUBLISH + "@VERSION@\n")
        for template in (TEMPLATE.replace("@PUBLISH@\n", ""), TEMPLATE + "@PUBLISH@\n"):
            with self.assertRaisesRegex(SystemExit, "exactly once"):
                release.installer(template, "0.35.2", digests, PUBLISH)

    def test_real_generation_uses_target_prehelper_installer_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target"
            (target / "release").mkdir(parents=True)
            template = ("#!/bin/sh\nversion='@VERSION@'\n"
                        "digest_darwin_arm64='@SHA256_DARWIN_ARM64@'\n"
                        "digest_linux_x86_64='@SHA256_LINUX_X86_64@'\n@PUBLISH@\n"
                        'rui_publish "$HOME/.local" "$release" 40\n')
            publisher = ('rui_publish() {\n'
                         '    ln -s "$2/bin/rui" "$1/bin/rui.next" && mv -f "$1/bin/rui.next" "$1/bin/rui"\n'
                         '}\n')
            (target / "release/install.sh").write_text(template)
            (target / "release/publish.sh").write_text(publisher)
            sums = root / "SHA256SUMS"
            digests = {platform: character * 64 for platform, character in
                       zip(release.PLATFORMS, ("a", "b"))}
            sums.write_text("".join(f"{digest}  rui-0.40.0-{platform}.tar.gz\n"
                                    for platform, digest in digests.items()))
            output = root / "install.sh"
            result = subprocess.run([sys.executable, str(ROOT / "tests/ci/release.py"), "installer",
                                     "0.40.0", str(sums), str(output), "--source-root", str(target)],
                                    check=True, capture_output=True, text=True, timeout=20)
            self.assertEqual(result.stdout, "")
            self.assertEqual(output.read_text(), release.installer(template, "0.40.0", digests, publisher))
            self.assertNotIn("--publish-install", output.read_text())

    def test_publication_binds_installer_source_to_artifact_target(self):
        publication = (ROOT / ".github/workflows/release.yml").read_text().split("  publish:", 1)[1]
        self.assertIn("ref: ${{ needs.plan.outputs.sha }}\n          path: .release-source", publication)
        self.assertIn('dist/install.sh --source-root .release-source', publication)

    def test_template_refuses_to_install(self):
        result = subprocess.run(["sh", str(ROOT / "release/install.sh")], check=False, capture_output=True, text=True,
                                env={**os.environ, "HOME": "/nonexistent"}, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unpublished installer template", result.stderr)

    def test_publish_fragment_parses_as_posix_sh(self):
        for shell in ("sh", "dash"):
            if shell == "sh" or shutil.which(shell):
                with self.subTest(shell=shell):
                    result = subprocess.run([shell, "-n", str(ROOT / "release/publish.sh")],
                                            check=False, capture_output=True, text=True, timeout=20)
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_publish_fragment_reads_the_database_the_build_names(self):
        self.assertIn('pub const database_suffix = "/rui.sqlite3";', (ROOT / "src/platform.zig").read_text())
        self.assertIn('"$1/rui.sqlite3"', PUBLISH)

    def test_only_installers_call_the_fragment(self):
        def users(name):
            return set(git("grep", "-l", "-F", name, "--", ":!*.md", ":!tests/ci/test_release.py", cwd=ROOT).splitlines())
        self.assertEqual(users("rui_publish"), {"release/publish.sh", "release/install.sh", "install.sh"})
        # host_status_integration.py pins the fragment's JSON reader against the real build.
        self.assertEqual(users("_rui_selected"), {"release/publish.sh", "tests/integration/host_status_integration.py"})


if __name__ == "__main__":
    unittest.main()
