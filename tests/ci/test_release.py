import contextlib
import hashlib
import io
import os
from pathlib import Path
import platform
import subprocess
import tarfile
import tempfile
import unittest

import release

ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = (ROOT / "release/install.sh").read_text()
PLATFORM = {("Darwin", "arm64"): "darwin-arm64", ("Linux", "x86_64"): "linux-x86_64"}.get(
    (platform.system(), platform.machine()))


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

    def commit(self, schema):
        Path("src").mkdir(exist_ok=True)
        Path("src/store.zig").write_text(f"const x = 1;\npub const schema_version: u32 = {schema};\n")
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

    def test_schema_must_be_declared(self):
        Path("src").mkdir()
        Path("src/store.zig").write_text("const schema_version = 35;\n")
        git("add", "-A")
        git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "no schema")
        sha = git("rev-parse", "HEAD")
        self.publish(sha)
        with self.assertRaisesRegex(SystemExit, "schema_version"):
            self.plan(sha)


class InstallerTemplateTest(unittest.TestCase):
    def test_fills_every_placeholder_with_checked_digests(self):
        digests = {"darwin-arm64": "a" * 64, "linux-x86_64": "b" * 64}
        text = release.installer(TEMPLATE, "0.35.2", digests)
        self.assertIn("version='0.35.2'", text)
        self.assertIn("digest_darwin_arm64='" + "a" * 64 + "'", text)
        self.assertIn("digest_linux_x86_64='" + "b" * 64 + "'", text)
        self.assertNotRegex(text, r"@[A-Z0-9_]+@")
        with self.assertRaisesRegex(SystemExit, "SHA-256"):
            release.installer(TEMPLATE, "0.35.2", dict(digests, **{"linux-x86_64": "x"}))
        with self.assertRaisesRegex(SystemExit, "unfilled"):
            release.installer(TEMPLATE + "@NEW_FIELD@\n", "0.35.2", digests)

    def test_template_refuses_to_install(self):
        result = subprocess.run(["sh", str(ROOT / "release/install.sh")], capture_output=True, text=True,
                                env={**os.environ, "HOME": "/nonexistent"}, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unpublished installer template", result.stderr)


@unittest.skipUnless(PLATFORM, "release installer supports macOS Apple Silicon and Linux x86-64")
class InstallTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="rui release ")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.home = self.root / "home"
        self.bin = self.home / ".local/bin"
        self.bin.mkdir(parents=True)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.served = self.root / "served"
        self.served.mkdir()
        # Fake curl serves only this release's exact archive URL.
        (self.tools / "curl").write_text(f'''#!/bin/sh
for argument; do
    case $argument in
        https://github.com/DivyanshGolyan/rui/releases/download/*) url=$argument ;;
    esac
    if [ "$previous" = -o ]; then output=$argument; fi
    previous=$argument
done
cp "{self.served}/${{url##*/download/}}" "$output"
''')
        (self.tools / "curl").chmod(0o755)
        self.environment = {**os.environ, "HOME": str(self.home),
                            "PATH": f"{self.tools}:{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin"}

    def archive(self, version, reported=None):
        """Serve a release archive whose rui reports `reported`; return its digest."""
        name = f"rui-{version}-{PLATFORM}"
        stage = self.root / "stage" / version / name
        (stage / "bin").mkdir(parents=True)
        (stage / "bin/rui").write_text(f'''#!/bin/sh
case $1 in
    --version) echo 'rui {reported or version} (abc123)' ;;
    host) echo 'Host unavailable' ;;
    *) echo '{version}' ;;
esac
''')
        (stage / "bin/rui-evaluator").write_text("#!/bin/sh\n")
        for binary in stage.glob("bin/*"):
            binary.chmod(0o755)
        (stage / "THIRD_PARTY_NOTICES.md").write_text("notices")
        path = self.served / f"v{version}" / f"{name}.tar.gz"
        path.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(path, "w:gz") as archive:
            archive.add(stage, arcname=name)
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def install(self, version, digest, *args):
        digests = {name: "0" * 64 for name in release.PLATFORMS}
        digests[PLATFORM] = digest
        script = self.root / f"install-{version}.sh"
        script.write_text(release.installer(TEMPLATE, version, digests))
        return subprocess.run(["sh", str(script), *args], cwd=self.root, env=self.environment,
                              capture_output=True, text=True, timeout=30)

    def test_install_update_preserves_data_and_previous_build(self):
        sentinels = [self.home / ".zshrc", self.home / ".config/rui/codex.json",
                     self.home / ".local/share/rui/store/saved"]
        for path in sentinels:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("keep")
        first = self.install("0.35.0", self.archive("0.35.0"))
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn("Installed rui 0.35.0 (abc123)", first.stdout)
        previous = (self.bin / "rui").resolve()
        second = self.install("0.35.1", self.archive("0.35.1"))
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(subprocess.check_output([self.bin / "rui"], text=True), "0.35.1\n")
        self.assertEqual(subprocess.check_output([previous], text=True), "0.35.0\n")
        self.assertTrue((self.bin / "rui-evaluator").resolve().is_relative_to(self.home.resolve() / ".local/lib/rui"))
        self.assertEqual([path.read_text() for path in sentinels], ["keep"] * 3)
        self.assertEqual(list(self.bin.glob(".rui-install.*")), [])
        self.assertEqual(len(list((self.home / ".local/lib/rui").glob("install.*/bin/rui"))), 2)
        self.assertIn("running Host keeps its old executable", second.stdout)

    def test_rejected_download_preserves_installed_commands(self):
        for name in ("rui", "rui-evaluator"):
            (self.bin / name).write_text("previous " + name)
        good = self.archive("0.35.0")
        cases = {
            "digest": ("0.35.0", "f" * 64, "does not match"),
            "version": ("0.35.9", self.archive("0.35.9", reported="0.35.8"), "not Rui 0.35.9"),
            "missing": ("0.35.7", good, ""),
        }
        for case, (version, digest, message) in cases.items():
            with self.subTest(case=case):
                result = self.install(version, digest)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn(message, result.stderr)
                for name in ("rui", "rui-evaluator"):
                    self.assertEqual((self.bin / name).read_text(), "previous " + name)
                self.assertEqual(list((self.home / ".local/lib/rui").glob("install.*")), [])

    def test_help_is_read_only_and_bad_arguments_fail(self):
        result = self.install("0.35.0", "0" * 64, "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Download Rui 0.35.0", result.stdout)
        self.assertFalse((self.home / ".local/lib").exists())
        self.assertNotEqual(self.install("0.35.0", "0" * 64, "--unknown").returncode, 0)


if __name__ == "__main__":
    unittest.main()
