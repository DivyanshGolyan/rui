import importlib.util
import os
from pathlib import Path
import subprocess

import pytest

spec = importlib.util.spec_from_file_location('screens_cleanup', Path(__file__).with_name('screens_cleanup.py'))
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)


def git(repo, *args):
    return subprocess.run(['git', '-C', str(repo), *args], check=True, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.strip()


@pytest.fixture
def repos(tmp_path, monkeypatch):
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
    monkeypatch.chdir(worker)
    return origin, writer


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


def test_cleanup_keeps_open_and_removes_closed_and_legacy(repos):
    origin, writer = repos
    publish(writer, 2)
    (writer / 'main').mkdir()
    (writer / 'main' / 'capture').write_text('legacy')
    (writer / 'stray').write_text('legacy')
    (writer / 'pr-3').write_text('not a directory')
    git(writer, 'add', '.')
    git(writer, 'commit', '-qm', 'Legacy files')
    git(writer, 'push', '-q', 'origin', 'HEAD:pr-screens')
    cleanup.cleanup(lambda pr: 'closed' if pr == 1 else 'open')
    assert paths(origin) == ['pr-2/capture']
    original = git(origin, 'rev-parse', 'refs/heads/pr-screens')
    cleanup.cleanup(lambda pr: 'open')
    assert git(origin, 'rev-parse', 'refs/heads/pr-screens') == original


def test_cleanup_removes_late_publication_on_next_sweep(repos):
    origin, writer = repos
    cleanup.cleanup(lambda pr: 'closed')
    publish(writer, 1)
    cleanup.cleanup(lambda pr: 'closed')
    assert paths(origin) == []


@pytest.mark.parametrize('state,expected', [('open', ['pr-2/capture']), ('closed', [])])
def test_cleanup_recomputes_after_concurrent_publication(repos, state, expected):
    origin, writer = repos
    cleanup.cleanup(lambda pr: 'closed' if pr == 1 else state,
                    before_push=lambda attempt: publish(writer, 2) if attempt == 0 else None)
    assert paths(origin) == expected


def test_retries_are_bounded_and_preserve_each_publication(repos):
    origin, writer = repos
    attempts = []
    def race(attempt):
        attempts.append(attempt)
        publish(writer, attempt + 2)
    with pytest.raises(RuntimeError, match='after 5 attempts'):
        cleanup.cleanup(lambda pr: 'closed' if pr == 1 else 'open', before_push=race)
    assert attempts == list(range(5))
    assert paths(origin) == [f'pr-{pr}/capture' for pr in range(1, 7)]


def test_concurrent_cleanup_on_last_attempt_is_success(repos):
    origin, writer = repos
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
    assert paths(origin) == [f'pr-{pr}/capture' for pr in range(2, 6)]


def test_push_failure_without_tip_change_fails(repos):
    origin, _ = repos
    hook = origin / 'hooks' / 'pre-receive'
    hook.write_text('#!/bin/sh\nexit 1\n')
    os.chmod(hook, 0o755)
    with pytest.raises(RuntimeError, match='without a changed remote tip'):
        cleanup.cleanup(lambda pr: 'closed')
    assert paths(origin) == ['pr-1/capture']


def test_absent_branch_is_noop(repos):
    origin, _ = repos
    git(origin, 'update-ref', '-d', 'refs/heads/pr-screens')
    cleanup.cleanup(lambda pr: 'closed')
    assert cleanup.tip() is None


def test_state_lookup_failure_leaves_branch_unchanged(repos):
    origin, _ = repos
    original = git(origin, 'rev-parse', 'refs/heads/pr-screens')
    def fail(pr):
        raise RuntimeError('API unavailable')
    with pytest.raises(RuntimeError, match='API unavailable'):
        cleanup.cleanup(fail)
    assert git(origin, 'rev-parse', 'refs/heads/pr-screens') == original


def test_pr_state_reads_rest_and_rejects_unknown_state(monkeypatch):
    monkeypatch.setenv('GITHUB_REPOSITORY', 'owner/repo')
    calls = []
    def api(args, text):
        calls.append(args)
        return '{"state": "closed"}'
    monkeypatch.setattr(subprocess, 'check_output', api)
    assert cleanup.pr_state(42) == 'closed'
    assert calls == [['gh', 'api', 'repos/owner/repo/pulls/42']]
    monkeypatch.setattr(subprocess, 'check_output', lambda *args, **kwargs: '{"state": "unknown"}')
    with pytest.raises(ValueError, match='unexpected state'):
        cleanup.pr_state(42)
