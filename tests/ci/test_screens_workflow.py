"""Contract checks for the screen workflow's artifact and writer wiring."""
import json
import os
import pathlib
import re
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import unittest

WORKFLOW = pathlib.Path(__file__).resolve().parents[2] / '.github/workflows/screens.yml'


class ScreensWorkflowTest(unittest.TestCase):
    def test_build_is_transferred_once_and_all_four_shards_are_required(self):
        workflow = WORKFLOW.read_text()
        self.assertIn('matrix:\n        shard: [1, 2, 3, 4]', workflow)
        self.assertIn('pattern: screens-[1-4]-${{ github.run_id }}', workflow)
        self.assertIn('for number in 1 2 3 4; do', workflow)
        self.assertIn('test -f "$shard/head/shots.json"', workflow)
        self.assertIn('tar -cf "$RUNNER_TEMP/screens-build.tar"', workflow)
        self.assertIn('tar -xf "$RUNNER_TEMP/screens-build.tar"', workflow)
        self.assertIn("record['tree'] + '^{tree}'", workflow)

    def test_artifacts_are_shared_across_attempts_and_uploads_overwrite(self):
        workflow = WORKFLOW.read_text()
        self.assertNotIn('github.run_attempt', workflow)
        self.assertNotIn('GITHUB_RUN_ATTEMPT', workflow)
        uploaders = re.findall(r'(?ms)^      - uses: actions/upload-artifact@[^\n]*\n(.*?)(?=^      - |^  [a-z_]+:|\Z)', workflow)
        self.assertEqual(len(uploaders), 6)
        for upload in uploaders:
            self.assertRegex(upload, r'(?m)^          name: .+')
            self.assertRegex(upload, r'(?m)^          overwrite: true$')

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

    def test_capture_verdicts_reach_publication_for_candidate_and_baseline(self):
        workflow = WORKFLOW.read_text()
        merge = workflow.split('      - name: Merge captures\n', 1)[1].split('      - uses: actions/upload-artifact@', 1)[0]
        script = textwrap.dedent(merge.split('        run: |\n', 1)[1])
        repo = WORKFLOW.parents[2]
        for side in ('candidate', 'baseline'):
            for failure in ('none', 'record', 'run', 'exit'):
                for with_base in ((True, False) if side == 'candidate' else (True,)):
                    with self.subTest(side=side, failure=failure, with_base=with_base), tempfile.TemporaryDirectory() as tmp:
                        root = pathlib.Path(tmp)
                        for number in range(1, 5):
                            for kind in ('candidate', 'baseline'):
                                shard = (root / ('shards' if kind == 'candidate' else 'baseline-shards') /
                                         (f'screens-{number}-1' if kind == 'candidate' else f'screens-baseline-{number}-1'))
                                capture = shard / 'head' if kind == 'candidate' else shard
                                capture.mkdir(parents=True)
                                broken = kind == side and number == 1
                                record = {'name': f'screen-{number}', 'size': '80x24',
                                          'ok': not (broken and failure == 'record'),
                                          'reason': 'failed' if broken and failure == 'record' else None,
                                          'fingerprint': 'same', 'files': {}}
                                (capture / 'shots.json').write_text(json.dumps([record]))
                                (capture / 'shots-meta.json').write_text(json.dumps({'failed': broken and failure == 'run'}))
                                (shard / 'verdict').write_text('failure' if broken and failure == 'exit' else 'success')
                        output = root / 'outputs'
                        env = {**os.environ, 'RUNNER_TEMP': tmp, 'GITHUB_RUN_ID': '1',
                               'GITHUB_RUN_ATTEMPT': '2', 'GITHUB_OUTPUT': str(output),
                               'BASE': 'base' if with_base else '', 'BASELINE_MISSING': 'true'}
                        result = subprocess.run(['bash', '-c', script], cwd=repo, env=env, capture_output=True, text=True)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        verdicts = dict(line.split('=', 1) for line in output.read_text().splitlines())
                        self.assertEqual(verdicts['baseline_ok'], 'false' if side == 'baseline' and failure != 'none' else 'true')
                        candidate_failed = (side == 'candidate' and failure != 'none') or (side == 'baseline' and failure == 'record')
                        self.assertEqual(verdicts['candidate_ok'], 'false' if candidate_failed else 'true')
        publish = workflow.split('      - name: Publish screenshots and update comment', 1)[1].split('  cleanup:', 1)[0]
        self.assertIn('if [ "$BASELINE_OK" = true ]; then', publish)
        self.assertIn('if [ "$CANDIDATE_OK" = true ]; then', publish)
        self.assertIn('test "$CANDIDATE_OK" = true && test "$BASELINE_OK" = true', publish)
        self.assertNotIn("item['ok']", publish)
        self.assertNotIn("['failed']", publish.split('          PY_MEDIA', 1)[1])

    def test_cached_baseline_is_rechecked_by_merge_owner(self):
        workflow = WORKFLOW.read_text()
        merge = workflow.split('      - name: Merge captures\n', 1)[1].split('      - uses: actions/upload-artifact@', 1)[0]
        script = textwrap.dedent(merge.split('        run: |\n', 1)[1])
        for failed in (False, True):
            with self.subTest(failed=failed), tempfile.TemporaryDirectory() as tmp:
                root = pathlib.Path(tmp)
                record = {'name': 'screen', 'size': '80x24', 'ok': True, 'reason': None,
                          'fingerprint': 'same', 'files': {}}
                for number in range(1, 5):
                    shard = root / f'shards/screens-{number}-1'
                    (shard / 'head').mkdir(parents=True)
                    (shard / 'head/shots.json').write_text(json.dumps([record] if number == 1 else []))
                    (shard / 'head/shots-meta.json').write_text(json.dumps({'failed': False}))
                    (shard / 'verdict').write_text('success')
                cached = root / 'source/main/base'
                cached.mkdir(parents=True)
                (cached / 'shots.json').write_text(json.dumps([record]))
                (cached / 'shots-meta.json').write_text(json.dumps({'failed': failed}))
                with tarfile.open(root / 'cached-baseline.tar', 'w') as archive:
                    archive.add(cached, arcname='main/base')
                output = root / 'outputs'
                env = {**os.environ, 'RUNNER_TEMP': tmp, 'GITHUB_RUN_ID': '1', 'GITHUB_RUN_ATTEMPT': '2',
                       'GITHUB_OUTPUT': str(output), 'BASE': 'base', 'BASELINE_MISSING': 'false'}
                result = subprocess.run(['bash', '-c', script], cwd=WORKFLOW.parents[2], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                verdicts = dict(line.split('=', 1) for line in output.read_text().splitlines())
                self.assertEqual(verdicts, {'candidate_ok': 'true', 'baseline_ok': 'false' if failed else 'true'})

    def test_policy_actionlint_applies_only_workflow_specific_ignores(self):
        self.assertEqual(WORKFLOW.read_text().count('queue: max'), 2)
        policy = (WORKFLOW.parent / 'check.yml').read_text()
        step = policy.split('      - name: Validate workflows with pinned-linter compatibility exceptions\n', 1)[1].split('  linux_build:\n', 1)[0]
        script = textwrap.dedent(step.split('        run: |\n', 1)[1])
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            linter = root / 'actionlint'
            linter.write_text('#!' + sys.executable + '\nimport json, os, sys\nwith open(os.environ["LINT_LOG"], "a") as f: f.write(json.dumps(sys.argv[1:]) + "\\n")\n')
            linter.chmod(0o755)
            log = root / 'calls'
            env = {**os.environ, 'PATH': str(root) + os.pathsep + os.environ['PATH'], 'LINT_LOG': str(log)}
            subprocess.run(['bash', '-c', script], cwd=WORKFLOW.parents[2], env=env, check=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
        by_name = {pathlib.Path(call[-1]).name: call[1:-1] for call in calls}
        self.assertEqual(set(by_name), {path.name for path in WORKFLOW.parent.glob('*.yml')})
        cache = ['-ignore', r'^unexpected key "cache-mode" for "workflow" section\.']
        queue = ['-ignore', r'^unexpected key "queue" for "concurrency" section\.']
        for name, args in by_name.items():
            expected = (cache if name in ('qualify-macos.yml', 'previous-release-upgrade.yml', 'release.yml', 'screens.yml') else [])
            expected += queue if name == 'screens.yml' else []
            self.assertEqual(args, expected, name)

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
