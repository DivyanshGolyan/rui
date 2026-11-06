#!/usr/bin/env python3
"""Source and release installer boundaries using an explicit production binary."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

import host_process
import os_semantics

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/ci"))
import fake_rui
import release

TEMPLATE = (ROOT / "release/install.sh").read_text()
PUBLISH = (ROOT / "release/publish.sh").read_text()
PLATFORM = os_semantics.native_release_target()


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

PAUSE_SINCE = 41

FAKE_ZIG = '''#!/usr/bin/env python3
import json, os, pathlib, re, sys
args = sys.argv[1:]
if args == ["version"]:
    print(os.environ.get("TEST_ZIG_VERSION", "0.17.0"))
    sys.exit(0)
assert "--global-cache-dir" not in args, "removed Zig 0.17 option"
cache = pathlib.Path(os.environ["ZIG_GLOBAL_CACHE_DIR"])
assert (cache / "tmp").is_dir(), "installer did not prepare the selected cache"
if args[0] == "fetch":
    name = next(arg.split("=", 1)[1] for arg in args if arg.startswith("--save="))
    manifest = pathlib.Path("build.zig.zon")
    value = manifest.read_text()
    package_hash = re.search(r"\\." + name + r" = .*?\\.hash = \\\"([^\\\"]+)\\\"", value, re.S)[1]
    if os.environ.get("TEST_HASH_FAILURE") in ("1", name):
        manifest.write_text(value.replace(package_hash, "incorrect-package-hash"))
    else:
        package = pathlib.Path(args[args.index("--pkg-dir") + 1]) / package_hash
        package.mkdir()
        contents = json.loads(os.environ.get("TEST_PACKAGE_MANIFESTS", "{}"))
        if package_hash in contents:
            (package / "build.zig.zon").write_text(contents[package_hash])
    sys.exit(0)
if "--fetch=all" in args:
    for package_hash in json.loads(os.environ.get("TEST_PACKAGE_MANIFESTS", "{}")):
        if not (pathlib.Path(os.environ["ZIG_LOCAL_PKG_DIR"]) / package_hash).is_dir():
            sys.exit("ResolvConfParseFailed: dependency not prepared: " + package_hash)
    sys.exit(0)
if os.environ.get("TEST_BUILD_FAILURE"):
    sys.exit(42)
assert "-Doptimize=ReleaseSafe" in args
prefix = pathlib.Path(args[args.index("--prefix") + 1])
(prefix / "bin").mkdir()
generation = os.environ.get("TEST_GENERATION", "first")
binary = prefix / "bin/rui"
binary.write_text(os.environ["TEST_RUI_SCRIPT"].replace("GENERATION", generation))
binary.chmod(0o755)
if os.environ.get("TEST_INVALID_BUILD"):
    (prefix / "bin/rui").write_text("#!/bin/sh\\nexit 3\\n")
(prefix / "THIRD_PARTY_NOTICES.md").write_text("test notices")
'''

class NativeInstallerCase(unittest.TestCase):
    def __init__(self, methodName, *, publisher):
        super().__init__(methodName)
        self.publisher = publisher


class ReleaseInstallerTest(NativeInstallerCase):
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
                            "RUI_TEST_PUBLISH_HELPER": str(self.publisher)}

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
        release_version = "0.40.0"
        self.archive(release_version)
        archive_path = self.served / f"v{release_version}/rui-{release_version}-{PLATFORM}.tar.gz"
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
        result = self.install(release_version, hashlib.sha256(archive_path.read_bytes()).hexdigest())
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

class SourceInstallerTest(NativeInstallerCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="rui install ")
        self.addCleanup(self.temporary.cleanup)
        # Resolved, so that git's top level matches install.sh's checkout path on macOS.
        self.root = Path(self.temporary.name).resolve()
        self.repo = self.root / "source checkout"
        self.repo.mkdir()
        shutil.copy2(ROOT / "install.sh", self.repo / "install.sh")
        (self.repo / "release").mkdir()
        shutil.copy2(ROOT / "release/publish.sh", self.repo / "release/publish.sh")
        (self.repo / "src/store").mkdir(parents=True)
        shutil.copy2(ROOT / "src/fetch_dependencies.sh", self.repo / "src/fetch_dependencies.sh")
        (self.repo / "src/store/schema.zig").write_text("pub const schema_version: u32 = 40;\n")
        self.manifest = '.{\n    .minimum_zig_version = "0.17.0",\n    .dependencies = .{\n'
        for name in ("openssl", "sqlite", "nghttp2", "utf8proc"):
            self.manifest += f'''        .{name} = .{{
            .url = "https://example.invalid/{name}.tar.gz",
            .hash = "test-{name}-hash",
        }},
'''
        self.manifest += '    },\n}\n'
        (self.repo / "build.zig.zon").write_text(self.manifest)
        (self.repo / "build.zig").write_text("fixture build root\n")
        self.home = self.root / "home"
        self.bin = self.home / ".local/bin"
        self.bin.mkdir(parents=True)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        (self.tools / "zig").write_text(FAKE_ZIG)
        (self.tools / "zig").chmod(0o755)
        (self.tools / "curl").write_text('''#!/usr/bin/env python3
import pathlib, sys
url = next(arg for arg in sys.argv if "://" in arg)
assert url.startswith("https://"), "curl requires an HTTPS archive URL"
if "codeberg.org/" in url:
    assert url in {
        "https://codeberg.org/ziglang/translate-c/archive/f978dca0f2b2a782d06591989e80aae7c74d0183.tar.gz",
        "https://codeberg.org/ziglang/arocc/archive/ffddc972f7a208bd6e254c27465407270fd8b60c.tar.gz",
    }, "archive URL must preserve the exact commit, without Git query or fragment"
if "github.com/" in url:
    assert url in {
        "https://github.com/ziglang/translate-c/archive/f978dca0f2b2a782d06591989e80aae7c74d0183.tar.gz",
        "https://github.com/ziglang/arocc/archive/ffddc972f7a208bd6e254c27465407270fd8b60c.tar.gz",
    }, "archive URL must preserve the exact commit, without .git, query or fragment"
pathlib.Path(sys.argv[sys.argv.index("-o") + 1]).write_bytes(b"fixture archive")
''')
        (self.tools / "curl").chmod(0o755)
        self.cache = self.root / "selected cache"
        self.environment = {
            **os.environ, "HOME": str(self.home), "ZIG_GLOBAL_CACHE_DIR": str(self.cache),
            "PATH": f"{self.tools}:{self.bin}:{os.environ['PATH']}",
            "ZIG_LOCAL_PKG_DIR": str(self.root / "selected packages"),
            "RUI_TEST_PUBLISH_HELPER": str(self.publisher),
            # An unreleased build: the report names it by its revision file.
            "TEST_RUI_SCRIPT": fake_rui.script("rui unreleased (0000000)", "40", "GENERATION"),
        }

    def install(self, *args, **environment):
        return subprocess.run(
            ["bash", str(self.repo / "install.sh"), *args], cwd=self.root,
            env={**self.environment, **environment}, capture_output=True, text=True, timeout=20,
        )

    def report(self, result):
        """What the installer said after publishing: the lines after its build output."""
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.split("\n\n", 1)[1].splitlines()

    def commit(self):
        """Commit the fixture checkout, so its build is named by a short revision."""
        def git(*args):
            return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], cwd=self.repo,
                                  check=True, capture_output=True, text=True).stdout.strip()
        git("init", "-q")
        with open(self.repo / "history", "a") as history:
            history.write("commit\n")
        git("add", "-A")
        git("commit", "-qm", "fixture")
        return git("rev-parse", "--short", "HEAD")

    def test_install_update_preserves_data_and_complete_previous_build(self):
        sentinels = [self.home / ".zshrc", self.home / ".config/rui/credentials",
                     self.home / ".local/share/rui/store/saved"]
        for path in sentinels:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("keep")
        before = self.commit()
        self.assertEqual(self.report(self.install()), [f"Installed Rui {before} at ~/.local/bin/rui.", NEXT])
        previous = (self.bin / "rui").resolve()
        after = self.commit()
        second = self.install(TEST_GENERATION="second")
        self.assertEqual(self.report(second), [f"Updated Rui from {before} to {after}. Saved work and sign-in were kept."])
        self.assertEqual(subprocess.check_output([self.bin / "rui"], text=True), "second\n")
        self.assertEqual(subprocess.check_output([previous], text=True), "first\n")
        self.assertTrue(((self.bin / "rui").resolve().parent.parent / "THIRD_PARTY_NOTICES.md").exists())
        self.assertEqual([path.read_text() for path in sentinels], ["keep"] * 3)
        self.assertEqual((self.repo / "build.zig.zon").read_text(), self.manifest)

    def test_source_install_reads_the_store_format_from_the_checkout(self):
        source = (ROOT / "src/store/schema.zig").read_text()
        (self.repo / "src/store/schema.zig").write_text(source)
        supported = int(release.SCHEMA.search(source)[1])
        fake_rui.saved_work(self.home, supported - 1)
        script = fake_rui.script("rui unreleased (0000000)", str(supported), "GENERATION")
        result = self.install(TEST_RUI_SCRIPT=script, TEST_MINIMUM_SCHEMA=str(supported - 1))
        self.assertEqual(self.report(result)[1:2], [
            f"Your defaults-selected SQLite Store uses format {supported - 1}. Host startup can back it up and migrate it "
            f"to format {supported}; installing alone does not migrate it. MySQL schema changes remain operator-owned."])

    def test_missing_schema_declaration_refuses_before_building(self):
        (self.bin / "rui").write_text("previous rui")
        (self.repo / "src/store/schema.zig").write_text("const schema_version = 40;\n")
        result = self.install()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("src/store/schema.zig declares no schema_version. No installation changed.", result.stderr)
        self.assertNotIn("Building", result.stdout)
        self.assertEqual((self.bin / "rui").read_text(), "previous rui")
        self.assertFalse((self.home / ".local/lib/rui").exists())

    def test_update_over_a_build_with_the_retired_evaluator_leaves_it_untouched(self):
        earlier = self.home / ".local/lib/rui/install.earlier/bin"
        earlier.mkdir(parents=True)
        for name in ("rui", "rui-evaluator"):
            (earlier / name).write_text("#!/bin/sh\nprintf 'earlier\\n'\n")
            (earlier / name).chmod(0o755)
            (self.bin / name).symlink_to(earlier / name)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(subprocess.check_output([self.bin / "rui"], text=True), "first\n")
        self.assertEqual((self.bin / "rui-evaluator").resolve(), (earlier / "rui-evaluator").resolve())

    def test_failed_build_or_validation_preserves_installed_commands(self):
        (self.bin / "rui").write_text("previous rui")
        for failure in ({"TEST_HASH_FAILURE": "1"}, {"TEST_BUILD_FAILURE": "1"}, {"TEST_INVALID_BUILD": "1"},
                        {"TEST_ZIG_VERSION": "0.15.2"}):
            with self.subTest(failure=failure):
                result = self.install(**failure)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual((self.bin / "rui").read_text(), "previous rui")
                self.assertEqual(list((self.home / ".local/lib/rui").glob("install.*")), [])
                self.assertEqual((self.repo / "build.zig.zon").read_text(), self.manifest)

    def test_help_is_read_only_and_bad_arguments_fail(self):
        result = self.install("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Usage: ./install.sh", result.stdout)
        self.assertFalse(self.cache.exists())
        self.assertFalse((self.home / ".local/lib").exists())
        self.assertNotEqual(self.install("--unknown").returncode, 0)

    def test_git_dependency_graph_is_prepared_and_hash_checked(self):
        self.check_git_dependency_graph("codeberg.org")

    def test_github_dependency_graph_is_prepared_and_hash_checked(self):
        self.check_git_dependency_graph("github.com", suffix=".git")

    def check_git_dependency_graph(self, host, suffix=""):
        translator = '''        .translate_c = .{
            .url = "git+https://HOST/ziglang/translate-cSUFFIX#f978dca0f2b2a782d06591989e80aae7c74d0183",
            .hash = "test-translator-hash",
        },
'''.replace("HOST", host).replace("SUFFIX", suffix)
        manifest = self.manifest.replace('    .dependencies = .{\n', '    .dependencies = .{\n' + translator)
        (self.repo / "build.zig.zon").write_text(manifest)
        manifests = {
            "test-translator-hash": '''.{
    .dependencies = .{
        .aro = .{
            .url = "git+https://HOST/ziglang/aroccSUFFIX?ref=zig-0.17.x#ffddc972f7a208bd6e254c27465407270fd8b60c",
            .hash = "test-parser-hash",
        },
    },
}
'''.replace("HOST", host).replace("SUFFIX", suffix),
            "test-parser-hash": '.{\n    .dependencies = .{},\n}\n',
        }
        environment = {"TEST_PACKAGE_MANIFESTS": json.dumps(manifests)}
        failed = self.install(**environment, TEST_HASH_FAILURE="aro")
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("Pinned aro dependency hash mismatch", failed.stderr)
        self.assertFalse((self.bin / "rui").exists())
        self.assertEqual((self.repo / "build.zig.zon").read_text(), manifest)
        cached_manifest = self.root / "selected packages/test-translator-hash/build.zig.zon"
        self.assertEqual(cached_manifest.read_text(), manifests["test-translator-hash"])
        self.assertFalse((self.root / "selected packages/test-parser-hash").exists())
        # The translator is already cached; its missing child still needs preparation.
        result = self.install(**environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.repo / "build.zig.zon").read_text(), manifest)
        self.assertEqual(cached_manifest.read_text(), manifests["test-translator-hash"])
        self.assertEqual((self.root / "selected packages/test-parser-hash/build.zig.zon").read_text(),
                         manifests["test-parser-hash"])
        repeated = self.install(**environment, TEST_HASH_FAILURE="1")
        self.assertEqual(repeated.returncode, 0, repeated.stderr)

    def test_github_abbreviated_commit_is_refused_without_install(self):
        manifest = self.manifest.replace(
            "https://example.invalid/openssl.tar.gz",
            "git+https://github.com/ziglang/translate-c.git#f978dca",
        )
        (self.repo / "build.zig.zon").write_text(manifest)
        # If revision validation is removed, fake curl would accept this archive.
        curl = self.tools / "curl"
        curl.write_text(curl.read_text().replace(
            '"https://github.com/ziglang/translate-c/archive/f978dca0f2b2a782d06591989e80aae7c74d0183.tar.gz",',
            '"https://github.com/ziglang/translate-c/archive/f978dca.tar.gz",',
        ))
        result = self.install()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("Preparing pinned openssl dependency", result.stdout)
        self.assertFalse((self.bin / "rui").exists())
        self.assertFalse((self.root / "selected packages/test-openssl-hash").exists())
        self.assertEqual((self.repo / "build.zig.zon").read_text(), manifest)

    def test_cached_git_dependencies_still_require_full_commits(self):
        cached_manifest = self.root / "selected packages/test-openssl-hash/build.zig.zon"
        for host in ("github.com", "codeberg.org"):
            for fragment in ("#f978dca", "", "#", "#ignored#f978dca0f2b2a782d06591989e80aae7c74d0183"):
                for route in ("cached", "deduplicated", "transitive"):
                    with self.subTest(host=host, fragment=fragment, route=route):
                        (self.repo / "build.zig.zon").write_text(self.manifest)
                        first = self.install()
                        self.assertEqual(first.returncode, 0, first.stderr)
                        previous = {"rui": (self.bin / "rui").resolve()}
                        url = f"git+https://{host}/ziglang/translate-c.git{fragment}"
                        alias = f'''        .alias = .{{
            .url = "{url}",
            .hash = "test-openssl-hash",
        }},
'''
                        manifest = self.manifest
                        if route == "cached":
                            manifest = manifest.replace("https://example.invalid/openssl.tar.gz", url)
                        elif route == "deduplicated":
                            manifest = manifest.replace('    },\n}\n', alias + '    },\n}\n')
                        else:
                            cached_manifest.write_text('.{\n    .dependencies = .{\n' + alias + '    },\n}\n')
                        try:
                            (self.repo / "build.zig.zon").write_text(manifest)
                            result = self.install(TEST_GENERATION="rejected")
                            self.assertNotEqual(result.returncode, 0, result.stdout)
                            self.assertNotIn("Preparing pinned", result.stdout)
                            name = "openssl" if route == "cached" else "alias"
                            self.assertIn(f"Pinned {name} Git dependency", result.stderr)
                            self.assertIn(str(cached_manifest if route == "transitive" else self.repo / "build.zig.zon"), result.stderr)
                            self.assertIn("40-character hexadecimal commit ID", result.stderr)
                            for name, target in previous.items():
                                self.assertEqual((self.bin / name).resolve(), target)
                                self.assertEqual(subprocess.check_output([self.bin / name], text=True), "first\n")
                            self.assertEqual((self.repo / "build.zig.zon").read_text(), manifest)
                            if route == "transitive":
                                self.assertEqual(cached_manifest.read_text(), '.{\n    .dependencies = .{\n' + alias + '    },\n}\n')
                        finally:
                            cached_manifest.unlink(missing_ok=True)

    def test_path_conflict_is_actionable(self):
        shadow = self.tools / "rui"
        shadow.write_text("#!/bin/sh\nexit 0\n")
        shadow.chmod(0o755)
        self.assertEqual(self.report(self.install()), [
            "Installed Rui source archive at ~/.local/bin/rui.", NEXT,
            f"Your PATH finds another rui first, at {shadow}. Put {self.bin} before it in your PATH, "
            "then run hash -r (Bash) or rehash (Zsh)."])

def installer_suite(publisher):
    loader = unittest.TestLoader()
    return unittest.TestSuite(
        case(name, publisher=publisher)
        for case in (ReleaseInstallerTest, SourceInstallerTest)
        for name in loader.getTestCaseNames(case)
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("publisher", type=Path, help="compiled production Rui executable")
    args = parser.parse_args()
    publisher = args.publisher.resolve(strict=True)
    if not publisher.is_file() or not os.access(publisher, os.X_OK):
        parser.error("publisher must be an executable file")
    if PLATFORM is None:
        parser.error("installer cases require a supported native release platform")
    result = unittest.TextTestRunner(verbosity=2).run(installer_suite(publisher))
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    host_process.enter()
    sys.exit(main())
