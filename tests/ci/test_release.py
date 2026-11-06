import contextlib
import hashlib
import io
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
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
NEXT = "Next: ~/.local/bin/rui auth login codex (setup steps: https://github.com/DivyanshGolyan/rui#start-a-conversation)"


UNKNOWN_COMPATIBILITY = ("Could not establish compatibility for the defaults-selected Store. Host startup performs the authoritative check; "
                         "installing did not migrate or reset saved work. MySQL schema changes remain operator-owned.")


def unopenable(saved, supported=40, minimum=None):
    return (f"Your defaults-selected Store uses format {saved}; this build supports SQLite formats "
            f"{minimum or supported} through {supported}. Installing did not change the Store. "
            "Use a compatible build or follow the Store recovery guidance.")


def ready_host(controller, verb="host stop"):
    return (f"For the defaults-selected Store ~/.local/share/rui/store, {HOST} is ready. "
            "Its running build was not identified; installation did not restart it. "
            f"When its work finishes, pause it with: {controller} {verb} --store ~/.local/share/rui/store")


def retained_controller(controller, verb="host stop"):
    return ("For the defaults-selected Store ~/.local/share/rui/store, the selected command reported an "
            "incompatible Host; the retained command can reach a ready Host. Its running build was not identified; "
            "installation did not restart it. When its work finishes, pause it with: "
            f"{controller} {verb} --store ~/.local/share/rui/store")


def git(*args, cwd=None):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


# Fake builds from this minor version know host pause; earlier ones, host stop.
PAUSE_SINCE = 41

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


