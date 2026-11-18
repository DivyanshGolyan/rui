#!/usr/bin/env python3
"""Sweep closed PR captures and retired entries from the screens branch."""
import argparse
import json
import os
import re
import subprocess
import tempfile

REF = 'refs/heads/pr-screens'


def git(*args, env=None, check=True):
    return subprocess.run(['git', *args], env=env, check=check, stdout=subprocess.PIPE,
                          text=True).stdout.strip()


def tip():
    remote = git('ls-remote', '--refs', 'origin', REF)
    return remote.split()[0] if remote else None


def pr_state(pr):
    repository = os.environ['GITHUB_REPOSITORY']
    result = subprocess.check_output(['gh', 'api', f'repos/{repository}/pulls/{pr}'], text=True)
    state = json.loads(result)['state']
    if state not in ('open', 'closed'):
        raise ValueError(f'unexpected state for PR #{pr}: {state}')
    return state


def removable(sha, state_for_pr):
    entries = subprocess.check_output(['git', 'ls-tree', '-z', sha]).split(b'\0')
    paths = []
    for entry in filter(None, entries):
        metadata, name = entry.split(b'\t', 1)
        path = os.fsdecode(name)
        match = re.fullmatch(r'pr-([1-9][0-9]*)', path)
        if metadata.split()[1] != b'tree' or not match:
            paths.append(path)
        elif state_for_pr(int(match.group(1))) == 'closed':
            paths.append(path)
    return paths


def cleanup(state_for_pr=pr_state, before_push=None):
    env = os.environ.copy()
    env.update(GIT_AUTHOR_NAME='github-actions[bot]',
               GIT_AUTHOR_EMAIL='41898282+github-actions[bot]@users.noreply.github.com',
               GIT_COMMITTER_NAME='github-actions[bot]',
               GIT_COMMITTER_EMAIL='41898282+github-actions[bot]@users.noreply.github.com')
    with tempfile.TemporaryDirectory() as temporary:
        env['GIT_INDEX_FILE'] = os.path.join(temporary, 'index')
        for attempt in range(5):
            sha = tip()
            if sha is None:
                return
            git('fetch', '--no-tags', 'origin', sha)
            paths = removable(sha, state_for_pr)
            if not paths:
                return
            git('read-tree', sha, env=env)
            git('rm', '-r', '-f', '--cached', '--ignore-unmatch', '--', *(f':(literal){path}' for path in paths), env=env)
            tree = git('write-tree', env=env)
            commit = git('commit-tree', tree, '-m', 'Remove closed PR screen captures', env=env)
            if before_push:
                before_push(attempt)
            result = subprocess.run(['git', 'push', f'--force-with-lease={REF}:{sha}',
                                     'origin', f'{commit}:{REF}'])
            if result.returncode == 0:
                return
            latest = tip()
            if latest == sha:
                raise RuntimeError('cleanup push failed without a changed remote tip')
        if latest is None:
            return
        git('fetch', '--no-tags', 'origin', latest)
        if not removable(latest, state_for_pr):
            return
        raise RuntimeError('cleanup could not update pr-screens after 5 attempts')


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    cleanup()


if __name__ == '__main__':
    main()
