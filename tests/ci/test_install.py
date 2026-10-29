import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
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
binary.write_text("#!/bin/sh\\nprintf '%s\\\\n' '" + generation + "'\\n")
binary.chmod(0o755)
if os.environ.get("TEST_INVALID_BUILD"):
    (prefix / "bin/rui").write_text("#!/bin/sh\\nexit 3\\n")
(prefix / "THIRD_PARTY_NOTICES.md").write_text("test notices")
'''


class InstallTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="rui install ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "source checkout"
        self.repo.mkdir()
        shutil.copy2(ROOT / "install.sh", self.repo / "install.sh")
        (self.repo / "src").mkdir()
        shutil.copy2(ROOT / "src/fetch_dependencies.sh", self.repo / "src/fetch_dependencies.sh")
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
        }

    def install(self, *args, **environment):
        return subprocess.run(
            ["bash", str(self.repo / "install.sh"), *args], cwd=self.root,
            env={**self.environment, **environment}, capture_output=True, text=True, timeout=20,
        )

    def test_install_update_preserves_data_and_complete_previous_build(self):
        sentinels = [self.home / ".zshrc", self.home / ".config/rui/credentials",
                     self.home / ".local/share/rui/store/saved"]
        for path in sentinels:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("keep")
        first = self.install()
        self.assertEqual(first.returncode, 0, first.stderr)
        previous = (self.bin / "rui").resolve()
        second = self.install(TEST_GENERATION="second")
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(subprocess.check_output([self.bin / "rui"], text=True), "second\n")
        self.assertEqual(subprocess.check_output([previous], text=True), "first\n")
        self.assertTrue(((self.bin / "rui").resolve().parent.parent / "THIRD_PARTY_NOTICES.md").exists())
        self.assertEqual([path.read_text() for path in sentinels], ["keep"] * 3)
        self.assertIn("running Host keeps its old executable", second.stdout)
        self.assertEqual((self.repo / "build.zig.zon").read_text(), self.manifest)

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
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"Your PATH currently selects: {shadow}", result.stdout)
        self.assertIn('export PATH="$HOME/.local/bin:$PATH"', result.stdout)
        self.assertIn("rehash", result.stdout)


if __name__ == "__main__":
    unittest.main()
