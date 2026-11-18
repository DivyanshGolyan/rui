#!/usr/bin/env python3
"""Remove a closed PR's captures without overwriting concurrent publications."""
import argparse
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


def cleanup(pr, before_push=None):
    if not re.fullmatch(r'[1-9][0-9]*', str(pr)):
        raise ValueError('invalid pull request number')
    path = f'pr-{pr}'
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
            if not git('ls-tree', sha, '--', path):
                return
            git('read-tree', sha, env=env)
            git('rm', '-r', '-f', '--cached', '--ignore-unmatch', '--', path, env=env)
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
        # A concurrent cleanup may have removed the folder on the final attempt.
        if latest is None:
            return
        git('fetch', '--no-tags', 'origin', latest)
        if not git('ls-tree', latest, '--', path):
            return
        raise RuntimeError('cleanup could not update pr-screens after 5 attempts')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pr')
    cleanup(parser.parse_args().pr)


if __name__ == '__main__':
    main()
