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
VERSION, SHA = "0.80.0", "a" * 40


class FetchTest(unittest.TestCase):
    """CI-67: a promotion tier tests its own run's release executable, or fails without a path."""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.root)], check=True)

    def fixture(self, case, failures, reports, corrupt):
        """A gh that fails its first FAILURES downloads, printing on stdout as the real one may,
        then delivers the archive Release build uploads for linux-x86_64."""
        root = self.root / case
        built, bin_dir = root / "artifact", root / "bin"
        executable = built / "rui-0.80.0-linux-x86_64/bin/rui"
        executable.parent.mkdir(parents=True)
        bin_dir.mkdir()
        executable.write_text(f"#!/bin/sh\necho {shlex.quote(reports)}\n")
        executable.chmod(0o755)
        archive = root / "artifact.tar.gz"
        if corrupt:
            archive.write_bytes(b"not a gzip archive")
        else:
            with tarfile.open(archive, "w:gz") as tar:
                tar.add(built / "rui-0.80.0-linux-x86_64", arcname="rui-0.80.0-linux-x86_64")
        calls = root / "calls"
        gh = bin_dir / "gh"
        gh.write_text(textwrap.dedent(f"""\
            #!/bin/sh
            echo "$*" >> {shlex.quote(str(calls))}
            echo "gh progress on stdout"
            test "$(wc -l < {shlex.quote(str(calls))})" -gt {failures} || exit 1
            while [ "$1" != --dir ]; do shift; done
            cp {shlex.quote(str(archive))} "$2/rui-0.80.0-linux-x86_64.tar.gz"
            """))
        gh.chmod(0o755)
        return root, calls, bin_dir

    def test_whole_domain(self):
        good = f"rui {VERSION} ({SHA})"
        # case: (download failures, what the executable reports, corrupt archive,
        #        expected waits, expected download calls, expected failure or None)
        cases = {
            "immediate success": (0, good, False, [], 1, None),
            "retry success": (2, good, False, [10, 30], 3, None),
            "exhausted retries": (3, good, False, [10, 30], 3, "could not download artifact rui-linux-x86_64"),
            "archive does not extract": (0, good, True, [], 1, "could not extract rui-0.80.0-linux-x86_64.tar.gz"),
            "another release": (0, f"rui {VERSION} ({'b' * 40})", False, [], 1,
                                f"reports 'rui 0.80.0 ({'b' * 40})\\n', not release 0.80.0 at {SHA}"),
            "another version": (0, f"rui 0.80.1 ({SHA})", False, [], 1, "not release 0.80.0 at"),
        }
        for case, (failures, reports, corrupt, waits, downloads, failure) in cases.items():
            with self.subTest(case=case):
                root, calls, bin_dir = self.fixture(case, failures, reports, corrupt)
                destination = root / "out"
                slept = []
                search = os.environ["PATH"]
                os.environ["PATH"] = f"{bin_dir}{os.pathsep}{search}"
                try:
                    path = release_under_test.fetch("7", "o/r", "linux-x86_64", VERSION, SHA, destination,
                                                    sleep=slept.append)
                    outcome = None
                except SystemExit as exit:
                    path, outcome = None, str(exit)
                finally:
                    os.environ["PATH"] = search
                self.assertEqual(slept, waits)
                self.assertEqual(calls.read_text().splitlines(),
                                 [f"run download 7 --repo o/r --name rui-linux-x86_64 --dir {destination}"] * downloads)
                if failure is None:
                    self.assertIsNone(outcome)
                    self.assertEqual(path, (destination / "rui-0.80.0-linux-x86_64/bin/rui").resolve())
                else:
                    self.assertIsNone(path)
                    self.assertIn(failure, outcome)

                # The command the workflows capture: stdout is the path alone, or empty with a non-zero exit.
                calls.unlink()
                script = (f"import sys; sys.argv[1:] = {[VERSION, SHA, str(root / 'command')]!r}; "
                          f"sys.path.insert(0, {str(SCRIPT.parent)!r}); import release_under_test as r; "
                          "r.RETRY_DELAYS = (0, 0); r.PLATFORMS = dict.fromkeys(r.PLATFORMS, 'linux-x86_64'); "
                          "sys.exit(r.main())")
                result = subprocess.run([sys.executable, "-B", "-c", script], capture_output=True, text=True,
                                        check=False, env={**os.environ, "PATH": f"{bin_dir}{os.pathsep}{search}",
                                                          "GITHUB_RUN_ID": "7", "GITHUB_REPOSITORY": "o/r"})
                self.assertIn("gh progress on stdout", result.stderr)
                if failure is None:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout,
                                     f"{(root / 'command/rui-0.80.0-linux-x86_64/bin/rui').resolve()}\n")
                    if failures:
                        self.assertIn("::warning::Artifact download failed; retrying in 0s", result.stderr)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
