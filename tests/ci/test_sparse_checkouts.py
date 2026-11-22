"""A CI script imports in the sparse checkout its workflow step gives it.

Each step that runs `python3 tests/ci/<script>.py` after an `actions/checkout`
with `sparse-checkout:` gets only those paths. The script is imported there, in
a fresh process with tests/ci first on the path, so an import-time read of a
path outside the sparse set fails here, not in the run. The script is imported,
never run, so its `__main__` block does not execute.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github/workflows"
JOB = re.compile(r"^  ([A-Za-z_][\w-]*):\s*$")
STEP = re.compile(r"^      - ")
SPARSE = re.compile(r"^[ \t]+sparse-checkout: (\S.*?)[ \t]*$", re.M)
CONE = re.compile(r"^[ \t]+sparse-checkout-cone-mode: (\S+)[ \t]*$", re.M)
CHECKOUT = re.compile(r"uses: actions/checkout@\S+")
SCRIPT = re.compile(r"python3?\S*[ \t]+(?:-\w+[ \t]+)*\"?(tests/ci/[\w./-]+\.py)")
PROBE = """\
import importlib.util, sys
path, directory = sys.argv[1], sys.argv[2]
sys.path.insert(0, directory)
name = path.rsplit("/", 1)[-1][:-3]
spec = importlib.util.spec_from_file_location(name, path)
module = importlib.util.module_from_spec(spec)
sys.modules[name] = module
spec.loader.exec_module(module)
"""


def steps_of(text):
    """Return (job, lines) for each step of each job, in order, from the block YAML the workflows use."""
    steps, job, step = [], None, None
    for line in text.split("\njobs:\n", 1)[1].splitlines():
        if match := JOB.match(line):
            job, step = match[1], None
            continue
        if STEP.match(line):
            step = [line]
            steps.append((job, step))
        elif line.strip() and not line.startswith(" " * 6):
            step = None
        elif step is not None:
            step.append(line)
    return steps


def sparse_script_runs():
    """Return (workflow, job, script, sparse paths, cone mode) for each script a step runs after a sparse checkout."""
    runs = []
    for path in sorted(WORKFLOWS.glob("*.yml")):
        checkout = None
        for job, lines in steps_of(path.read_text()):
            text = "\n".join(lines)
            if CHECKOUT.search(text):
                checkout = None
                if sparse := SPARSE.search(text):
                    cone = CONE.search(text)
                    checkout = (sparse[1].split(), not (cone and cone[1] == "false"))
                continue
            if checkout is None:
                continue
            for script in dict.fromkeys(SCRIPT.findall(text)):
                runs.append((path.name, job, script, *checkout))
    return runs


def sparse_tree(destination, paths, cone):
    """Copy what the sparse checkout holds: the named paths, plus in cone mode the repository's top-level files."""
    if cone:
        for entry in ROOT.iterdir():
            if entry.is_file():
                shutil.copy2(entry, destination / entry.name)
    for path in paths:
        source, target = ROOT / path, destination / path
        if source.is_dir():
            shutil.copytree(source, target, dirs_exist_ok=True, ignore=shutil.ignore_patterns("__pycache__"))
        elif source.is_file():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)


class SparseCheckoutImportTest(unittest.TestCase):
    def test_each_script_a_sparse_step_runs_imports_in_its_sparse_checkout(self):
        runs = sparse_script_runs()
        found = {(workflow, job, Path(script).name) for workflow, job, script, _, _ in runs}
        # The parser must see the steps this policy is about, or it checks nothing.
        self.assertIn(("infra-retry.yml", "retry", "failure_cause.py"), found)
        self.assertIn(("check.yml", "linux", "failure_cause.py"), found)
        self.assertIn(("screens-comment.yml", "comment", "screens_comment.py"), found)
        for workflow, job, script, paths, cone in runs:
            with self.subTest(workflow=workflow, job=job, script=script):
                with tempfile.TemporaryDirectory() as directory:
                    tree = Path(directory)
                    sparse_tree(tree, paths, cone)
                    self.assertTrue((tree / script).is_file(), f"{script} is not in the sparse checkout {paths}")
                    probe = subprocess.run([sys.executable, "-I", "-B", "-c", PROBE, str(tree / script), str(tree / "tests/ci")],
                                           cwd=tree, capture_output=True, text=True, timeout=300)
                    self.assertEqual(probe.returncode, 0, "\n".join(probe.stderr.strip().splitlines()[-4:]))


if __name__ == "__main__":
    unittest.main()
