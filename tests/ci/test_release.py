import contextlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

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

    def commit(self, schema, path="src/store/schema.zig", digest=None):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        row = "" if digest is None else f"    .{{ .schema_version = {schema}, .digest = 0x{digest:016x} }},\n"
        Path(path).write_text(f"const x = 1;\npub const schema_version: u32 = {schema};\n{row}")
        with open("history", "a") as history:
            history.write(f"{schema}\n")
        git("add", "-A")
        git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", f"schema {schema}")
        return git("rev-parse", "HEAD")

    def publish(self, stable, tags=()):
        git("push", "-q", "-f", "origin", f"{stable}:refs/heads/stable", *(f"{sha}:refs/tags/{tag}" for tag, sha in tags))

    def plan(self, sha):
        with contextlib.redirect_stderr(io.StringIO()):
            return release.plan(sha)

    def test_versions_count_releases_within_a_schema(self):
        first = self.commit(35)
        second = self.commit(35)
        third = self.commit(36)
        self.publish(second)
        self.assertEqual(self.plan(first), "0.35.0")
        with self.assertRaisesRegex(SystemExit, "not on stable"):
            self.plan(third)
        self.publish(third, [("v0.35.0", first)])
        self.assertEqual(self.plan(second), "0.35.1")
        self.publish(third, [("v0.35.1", second)])
        self.assertEqual(self.plan(third), "0.36.0")
        # A released commit, or one a release already includes, is never released again.
        self.assertIsNone(self.plan(second))
        self.assertIsNone(self.plan(first))
        # Unrelated tags do not count toward the patch number.
        self.publish(third, [("v0.36.x", second), ("w0.36.4", second)])
        self.assertEqual(self.plan(third), "0.36.0")

    def test_refuses_to_ship_a_released_schema_whose_bootstrap_changed(self):
        shipped = self.commit(48, digest=0xaa)
        drifted = self.commit(48, digest=0xbb)
        self.publish(drifted, [("v0.48.0", shipped)])
        with self.assertRaisesRegex(SystemExit, "restore row 48 to 0x00000000000000aa, set schema_version to 49"):
            self.plan(drifted)
        repaired = self.commit(48, digest=0xaa)
        self.publish(repaired, [("v0.48.0", shipped)])
        self.assertEqual(self.plan(repaired), "0.48.1", "an unchanged bootstrap ships again under its number")

    def test_revisions_before_the_store_split_read_the_format_from_src_store_zig(self):
        before = self.commit(35, "src/store.zig")
        after = self.commit(36)
        self.publish(after)
        self.assertEqual(self.plan(before), "0.35.0")
        self.assertEqual(self.plan(after), "0.36.0")

    def test_schema_must_be_declared(self):
        Path("src/store").mkdir(parents=True)
        Path("src/store/schema.zig").write_text("const schema_version = 35;\n")
        git("add", "-A")
        git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "no schema")
        sha = git("rev-parse", "HEAD")
        self.publish(sha)
        with self.assertRaisesRegex(SystemExit, "src/store/schema.zig has no schema_version"):
            self.plan(sha)

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
        result = subprocess.run(["sh", str(ROOT / "release/install.sh")], capture_output=True, text=True,
                                env={**os.environ, "HOME": "/nonexistent"}, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unpublished installer template", result.stderr)

    def test_publish_fragment_parses_as_posix_sh(self):
        for shell in ("sh", "dash"):
            if shell == "sh" or shutil.which(shell):
                with self.subTest(shell=shell):
                    result = subprocess.run([shell, "-n", str(ROOT / "release/publish.sh")],
                                            capture_output=True, text=True, timeout=20)
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
