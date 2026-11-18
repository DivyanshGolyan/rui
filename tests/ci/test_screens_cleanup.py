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


@pytest.mark.parametrize('order', ['before', 'during', 'after'])
def test_cleanup_preserves_publication_in_every_order(repos, order):
    origin, writer = repos
    if order == 'before':
        publish(writer, 2)
    cleanup.cleanup(1, before_push=(lambda attempt: publish(writer, 2) if attempt == 0 else None)
                    if order == 'during' else None)
    if order == 'after':
        publish(writer, 2)
    assert paths(origin) == ['pr-2/capture']


def test_retries_are_bounded_and_preserve_each_publication(repos):
    origin, writer = repos
    attempts = []
    def race(attempt):
        attempts.append(attempt)
        publish(writer, attempt + 2)
    with pytest.raises(RuntimeError, match='after 5 attempts'):
        cleanup.cleanup(1, before_push=race)
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
    cleanup.cleanup(1, before_push=race)
    assert paths(origin) == [f'pr-{pr}/capture' for pr in range(2, 6)]


def test_absent_folder_is_noop(repos):
    origin, _ = repos
    original = git(origin, 'rev-parse', 'refs/heads/pr-screens')
    cleanup.cleanup(3)
    assert git(origin, 'rev-parse', 'refs/heads/pr-screens') == original


def test_push_failure_without_tip_change_fails(repos):
    origin, _ = repos
    hook = origin / 'hooks' / 'pre-receive'
    hook.write_text('#!/bin/sh\nexit 1\n')
    os.chmod(hook, 0o755)
    with pytest.raises(RuntimeError, match='without a changed remote tip'):
        cleanup.cleanup(1)
    assert paths(origin) == ['pr-1/capture']


def test_absent_branch_is_noop(repos):
    origin, _ = repos
    git(origin, 'update-ref', '-d', 'refs/heads/pr-screens')
    cleanup.cleanup(1)
    assert cleanup.tip() is None


@pytest.mark.parametrize('pr', ['0', '-1', '../2', '1/other', '01', ''])
def test_invalid_pr_is_rejected(repos, pr):
    with pytest.raises(ValueError, match='invalid pull request'):
        cleanup.cleanup(pr)
