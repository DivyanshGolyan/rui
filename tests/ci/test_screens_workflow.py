"""Contract checks for the screen workflow's artifact and writer wiring."""
import json
import pathlib
import subprocess
import sys
import tempfile
import textwrap
import unittest

WORKFLOW = pathlib.Path(__file__).resolve().parents[2] / '.github/workflows/screens.yml'


class ScreensWorkflowTest(unittest.TestCase):
    def test_build_is_transferred_once_and_all_four_shards_are_required(self):
        workflow = WORKFLOW.read_text()
        self.assertIn('matrix:\n        shard: [1, 2, 3, 4]', workflow)
        self.assertIn('pattern: screens-[1-4]-${{ github.run_id }}-${{ github.run_attempt }}', workflow)
        self.assertIn('for number in 1 2 3 4; do', workflow)
        self.assertIn('test -f "$shard/head/shots.json"', workflow)
        self.assertIn('tar -cf "$RUNNER_TEMP/screens-build.tar"', workflow)
        self.assertIn('tar -xf "$RUNNER_TEMP/screens-build.tar"', workflow)
        self.assertIn("record['tree'] + '^{tree}'", workflow)

    def test_build_manifests_round_trip_through_cache_for_both_shards(self):
        workflow = WORKFLOW.read_text()
        root = WORKFLOW.parents[2]
        tree = subprocess.check_output(['git', 'rev-parse', 'HEAD^{tree}'], cwd=root, text=True).strip()
        for label in ('candidate', 'baseline'):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as tmp:
                job = workflow.split('      - name: Restore ' + ('candidate build' if label == 'candidate' else 'base build and source'), 1)[1]
                script = textwrap.dedent(job.split("<<'PY_MANIFEST'\n", 1)[1].split('          PY_MANIFEST', 1)[0])
                cache_root = pathlib.Path(tmp)
                build_id = 'tree-' + 'a' * 64
                build_dir = cache_root / 'cache/builds' / build_id
                build_dir.mkdir(parents=True)
                for name in ('rui', 'screen.so'):
                    (build_dir / name).write_text('artifact')
                record = {'sha': build_id, 'tree': tree, 'source': str(root),
                          'binary': str(build_dir / 'rui'), 'screen_library': str(build_dir / 'screen.so')}
                printed = cache_root / 'build.json'
                manifest = build_dir / 'manifest.json'
                printed.write_text(json.dumps(record))
                manifest.write_text(json.dumps(record))
                args = [sys.executable, '-c', script, str(cache_root)]
                if label == 'baseline':
                    args.append(str(root))
                self.assertEqual(subprocess.run(args, capture_output=True).returncode, 0)
                manifest.unlink()
                self.assertNotEqual(subprocess.run(args, capture_output=True).returncode, 0)
                record['sha'] = '../escape'
                printed.write_text(json.dumps(record))
                self.assertNotEqual(subprocess.run(args, capture_output=True).returncode, 0)
        self.assertEqual(workflow.count('"$V" build --here >'), 2)
        self.assertEqual(workflow.count('"$V" shots "$build_id" --shard'), 2)
        self.assertNotIn('build --here --out', workflow)
        for cache in ('screens-build', 'screens-baseline-build'):
            self.assertEqual(workflow.count('export VERIFY_RUI_CACHE="$RUNNER_TEMP/' + cache + '/cache"'), 2)

    def test_write_jobs_are_serialized_and_publisher_uses_default_branch(self):
        workflow = WORKFLOW.read_text()
        publish = workflow.split('  screens:\n', 1)[1].split('  cleanup:\n', 1)[0]
        cleanup = workflow.split('  cleanup:\n', 1)[1]
        self.assertIn('group: pr-screens-writer', publish)
        self.assertIn('group: pr-screens-writer', cleanup)
        self.assertIn("jq -e '.state == \"closed\"'", cleanup)
        self.assertIn('ref: ${{ github.event.repository.default_branch }}', publish)
        self.assertIn('git merge-base "$HEAD_SHA" "$current_base"', publish)
        self.assertIn('Screen preview wall time:', publish)
        self.assertIn('git rev-list "origin/$DEFAULT_BRANCH"', publish)

    def test_baseline_runs_on_trusted_jobs_and_branch_errors_fail_closed(self):
        workflow = WORKFLOW.read_text()
        self.assertIn('  pull_request:', workflow)
        self.assertNotIn('  pull_request_target:', workflow)
        self.assertIn('select_tests.ROOT = candidate', workflow)
        baseline = workflow.split('  baseline_probe:\n', 1)[1].split('  capture:\n', 1)[0]
        self.assertEqual(baseline.count('ref: ${{ github.event.repository.default_branch }}'), 3)
        self.assertIn('git merge-base --is-ancestor "$BASE"', baseline)
        self.assertIn('git archive origin/pr-screens "main/$BASE" >', baseline)
        self.assertIn('screens-baseline-cached-', workflow)
        self.assertIn("record['tree'] != tree", baseline)
        self.assertIn('needs.baseline_capture.result == \'success\'', workflow)
        self.assertEqual(workflow.count('remote=$(git ls-remote --refs origin refs/heads/pr-screens)'), 3)
        self.assertEqual(workflow.count('push --force-with-lease='), 2)
        self.assertNotIn('if ! git fetch --no-tags origin refs/heads/pr-screens', workflow)

    def test_linter_exception_is_scoped_to_screen_workflow_and_queue(self):
        check = (WORKFLOW.parent / 'check.yml').read_text()
        self.assertIn('elif [ "$workflow" = .github/workflows/screens.yml ]; then', check)
        self.assertIn('unexpected key "queue" for "concurrency" section', check)
        workflow = WORKFLOW.read_text()
        self.assertEqual(workflow.count('queue: max'), 2)

    def test_publisher_includes_other_sizes_for_changed_states_only(self):
        workflow = WORKFLOW.read_text()
        start = workflow.index('          import json, pathlib, shutil, sys\n', workflow.index("<<'PY_MEDIA'"))
        end = workflow.index('          PY_MEDIA\n', start)
        program = textwrap.dedent(workflow[start:end])
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            source, target = root / 'merged', root / 'published'
            (source / 'baseline').mkdir(parents=True)
            target.mkdir()
            def record(name, size, path):
                return {'name': name, 'size': size, 'files': {'png': path}}
            changed = record('changed', '140x40', 'changed-large.png')
            companion = record('changed', '46x30', 'changed-small.png')
            unrelated = record('same', '46x30', 'unrelated.png')
            old_large = record('changed', '140x40', 'old-large.png')
            old_small = record('changed', '46x30', 'old-small.png')
            old_unrelated = record('same', '46x30', 'old-unrelated.png')
            (source / 'shots.json').write_text(json.dumps([changed, companion, unrelated]))
            baseline = root / 'baseline.json'
            baseline.write_text(json.dumps([old_large, old_small, old_unrelated]))
            before = record('changed', '140x40', 'baseline/old-large.png')
            (source / 'diff.json').write_text(json.dumps({'failed': [], 'new': [], 'changed': [
                {'name': 'changed', 'before': before, 'after': changed}]}))
            for item in [changed, companion, unrelated]:
                (source / item['files']['png']).write_bytes(b'image')
            for item in [old_large, old_small, old_unrelated]:
                (source / 'baseline' / item['files']['png']).write_bytes(b'image')
            subprocess.run([sys.executable, '-c', program, str(source), str(target), str(baseline)], check=True)
            self.assertEqual({p.relative_to(target).as_posix() for p in target.rglob('*.png')},
                             {'changed-large.png', 'changed-small.png', 'baseline/old-large.png', 'baseline/old-small.png'})
            self.assertIn('--shots "$RUNNER_TEMP/merged/shots.json" --baseline-shots "$RUNNER_TEMP/baseline/shots.json"', workflow)

    def test_retention_keeps_new_fallback_in_twenty_slots(self):
        workflow = WORKFLOW.read_text()
        start = workflow.index("          import pathlib, shutil, sys\n", workflow.index('pin=""'))
        end = workflow.index('          PY\n', start)
        program = textwrap.dedent(workflow[start:end])
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary) / 'main'
            root.mkdir()
            names = [f'{index:040x}' for index in range(25)]
            history = pathlib.Path(temporary) / 'history'
            history.write_text('\n'.join(names) + '\n')
            for name in names:
                (root / name).mkdir()
            subprocess.run([sys.executable, '-c', program, str(root), str(history), names[-1]], check=True)
            retained = {path.name for path in root.iterdir()}
            self.assertEqual(retained, set(names[:19] + [names[-1]]))


if __name__ == '__main__':
    unittest.main()
