import contextlib
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('screens_cleanup', Path(__file__).with_name('screens_cleanup.py'))
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)


def git(repo, *args):
    return subprocess.run(['git', '-C', str(repo), *args], check=True, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.strip()


def create_repos(tmp_path):
    origin = tmp_path / 'origin.git'
    subprocess.run(['git', 'init', '--bare', '-q', str(origin)], check=True)
    writer = tmp_path / 'writer'
    subprocess.run(['git', 'clone', '-q', str(origin), str(writer)], check=True)
    git(writer, 'config', 'user.name', 'Test')
    git(writer, 'config', 'user.email', 'test@example.com')
    git(writer, 'checkout', '-qb', 'pr-screens')
    (writer / 'pr-1').mkdir()
    (writer / 'pr-1' / 'capture').write_text('closed')
    git(writer, 'add', '.')
    git(writer, 'commit', '-qm', 'Initial captures')
    git(writer, 'push', '-q', 'origin', 'pr-screens')
    worker = tmp_path / 'worker'
    subprocess.run(['git', 'clone', '-q', '--no-checkout', str(origin), str(worker)], check=True,
                   stderr=subprocess.PIPE)
    return origin, writer, worker


def publish(writer, pr):
    git(writer, 'fetch', '-q', 'origin', 'pr-screens')
    git(writer, 'reset', '--hard', '-q', 'FETCH_HEAD')
    directory = writer / f'pr-{pr}'
    directory.mkdir(exist_ok=True)
    (directory / 'capture').write_text(f'published {pr}')
    git(writer, 'add', '.')
    git(writer, 'commit', '-qm', f'Publish {pr}')
    git(writer, 'push', '-q', 'origin', 'HEAD:pr-screens')


def paths(origin):
    return git(origin, 'ls-tree', '-r', '--name-only', 'refs/heads/pr-screens').splitlines()


class ScreensCleanupTest(unittest.TestCase):
    def _cleanup_keeps_open_and_removes_closed_and_legacy(self, repos):
        origin, writer, _ = repos
        publish(writer, 2)
        (writer / 'main').mkdir()
        (writer / 'main' / 'capture').write_text('legacy')
        (writer / 'stray').write_text('legacy')
        (writer / 'pr-3').write_text('not a directory')
        git(writer, 'add', '.')
        git(writer, 'commit', '-qm', 'Legacy files')
        git(writer, 'push', '-q', 'origin', 'HEAD:pr-screens')
        cleanup.cleanup(lambda pr: 'closed' if pr == 1 else 'open')
        self.assertEqual(paths(origin), ['pr-2/capture'])
        original = git(origin, 'rev-parse', 'refs/heads/pr-screens')
        cleanup.cleanup(lambda pr: 'open')
        self.assertEqual(git(origin, 'rev-parse', 'refs/heads/pr-screens'), original)

    def _cleanup_removes_late_publication_on_next_sweep(self, repos):
        origin, writer, _ = repos
        cleanup.cleanup(lambda pr: 'closed')
        publish(writer, 1)
        cleanup.cleanup(lambda pr: 'closed')
        self.assertEqual(paths(origin), [])

    def _cleanup_recomputes_after_concurrent_publication(self, repos, state, expected):
        origin, writer, _ = repos
        cleanup.cleanup(lambda pr: 'closed' if pr == 1 else state,
                        before_push=lambda attempt: publish(writer, 2) if attempt == 0 else None)
        self.assertEqual(paths(origin), expected)

    def _retries_are_bounded_and_preserve_each_publication(self, repos):
        origin, writer, _ = repos
        attempts = []
        def race(attempt):
            attempts.append(attempt)
            publish(writer, attempt + 2)
        with self.assertRaisesRegex(RuntimeError, 'after 5 attempts'):
            cleanup.cleanup(lambda pr: 'closed' if pr == 1 else 'open', before_push=race)
        self.assertEqual(attempts, list(range(5)))
        self.assertEqual(paths(origin), [f'pr-{pr}/capture' for pr in range(1, 7)])

    def _concurrent_cleanup_on_last_attempt_is_success(self, repos):
        origin, writer, _ = repos
        def race(attempt):
            if attempt < 4:
                publish(writer, attempt + 2)
            else:
                git(writer, 'fetch', '-q', 'origin', 'pr-screens')
                git(writer, 'reset', '--hard', '-q', 'FETCH_HEAD')
                git(writer, 'rm', '-qr', 'pr-1')
                git(writer, 'commit', '-qm', 'Other cleanup')
                git(writer, 'push', '-q', 'origin', 'HEAD:pr-screens')
        cleanup.cleanup(lambda pr: 'closed' if pr == 1 else 'open', before_push=race)
        self.assertEqual(paths(origin), [f'pr-{pr}/capture' for pr in range(2, 6)])

    def _push_failure_without_tip_change_fails(self, repos):
        origin, _, _ = repos
        hook = origin / 'hooks' / 'pre-receive'
        hook.write_text('#!/bin/sh\nexit 1\n')
        os.chmod(hook, 0o755)
        with self.assertRaisesRegex(RuntimeError, 'without a changed remote tip'):
            cleanup.cleanup(lambda pr: 'closed')
        self.assertEqual(paths(origin), ['pr-1/capture'])

    def _absent_branch_is_noop(self, repos):
        origin, _, _ = repos
        git(origin, 'update-ref', '-d', 'refs/heads/pr-screens')
        cleanup.cleanup(lambda pr: 'closed')
        self.assertIsNone(cleanup.tip())

    def _state_lookup_failure_leaves_branch_unchanged(self, repos):
        origin, _, _ = repos
        original = git(origin, 'rev-parse', 'refs/heads/pr-screens')
        def fail(pr):
            raise RuntimeError('API unavailable')
        with self.assertRaisesRegex(RuntimeError, 'API unavailable'):
            cleanup.cleanup(fail)
        self.assertEqual(git(origin, 'rev-parse', 'refs/heads/pr-screens'), original)

    def test_cleanup_sweep_preserves_open_prs_scr_5(self):
        # SCR-5: sweep only closed PR and legacy entries, including races and failures.
        cases = [
            (self._cleanup_keeps_open_and_removes_closed_and_legacy, ()),
            (self._cleanup_removes_late_publication_on_next_sweep, ()),
            (self._cleanup_recomputes_after_concurrent_publication, ('open', ['pr-2/capture'])),
            (self._cleanup_recomputes_after_concurrent_publication, ('closed', [])),
            (self._retries_are_bounded_and_preserve_each_publication, ()),
            (self._concurrent_cleanup_on_last_attempt_is_success, ()),
            (self._push_failure_without_tip_change_fails, ()),
            (self._absent_branch_is_noop, ()),
            (self._state_lookup_failure_leaves_branch_unchanged, ()),
        ]
        for case, args in cases:
            with self.subTest(case=case.__name__, args=args), tempfile.TemporaryDirectory() as tmp:
                repos = create_repos(Path(tmp))
                with contextlib.chdir(repos[2]):
                    case(repos, *args)

    def test_pr_state_reads_rest_and_rejects_unknown_state(self):
        calls = []
        def api(args, text):
            calls.append(args)
            return '{"state": "closed"}'
        with patch.dict(os.environ, GITHUB_REPOSITORY='owner/repo'):
            with patch.object(subprocess, 'check_output', side_effect=api):
                self.assertEqual(cleanup.pr_state(42), 'closed')
            self.assertEqual(calls, [['gh', 'api', 'repos/owner/repo/pulls/42']])
            with patch.object(subprocess, 'check_output', return_value='{"state": "unknown"}'):
                with self.assertRaisesRegex(ValueError, 'unexpected state'):
                    cleanup.pr_state(42)

    def test_cleanup_workflow_runs_on_close_and_every_dispatch(self):
        workflow = (Path(__file__).resolve().parents[2] / '.github/workflows/screens-comment.yml').read_text()
        triggers, jobs = workflow.split('\njobs:', 1)
        self.assertIn('  workflow_dispatch:', triggers)
        self.assertIn('  pull_request_target:\n    types: [closed]', triggers)
        self.assertNotIn('  schedule:', triggers)
        cleanup_job = jobs.split('\n  cleanup:', 1)[1]
        self.assertIn("    if: ${{ github.event_name == 'pull_request_target' || github.event_name == 'workflow_dispatch' }}", cleanup_job)
