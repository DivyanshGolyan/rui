"""The main build's crossing-PR range and its one issue's lifecycle, without GitHub."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import main_build
from main_build import MARKER, Commit, crossing, decide, render
from report_issue import LABEL


class Repo:
    def __enter__(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.path = Path(self.scratch.name)
        self.git('init', '-q', '-b', 'main')
        return self

    def __exit__(self, *args):
        self.scratch.cleanup()

    def git(self, *args):
        return subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@t', *args], cwd=self.path,
                              check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, subject):
        self.git('commit', '-q', '--allow-empty', '-m', subject)
        return self.git('rev-parse', 'HEAD')


class CrossingTest(unittest.TestCase):
    def test_names_each_squash_merge_after_the_last_green_build_oldest_first(self):
        with Repo() as repo:
            repo.commit('Older work (#1)')
            green = repo.commit('Green main (#2)')
            first = repo.commit('Sessions list loses its input (#1379)')
            direct = repo.commit('A commit without a PR number')
            head = repo.commit('Fix (#12) the screen test (#1403)')
            commits, known = crossing(green, head, cwd=repo.path)
            self.assertTrue(known)
            self.assertEqual(commits, [Commit(first, 'Sessions list loses its input (#1379)', 1379),
                                       Commit(direct, 'A commit without a PR number', None),
                                       Commit(head, 'Fix (#12) the screen test (#1403)', 1403)])

    def test_names_merges_not_their_branch_commits(self):
        with Repo() as repo:
            green = repo.commit('Green main (#2)')
            repo.git('checkout', '-q', '-b', 'side')
            repo.commit('Side work (#7)')
            repo.git('checkout', '-q', 'main')
            repo.git('merge', '-q', '--no-ff', '-m', 'Merge side (#8)', 'side')
            head = repo.git('rev-parse', 'HEAD')
            commits, known = crossing(green, head, cwd=repo.path)
            self.assertTrue(known)
            self.assertEqual([commit.pr for commit in commits], [8])

    def test_green_at_head_names_nothing(self):
        with Repo() as repo:
            head = repo.commit('Green main (#2)')
            self.assertEqual(crossing(head, head, cwd=repo.path), ([], True))

    def test_without_a_green_ancestor_names_only_head(self):
        with Repo() as repo:
            base = repo.commit('Base (#1)')
            repo.git('checkout', '-q', '-b', 'other')
            elsewhere = repo.commit('Off main (#5)')
            repo.git('checkout', '-q', 'main')
            repo.commit('Middle (#3)')
            head = repo.commit('Head (#4)')
            for green in (None, elsewhere, '0' * 40):
                with self.subTest(green=green):
                    commits, known = crossing(green, head, cwd=repo.path)
                    self.assertFalse(known)
                    self.assertEqual([(commit.sha, commit.pr) for commit in commits], [(head, 4)])
            self.assertTrue(crossing(base, head, cwd=repo.path)[1])


class DecideTest(unittest.TestCase):
    def test_every_result_and_issue_state(self):
        expected = {('failure', None): 'create', ('failure', 41): 'update',
                    ('success', None): 'none', ('success', 41): 'close'}
        for (result, issue), action in expected.items():
            with self.subTest(result=result, issue=issue):
                self.assertEqual(decide(result, issue), action)
        # A cancelled or skipped build is superseded or never ran; it says nothing about main.
        for result in ('cancelled', 'skipped', '', 'timed_out'):
            for issue in (None, 41):
                with self.subTest(result=result, issue=issue), self.assertRaises(ValueError):
                    decide(result, issue)


class RenderTest(unittest.TestCase):
    def test_body_names_each_pr_and_the_fast_fix_without_mentions(self):
        commits = [Commit('a' * 40, 'Ping @someone in a title (#1379)', 1379), Commit('b' * 40, 'Direct', None)]
        body = render('o/r', commits, True, 'c' * 40, 'd' * 40, 'https://run', [('build / linux_build', 'https://job')])
        self.assertIn('since the last green main build `' + 'c' * 40 + '`', body)
        self.assertIn('- #1379 Ping @\u200bsomeone in a title (#1379)', body)
        self.assertIn('- `' + 'b' * 12 + '` Direct', body)
        self.assertIn('- [build / linux_build](https://job)', body)
        self.assertIn('reverting the later one is the fast fix', body)
        self.assertIn('https://github.com/o/r/blob/main/docs/agents/landing.md#ci-failures', body)
        self.assertTrue(body.endswith(MARKER))
        unknown = render('o/r', commits[:1], False, None, 'd' * 40, 'https://run', [])
        self.assertIn('No green main build precedes it', unknown)
        self.assertNotIn('Failed jobs', unknown)


class FakeGitHub:
    """`gh` for one repository: open main-build issues, the last green run and the writes."""

    def __init__(self, issues=(), green='c' * 40):
        self.issues = list(issues)
        self.green = green
        self.writes = []

    def __call__(self, *args):
        if args[:2] == ('issue', 'list'):
            assert ('--label', LABEL) == args[args.index('--label'):args.index('--label') + 2]
            return json.dumps(self.issues)
        if args[0] == 'api':
            assert '/actions/workflows/main-build.yml/runs?branch=main&status=success' in args[1]
            return json.dumps({'workflow_runs': [{'head_sha': self.green}] if self.green else []})
        self.writes.append(args)
        return 'https://github.com/o/r/issues/50\n' if args[:2] == ('issue', 'create') else ''


class MainTest(unittest.TestCase):
    commits = [Commit('a' * 40, 'Sessions list (#1379)', 1379), Commit('b' * 40, 'Screen test (#1403)', 1403)]

    def run_main(self, result, fake):
        jobs = [{'name': 'build / linux_build', 'html_url': 'https://job', 'conclusion': 'failure'},
                {'name': 'report', 'html_url': 'https://report', 'conclusion': None}]
        argv = ['main_build.py', '--run-id', '7', '--sha', 'd' * 40, '--result', result]
        with patch.object(main_build, 'gh', fake), patch.object(main_build, 'run_jobs', return_value=jobs), \
                patch.object(main_build, 'crossing', return_value=(self.commits, True)) as ranged, \
                patch('sys.argv', argv), patch.dict('os.environ', GITHUB_REPOSITORY='o/r'), \
                patch('builtins.print'):
            main_build.main()
        return ranged

    def test_first_red_build_opens_one_ci_red_issue(self):
        fake = FakeGitHub(issues=[{'number': 9, 'body': 'A signature issue, not this one'}])
        ranged = self.run_main('failure', fake)
        ranged.assert_called_once_with('c' * 40, 'd' * 40)
        [create] = fake.writes
        self.assertEqual(create[:2], ('issue', 'create'))
        self.assertEqual(create[create.index('--label') + 1], LABEL)
        body = create[create.index('--body') + 1]
        self.assertIn('#1379', body)
        self.assertIn('#1403', body)
        self.assertIn('[build / linux_build](https://job)', body)
        self.assertNotIn('report', body)

    def test_later_red_build_updates_and_comments_on_the_open_issue(self):
        fake = FakeGitHub(issues=[{'number': 44, 'body': 'x\n' + MARKER}, {'number': 43, 'body': MARKER}])
        self.run_main('failure', fake)
        edit, comment = fake.writes
        self.assertEqual(edit[:3], ('issue', 'edit', '43'))
        self.assertIn(MARKER, edit[edit.index('--body') + 1])
        self.assertEqual(comment[:3], ('issue', 'comment', '43'))
        self.assertIn('#1379, #1403', comment[comment.index('--body') + 1])

    def test_green_build_closes_the_open_issue(self):
        fake = FakeGitHub(issues=[{'number': 43, 'body': MARKER}])
        ranged = self.run_main('success', fake)
        ranged.assert_not_called()
        [close] = fake.writes
        self.assertEqual(close[:3], ('issue', 'close', '43'))
        self.assertIn('green on `' + 'd' * 40 + '`', close[close.index('--comment') + 1])

    def test_green_build_without_an_issue_writes_nothing(self):
        fake = FakeGitHub(issues=[{'number': 9, 'body': None}])
        self.run_main('success', fake)
        self.assertEqual(fake.writes, [])

    def test_first_ever_red_build_has_no_green_to_range_from(self):
        fake = FakeGitHub(green=None)
        ranged = self.run_main('failure', fake)
        ranged.assert_called_once_with(None, 'd' * 40)


if __name__ == '__main__':
    unittest.main()