@unittest.skipUnless(PLATFORM, "release installer supports macOS Apple Silicon and Linux x86-64")
class InstallTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="rui release ")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name).resolve()
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
                            "PATH": f"{self.tools}:{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
                            "RUI_TEST_PUBLISH_HELPER": fake_rui.native_publisher()}

    def archive(self, version, reported=None):
        """Serve a release archive whose rui reports `reported`; return its digest."""
        name = f"rui-{version}-{PLATFORM}"
        path = self.served / f"v{version}" / f"{name}.tar.gz"
        if path.exists() and reported is None:
            return hashlib.sha256(path.read_bytes()).hexdigest()
        stage = self.root / "stage" / version / name
        minor = version.split(".")[1]
        (stage / "bin").mkdir(parents=True)
        (stage / "bin/rui").write_text(fake_rui.script(f"rui {reported or version} (abc123)", minor, version, pause=int(minor) >= PAUSE_SINCE))
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
        later = self.root / "later"
        missing = f"{self.bin} is not on your PATH. Add the installation directory to your shell profile, then open a new terminal:"
        exported = f"  export PATH=$'{self.bin}':\"$PATH\""
        cases = {
            "missing": (f"{self.tools}:/usr/bin:/bin", None, [installed, NEXT, missing, exported]),
            "missing, another rui": (f"{self.tools}:/usr/bin:/bin", self.tools, [
                installed, NEXT, f"{self.bin} is not on your PATH, which finds another rui at {self.tools}/rui. "
                "Add the installation directory to your shell profile, then open a new terminal:", exported]),
            "shadowed": (None, self.tools, [
                installed, NEXT, f"Your PATH finds another rui first, at {self.tools}/rui. Put {self.bin} before it "
                "in your PATH, then run hash -r (Bash) or rehash (Zsh)."]),
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

    def test_equal_release_does_not_assume_running_host_identity(self):
        self.report(self.install("0.40.0"))
        self.assertEqual(self.report(self.install("0.40.0", TEST_HOST="40")), [
            "Rui 0.40.0 is already selected. No installation changed.", ready_host(self.command())])

    def test_release_install_refuses_unmanaged_command(self):
        (self.bin / "rui").write_text("#!/bin/sh\necho usage\n")
        (self.bin / "rui").chmod(0o755)
        result = self.install("0.40.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.bin / "rui").read_text(), "#!/bin/sh\necho usage\n")

    def test_update_from_a_managed_command_without_a_version(self):
        earlier = self.home / ".local/lib/rui/install.earlier/bin"
        earlier.mkdir(parents=True)
        (earlier / "rui").write_text("#!/bin/sh\necho usage\n")
        (earlier / "rui").chmod(0o755)
        (self.bin / "rui").symlink_to(earlier / "rui")
        self.assertEqual(self.report(self.install("0.40.0")), [f"Updated Rui to 0.40.0. {KEPT}"])

    def test_manual_release_install_can_replace_tagged_managed_source(self):
        earlier = self.home / ".local/lib/rui/install.source"
        (earlier / "bin").mkdir(parents=True)
        (earlier / "bin/rui").write_text(fake_rui.script("rui 0.99.0 (dirty)", "40", "source"))
        (earlier / "bin/rui").chmod(0o755)
        (earlier / "revision").write_text("abcdef0 (local changes)\n")
        (self.bin / "rui").symlink_to(earlier / "bin/rui")
        result = self.install("0.40.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(subprocess.check_output([self.bin / "rui"], text=True), "0.40.0\n")

    def test_unsupported_format_reports_target_owned_range(self):
        self.report(self.install("0.37.5"))
        fake_rui.saved_work(self.home, 37)
        self.assertEqual(self.report(self.install("0.40.0")), [
            f"Updated Rui from 0.37.5 to 0.40.0. {KEPT}", unopenable(37),
        ])

    def test_format_change_reads_the_saved_format_not_the_version(self):
        self.report(self.install("0.40.0"))
        fake_rui.saved_work(self.home, 37)
        self.assertEqual(self.report(self.install("0.40.0")), [
            "Rui 0.40.0 is already selected. No installation changed.", unopenable(37)])
        self.start_over()
        self.report(self.install("0.37.5"))
        fake_rui.saved_work(self.home, 40)
        self.assertEqual(self.report(self.install("0.40.0")), [f"Updated Rui from 0.37.5 to 0.40.0. {KEPT}"])

    def test_unwritten_header_is_unknown_not_version_punctuation(self):
        self.report(self.install("0.37.5"))
        database = fake_rui.saved_work(self.home, 37, unwritten=True)
        self.addCleanup(database.close)
        self.assertEqual(self.report(self.install("0.40.0"))[1:], [
            UNKNOWN_COMPATIBILITY])

    def test_first_install_over_saved_work_of_another_format(self):
        fake_rui.saved_work(self.home, 37)
        self.assertEqual(self.report(self.install("0.40.0")), [
            "Installed Rui 0.40.0 at ~/.local/bin/rui.", unopenable(37),
            NEXT])

    def test_supported_startup_migration_is_not_a_reset(self):
        fake_rui.saved_work(self.home, 39)
        result = self.install("0.40.0", TEST_MINIMUM_SCHEMA="38")
        self.assertEqual(self.report(result)[1],
                         "Your defaults-selected SQLite Store uses format 39. Host startup can back it up and migrate it "
                         "to format 40; installing alone does not migrate it. MySQL schema changes remain operator-owned.")
        self.assertNotIn("fresh", result.stdout)

    def test_historical_target_without_range_facts_is_unknown(self):
        fake_rui.saved_work(self.home, 39)
        result = self.install("0.40.0", TEST_UNKNOWN_FACTS="1")
        self.assertIn(UNKNOWN_COMPATIBILITY, self.report(result))
        self.assertNotIn("cannot open", result.stdout)

    def test_incomplete_or_inverted_target_range_is_unknown(self):
        fake_rui.saved_work(self.home, 39)
        for facts in ('{"minimum_schema_version":38}', '{"schema_version":40}',
                      '{"schema_version":40,"minimum_schema_version":41}'):
            with self.subTest(facts=facts):
                result = self.install("0.40.0", TEST_FACTS=facts)
                self.assertIn(UNKNOWN_COMPATIBILITY, self.report(result))
                self.assertEqual(result.stderr, "")

    def test_older_installer_does_not_replace_or_report_losing_candidate(self):
        self.report(self.install("0.40.10"))
        selected = (self.bin / "rui").resolve()
        result = self.install("0.40.2")
        self.assertEqual(self.report(result), ["Rui 0.40.10 is already selected. No installation changed."])
        self.assertEqual((self.bin / "rui").resolve(), selected)

    def test_older_installer_uses_its_staged_path_helper(self):
        self.report(self.install("0.40.10"))
        selected = (self.bin / "rui").resolve()
        selected.write_text(selected.read_text().replace('case "$*" in\n',
            'case "$*" in\n    --installation-path) echo "selected command lacks this helper" >&2; exit 91 ;;\n'))
        result = self.install("0.40.2")
        self.assertEqual(self.report(result), ["Rui 0.40.10 is already selected. No installation changed."])
        self.assertEqual(result.stderr, "")
        self.assertEqual((self.bin / "rui").resolve(), selected)

    def test_host_states(self):
        incompatible = ("For the defaults-selected Store ~/.local/share/rui/store, the selected command reports "
                        "an incompatible Host; its running build was not identified. Installation did not restart it. "
                        "Use a compatible Rui command to inspect and pause it manually. Retained builds stay in ~/.local/lib/rui.")
        cases = {
            "ready after an update": (None, "40", [
                f"Updated Rui from 0.40.0 to 0.40.1. {KEPT}", ready_host("SELECTED")]),
            "ready at a first install": ("first", "40", [
                "Installed Rui 0.40.1 at ~/.local/bin/rui.", ready_host("SELECTED"), NEXT]),
            "different wire not identified": (None, "36", [
                f"Updated Rui from 0.40.0 to 0.40.1. {KEPT}", incompatible]),
            "future wire not called older": (None, "99", [
                f"Updated Rui from 0.40.0 to 0.40.1. {KEPT}", incompatible]),
            "ownership without readiness": (None, "busy", [
                f"Updated Rui from 0.40.0 to 0.40.1. {KEPT}",
                "For the defaults-selected Store ~/.local/share/rui/store, Host ownership was reported, but "
                "readiness was not confirmed. Its running build was not identified; installation did not restart it. "
                "Inspect it with: ~/.local/bin/rui host status --store ~/.local/share/rui/store"]),
        }
        for case, (first, host, expected) in cases.items():
            with self.subTest(case=case):
                self.start_over()
                if not first:
                    self.report(self.install("0.40.0"))
                result = self.install("0.40.1", TEST_HOST=host)
                self.assertEqual(self.report(result), [line.replace("SELECTED", self.command()) for line in expected])

    def test_reported_upgrade_from_0_37_5(self):
        self.report(self.install("0.37.5"))
        previous = self.command()
        fake_rui.saved_work(self.home, 37)
        result = self.install("0.40.0", TEST_HOST="37")
        self.assertEqual(self.report(result), [
            f"Updated Rui from 0.37.5 to 0.40.0. {KEPT}", unopenable(37),
            retained_controller(previous)])
        self.assertEqual(result.stderr, "")

    def test_an_unreachable_host_is_paused_with_its_own_builds_word(self):
        # Builds from 0.41 call the Host shutdown host pause; the report asks the old build.
        self.report(self.install("0.41.0"))
        previous = self.command()
        fake_rui.saved_work(self.home, 41)
        result = self.install("0.42.0", TEST_HOST="41")
        self.assertEqual(self.report(result)[-1], retained_controller(previous, "host pause"))

    def test_retained_controller_probe_names_the_observed_defaults_store(self):
        self.report(self.install("0.37.5"))
        previous = (self.bin / "rui").resolve()
        previous.write_text(previous.read_text().replace('store="$HOME/.local/share/rui/store"',
                                                       'store="$HOME/another-default-store"'))
        log = self.root / "status.log"
        result = self.install("0.40.0", TEST_HOST="37", TEST_STATUS_LOG=str(log))
        self.assertEqual(log.read_text().splitlines(), [
            f"host status --store {self.home}/.local/share/rui/store"])
        self.assertEqual(self.report(result)[-1], retained_controller(
            "~/" + str(previous.relative_to(self.home))))
        self.assertNotIn("another-default-store", result.stdout)

    def test_path_advice_failure_does_not_fail_or_undo_publication(self):
        result = self.install("0.40.0", TEST_PATH_FAULT="1")
        self.assertEqual(self.report(result), ["Installed Rui 0.40.0 at ~/.local/bin/rui.", NEXT])
        self.assertEqual(subprocess.check_output([self.bin / "rui"], text=True), "0.40.0\n")

    def test_report_never_fails_a_published_install(self):
        self.report(self.install("0.40.0"))
        database = self.home / ".local/share/rui/store/rui.sqlite3"
        database.parent.mkdir(parents=True)
        database.write_bytes(b"abc")
        result = self.install("0.40.1", TEST_REPORT_FAULT="1")
        self.assertEqual(self.report(result), [f"Updated Rui from 0.40.0 to 0.40.1. {KEPT}"])
        self.assertEqual(result.stderr, "Could not inspect the Host for the defaults-selected Store. Its identity and status "
                         "are unknown; installation did not restart it. The installation succeeded.\n")
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

    def test_bootstrap_archive_members_cannot_choose_filesystem_write_paths(self):
        version = "0.40.0"
        self.archive(version)
        archive_path = self.served / f"v{version}/rui-{version}-{PLATFORM}.tar.gz"
        escaped = self.root / "escaped"
        contents = io.BytesIO(archive_path.read_bytes())
        replacement = io.BytesIO()
        with tarfile.open(fileobj=contents, mode="r:gz") as original, \
             tarfile.open(fileobj=replacement, mode="w:gz") as changed:
            for member in original.getmembers():
                changed.addfile(member, original.extractfile(member) if member.isfile() else None)
            entry = tarfile.TarInfo(str(escaped))
            entry.size = 7
            changed.addfile(entry, io.BytesIO(b"escaped"))
        archive_path.write_bytes(replacement.getvalue())
        result = self.install(version, hashlib.sha256(archive_path.read_bytes()).hexdigest())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(escaped.exists())
        self.assertEqual(subprocess.check_output([self.bin / "rui"], text=True), "0.40.0\n")

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
