import contextlib
import hashlib
import io
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import unittest

import fake_rui
import release

ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = (ROOT / "release/install.sh").read_text()
PUBLISH = (ROOT / "release/publish.sh").read_text()
PLATFORM = {("Darwin", "arm64"): "darwin-arm64", ("Linux", "x86_64"): "linux-x86_64"}.get(
    (platform.system(), platform.machine()))
KEPT = "Saved work and sign-in were kept."
HOST = "Rui's background Host (the process that runs your Sessions)"
NEXT = "Next: rui auth login codex (setup steps: https://github.com/DivyanshGolyan/rui#start-a-conversation)"
FRESH = "  Or start fresh: https://github.com/DivyanshGolyan/rui/blob/main/docs/store-reset.md"
EXPORT = '  export PATH="$HOME/.local/bin:$PATH"'


def unopenable(saved, supported=40):
    return (f"Rui 0.{supported}.0 cannot open your saved work in ~/.local/share/rui/store: that Store uses "
            f"format {saved}, and this version uses format {supported}. Nothing was changed or deleted. Choose one:")


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
        path = self.served / f"v{version}" / f"{name}.tar.gz"
        if path.exists() and reported is None:
            return hashlib.sha256(path.read_bytes()).hexdigest()
        stage = self.root / "stage" / version / name
        (stage / "bin").mkdir(parents=True)
        (stage / "bin/rui").write_text(fake_rui.script(f"rui {reported or version} (abc123)", version.split(".")[1], version))
        (stage / "bin/rui").chmod(0o755)
        (stage / "THIRD_PARTY_NOTICES.md").write_text("notices")
        path.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(path, "w:gz") as archive:
            archive.add(stage, arcname=name)
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def install(self, version, digest=None, *args, **environment):
        digests = {name: "0" * 64 for name in release.PLATFORMS}
        digests[PLATFORM] = digest or self.archive(version)
        script = self.root / f"install-{version}.sh"
        script.write_text(release.installer(TEMPLATE, version, digests, PUBLISH))
        return subprocess.run(["sh", str(script), *args], cwd=self.root, env={**self.environment, **environment},
                              capture_output=True, text=True, timeout=30)

    def report(self, result):
        """What the installer said after publishing: the lines after its progress."""
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.split("\n\n", 1)[1].splitlines()

    def command(self):
        """The build the command runs, as the report prints it."""
        # readlink, not resolve(): macOS resolves /var to /private/var; the report does not.
        return "~/" + str(Path(os.readlink(self.bin / "rui")).relative_to(self.home))

    def start_over(self):
        shutil.rmtree(self.home)
        self.bin.mkdir(parents=True)
        for directory in (self.tools, self.root / "later"):
            (directory / "rui").unlink(missing_ok=True)

    def other_rui(self, directory):
        directory.mkdir(exist_ok=True)
        (directory / "rui").write_text("#!/bin/sh\necho other\n")
        (directory / "rui").chmod(0o755)
        return directory / "rui"

    def test_first_install_reports_only_location_and_next_step(self):
        result = self.install("0.40.0")
        self.assertEqual(result.stdout, f"Downloading Rui 0.40.0 for {PLATFORM} ...\nChecking the downloaded command ...\n\n"
                                        f"Installed Rui 0.40.0 at ~/.local/bin/rui.\n{NEXT}\n")
        self.assertEqual(result.stderr, "")

    def test_first_install_path_states(self):
        installed = "Installed Rui 0.40.0 at ~/.local/bin/rui."
        full_next = NEXT.replace("Next: rui", "Next: ~/.local/bin/rui")
        later = self.root / "later"
        missing = "~/.local/bin is not on your PATH. Add this line to your shell profile, then open a new terminal:"
        cases = {
            "missing": (f"{self.tools}:/usr/bin:/bin", None, [installed, missing, EXPORT, full_next]),
            "missing, another rui": (f"{self.tools}:/usr/bin:/bin", self.tools, [
                installed, f"~/.local/bin is not on your PATH, which finds another rui at {self.tools}/rui. "
                "Add this line to your shell profile, then open a new terminal:", EXPORT, full_next]),
            "shadowed": (None, self.tools, [
                installed, f"Your PATH finds another rui first, at {self.tools}/rui. Put ~/.local/bin before it "
                "in your PATH, then run hash -r (Bash) or rehash (Zsh).", full_next]),
            "another rui later": (f"{self.tools}:{self.bin}:{later}:/usr/bin:/bin", later, [installed, NEXT]),
            "unnormalized and repeated": (f"{self.tools}:{self.home}/.local/./bin:{self.bin}:/usr/bin:/bin", None,
                                          [installed, NEXT]),
        }
        for case, (path, other, expected) in cases.items():
            with self.subTest(case=case):
                self.start_over()
                if other:
                    self.other_rui(other)
                result = self.install("0.40.0", PATH=path or self.environment["PATH"])
                self.assertEqual(self.report(result), expected)

    def test_update_preserves_data_and_reports_versions(self):
        sentinels = [self.home / ".zshrc", self.home / ".config/rui/codex.json",
                     self.home / ".local/share/rui/store/saved"]
        for path in sentinels:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("keep")
        self.report(self.install("0.35.0"))
        previous = (self.bin / "rui").resolve()
        fake_rui.saved_work(self.home, 35)
        second = self.install("0.35.1")
        self.assertEqual(self.report(second), [f"Updated Rui from 0.35.0 to 0.35.1. {KEPT}"])
        self.assertEqual(subprocess.check_output([self.bin / "rui"], text=True), "0.35.1\n")
        self.assertEqual(subprocess.check_output([previous], text=True), "0.35.0\n")
        self.assertEqual([path.read_text() for path in sentinels], ["keep"] * 3)
        self.assertEqual(list(self.bin.glob(".rui-install.*")), [])
        self.assertEqual(len(list((self.home / ".local/lib/rui").glob("install.*/bin/rui"))), 2)

    def test_reinstall_reports_reinstalled_and_no_ready_host(self):
        self.report(self.install("0.40.0"))
        self.assertEqual(self.report(self.install("0.40.0", TEST_HOST="40")), [f"Reinstalled Rui 0.40.0. {KEPT}"])

    def test_update_from_a_command_without_a_version(self):
        (self.bin / "rui").write_text("#!/bin/sh\necho usage\n")
        (self.bin / "rui").chmod(0o755)
        self.assertEqual(self.report(self.install("0.40.0")), [f"Updated Rui to 0.40.0. {KEPT}"])

    def test_format_change_names_previous_build_and_reset_guide(self):
        self.report(self.install("0.37.5"))
        previous = self.command()
        fake_rui.saved_work(self.home, 37)
        self.assertEqual(self.report(self.install("0.40.0")), [
            f"Updated Rui from 0.37.5 to 0.40.0. {KEPT}", unopenable(37),
            f"  Keep using it with your previous build, Rui 0.37.5: {previous}", FRESH])

    def test_format_change_reads_the_saved_format_not_the_version(self):
        self.report(self.install("0.40.0"))
        fake_rui.saved_work(self.home, 37)
        self.assertEqual(self.report(self.install("0.40.0")), [
            f"Reinstalled Rui 0.40.0. {KEPT}", unopenable(37),
            "  Keep using it with a Rui build that opens format 37. Earlier builds stay in ~/.local/lib/rui.", FRESH])
        self.start_over()
        self.report(self.install("0.37.5"))
        fake_rui.saved_work(self.home, 40)
        self.assertEqual(self.report(self.install("0.40.0")), [f"Updated Rui from 0.37.5 to 0.40.0. {KEPT}"])

    def test_unwritten_header_uses_the_previous_release_format(self):
        self.report(self.install("0.37.5"))
        previous = self.command()
        database = fake_rui.saved_work(self.home, 37, unwritten=True)
        self.addCleanup(database.close)
        self.assertEqual(self.report(self.install("0.40.0"))[1:], [
            unopenable(37), f"  Keep using it with your previous build, Rui 0.37.5: {previous}", FRESH])

    def test_first_install_over_saved_work_of_another_format(self):
        fake_rui.saved_work(self.home, 37)
        self.assertEqual(self.report(self.install("0.40.0")), [
            "Installed Rui 0.40.0 at ~/.local/bin/rui.", unopenable(37),
            "  Keep using it with a Rui build that opens format 37. Earlier builds stay in ~/.local/lib/rui.", FRESH,
            NEXT])

    def test_host_states(self):
        cases = {
            "ready after an update": (None, "40", [
                f"Updated Rui from 0.40.0 to 0.40.1. {KEPT}",
                f"{HOST} is still running an earlier build. When its work finishes, run: rui host stop"]),
            "ready at a first install": ("first", "40", [
                "Installed Rui 0.40.1 at ~/.local/bin/rui.",
                f"{HOST} is already running another Rui build. When its work finishes, run: rui host stop", NEXT]),
            "no build here can reach it": (None, "36", [
                f"Updated Rui from 0.40.0 to 0.40.1. {KEPT}",
                f"{HOST} is still running an older build, and this version cannot stop it. Stop it with the "
                "build that started it. Earlier builds stay in ~/.local/lib/rui."]),
            "holds the Store without answering": (None, "busy", [
                f"Updated Rui from 0.40.0 to 0.40.1. {KEPT}",
                f"{HOST} holds your saved work but did not answer. Before you start work, check it with: rui host status"]),
        }
        for case, (first, host, expected) in cases.items():
            with self.subTest(case=case):
                self.start_over()
                if not first:
                    self.report(self.install("0.40.0"))
                self.assertEqual(self.report(self.install("0.40.1", TEST_HOST=host)), expected)

    def test_reported_upgrade_from_0_37_5(self):
        self.report(self.install("0.37.5"))
        previous = self.command()
        fake_rui.saved_work(self.home, 37)
        result = self.install("0.40.0", TEST_HOST="37")
        self.assertEqual(self.report(result), [
            f"Updated Rui from 0.37.5 to 0.40.0. {KEPT}", unopenable(37),
            f"  Keep using it with your previous build, Rui 0.37.5: {previous}", FRESH,
            f"{HOST} is still running Rui 0.37.5, and this version cannot stop it. When its work finishes, "
            f"run: {previous} host stop"])
        self.assertEqual(result.stderr, "")

    def test_report_never_fails_a_published_install(self):
        self.report(self.install("0.40.0"))
        database = self.home / ".local/share/rui/store/rui.sqlite3"
        database.parent.mkdir(parents=True)
        database.write_bytes(b"abc")
        result = self.install("0.40.1", TEST_REPORT_FAULT="1")
        self.assertEqual(self.report(result), [f"Updated Rui from 0.40.0 to 0.40.1. {KEPT}"])
        self.assertEqual(result.stderr, f"Could not check whether {HOST} is running. The installation succeeded.\n")
        self.assertEqual(subprocess.check_output([self.bin / "rui"], text=True), "0.40.1\n")
        self.assertEqual(list(self.bin.glob(".rui-install.*")), [])

    def test_update_over_a_release_with_the_retired_evaluator_leaves_it_untouched(self):
        earlier = self.home / ".local/lib/rui/install.earlier/bin"
        earlier.mkdir(parents=True)
        for name in ("rui", "rui-evaluator"):
            (earlier / name).write_text("#!/bin/sh\necho earlier\n")
            (earlier / name).chmod(0o755)
            (self.bin / name).symlink_to(earlier / name)
        result = self.install("0.35.0", self.archive("0.35.0"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(subprocess.check_output([self.bin / "rui"], text=True), "0.35.0\n")
        self.assertEqual((self.bin / "rui-evaluator").resolve(), (earlier / "rui-evaluator").resolve())

    def test_rejected_download_preserves_installed_commands(self):
        (self.bin / "rui").write_text("previous rui")
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
                self.assertEqual((self.bin / "rui").read_text(), "previous rui")
                self.assertEqual(list((self.home / ".local/lib/rui").glob("install.*")), [])

    def test_help_is_read_only_and_bad_arguments_fail(self):
        result = self.install("0.35.0", "0" * 64, "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Download Rui 0.35.0", result.stdout)
        self.assertFalse((self.home / ".local/lib").exists())
        self.assertNotEqual(self.install("0.35.0", "0" * 64, "--unknown").returncode, 0)


if __name__ == "__main__":
    unittest.main()
