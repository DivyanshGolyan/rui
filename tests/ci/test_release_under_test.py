import os
from pathlib import Path
import shlex
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import unittest

import release_under_test

SCRIPT = Path(__file__).with_name("release_under_test.py")
VERSION, SHA, TARGET = "0.80.0", "a" * 40, "linux-x86_64"


class FetchTest(unittest.TestCase):
    """The fetcher prints only a verified executable's path, or fails non-zero."""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.root)], check=True)
        self.calls = self.root / "calls"
        self.bin = self.root / "bin"
        self.bin.mkdir()

    def archive(self, reports=f"rui {VERSION} ({SHA})", corrupt=False):
        """Build the artifact gh would download: the archive Release build uploads."""
        name = f"rui-{VERSION}-{TARGET}"
        built = self.root / "artifact"
        executable = built / name / "bin/rui"
        executable.parent.mkdir(parents=True)
        executable.write_text(f"#!/bin/sh\necho {shlex.quote(reports)}\n")
        executable.chmod(0o755)
        archive = self.root / "artifact.tar.gz"
        if corrupt:
            archive.write_bytes(b"not a gzip archive")
        else:
            with tarfile.open(archive, "w:gz") as tar:
                tar.add(built / name, arcname=name)
        return archive

    def fake_gh(self, archive, failures):
        """A gh that fails its first FAILURES downloads, printing to stdout as the real one may."""
        gh = self.bin / "gh"
        gh.write_text(textwrap.dedent(f"""\
            #!/bin/sh
            echo "$*" >> {self.calls}
            echo "gh progress on stdout"
            test "$(wc -l < {self.calls})" -gt {failures} || exit 1
            while [ "$1" != --dir ]; do shift; done
            cp {archive} "$2/rui-{VERSION}-{TARGET}.tar.gz"
            """))
        gh.chmod(0o755)

    def run_fetch(self, failures=0, **archive):
        self.fake_gh(self.archive(**archive), failures)
        waits = []
        search = os.environ["PATH"]
        os.environ["PATH"] = f"{self.bin}{os.pathsep}{search}"
        try:
            path = release_under_test.fetch("7", "o/r", TARGET, VERSION, SHA, self.root / "out", sleep=waits.append)
            outcome = None
        except (SystemExit, subprocess.CalledProcessError) as failure:
            path, outcome = None, str(failure)
        finally:
            os.environ["PATH"] = search
        return path, outcome, waits, self.calls.read_text().splitlines()

    def test_immediate_success_returns_the_identified_executable(self):
        path, outcome, waits, calls = self.run_fetch()
        self.assertIsNone(outcome)
        self.assertEqual(path, (self.root / "out" / f"rui-{VERSION}-{TARGET}/bin/rui").resolve())
        self.assertEqual(waits, [])
        self.assertEqual(calls, [f"run download 7 --repo o/r --name rui-{TARGET} --dir {self.root / 'out'}"])

    def test_transient_failures_retry_after_each_delay(self):
        path, outcome, waits, calls = self.run_fetch(failures=2)
        self.assertIsNone(outcome)
        self.assertIsNotNone(path)
        self.assertEqual(waits, list(release_under_test.RETRY_DELAYS))
        self.assertEqual(len(calls), 3)

    def test_exhausted_retries_name_the_artifact(self):
        path, outcome, waits, calls = self.run_fetch(failures=3)
        self.assertEqual(outcome, f"could not download artifact rui-{TARGET}")
        self.assertEqual(waits, list(release_under_test.RETRY_DELAYS))
        self.assertEqual(len(calls), 3)

    def test_an_archive_that_does_not_extract_fails(self):
        path, outcome, _, _ = self.run_fetch(corrupt=True)
        self.assertIsNone(path)
        self.assertEqual(outcome, f"could not extract rui-{VERSION}-{TARGET}.tar.gz")

    def test_an_executable_of_another_release_fails(self):
        path, outcome, _, _ = self.run_fetch(reports=f"rui {VERSION} ({'b' * 40})")
        self.assertIsNone(path)
        self.assertIn(f"not release {VERSION} at {SHA}", outcome)

    def test_the_command_prints_only_the_path_even_after_a_retry(self):
        """Callers capture stdout as the path; warnings and gh output must stay on stderr."""
        self.fake_gh(self.archive(), failures=1)
        script = (f"import sys; sys.argv[1:] = {[VERSION, SHA, str(self.root / 'out')]!r}; "
                  f"sys.path.insert(0, {str(SCRIPT.parent)!r}); import release_under_test as r; "
                  "r.RETRY_DELAYS = (0, 0); r.PLATFORMS = dict.fromkeys(r.PLATFORMS, 'linux-x86_64'); "
                  "sys.exit(r.main())")
        result = subprocess.run([sys.executable, "-B", "-c", script], capture_output=True, text=True, check=False,
                                env={**os.environ, "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
                                     "GITHUB_RUN_ID": "7", "GITHUB_REPOSITORY": "o/r"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"{(self.root / 'out' / f'rui-{VERSION}-{TARGET}/bin/rui').resolve()}\n")
        self.assertIn("::warning::Artifact download failed", result.stderr)
        self.assertIn("gh progress on stdout", result.stderr)

    def test_a_failed_fetch_exits_non_zero_from_the_command(self):
        self.fake_gh(self.archive(reports="rui 0.1.0 (other)"), failures=0)
        script = (f"import sys; sys.argv[1:] = {[VERSION, SHA, str(self.root / 'out')]!r}; "
                  f"sys.path.insert(0, {str(SCRIPT.parent)!r}); import release_under_test as r; "
                  "r.PLATFORMS = dict.fromkeys(r.PLATFORMS, 'linux-x86_64'); sys.exit(r.main())")
        result = subprocess.run([sys.executable, "-B", "-c", script], capture_output=True, text=True, check=False,
                                env={**os.environ, "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
                                     "GITHUB_RUN_ID": "7", "GITHUB_REPOSITORY": "o/r"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
