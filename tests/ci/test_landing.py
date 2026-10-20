"""Landing-rule wiring: strict paths, post-push decisions and CI triggers."""
import contextlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import auto_land
import main_health
from main_health import decide
from select_tests import select
from strict_paths import STRICT, strict


def workflow(name):
    return Path('.github/workflows', name).read_text()


class LandingTest(unittest.TestCase):
    def test_upgrade_check_runs_on_exactly_the_strict_paths(self):
        text = workflow('previous-release-upgrade.yml')
        on = text.split('\npermissions:', 1)[0]
        lists = re.findall(r"(?m)^    paths:\n((?:      - '[^']+'\n)+)", on)
        self.assertEqual(len(lists), 2, 'pull_request and push both filter')
        for block in lists:
            self.assertEqual(tuple(re.findall(r"'([^']+)'", block)), STRICT)
        self.assertIn("branches: ['wip/land-*', 'main']", on)

    def test_strict_patterns_match_like_github_path_filters(self):
        self.assertEqual(strict([
            'src/store.zig', 'src/server.zig', 'src/execution_turn.zig', 'build.zig', 'build.zig.zon',
            'install.sh', 'tests/integration/bash_integration.py', 'tests/integration/bash_recovery_integration.py',
            'src/cli.zig', 'src/store/nested.zig', 'tests/integration/host_process.py', 'build.zig.bak',
            'docs/install.sh']), [
            'build.zig', 'build.zig.zon', 'install.sh', 'src/execution_turn.zig', 'src/server.zig',
            'src/store.zig', 'tests/integration/bash_integration.py',
            'tests/integration/bash_recovery_integration.py'])

    def test_post_push_decisions(self):
        def run(status='completed', conclusion='success'):
            return dict(status=status, conclusion=conclusion)
        selected, upgrade = 'check.yml', 'previous-release-upgrade.yml'
        self.assertEqual(decide({}, ['src/cli.zig']), 'pending')
        self.assertEqual(decide({upgrade: run()}, ['src/store.zig']), 'pending')
        self.assertEqual(decide({selected: run(), upgrade: run('in_progress', None)}, ['src/store.zig']), 'pending')
        self.assertEqual(decide({selected: run()}, ['src/cli.zig']), 'green')
        self.assertEqual(decide({selected: run(), upgrade: run()}, ['src/store.zig']), 'green')
        # A strict change waits for its upgrade check before stable can move.
        self.assertEqual(decide({selected: run()}, ['src/store.zig']), 'pending')
        self.assertEqual(decide({selected: run(conclusion='failure')}, ['src/cli.zig']), 'issue')
        self.assertEqual(decide({selected: run(conclusion='failure'), upgrade: run()},
                                ['src/cli.zig', 'src/store.zig']), 'revert')
        self.assertEqual(decide({selected: run(), upgrade: run(conclusion='failure')}, ['install.sh']), 'revert')
        self.assertEqual(decide({selected: run(conclusion='cancelled'), upgrade: run()}, ['src/server.zig']), 'revert')

    def test_auto_land_decisions(self):
        def run(status='completed', conclusion='success', mac=None):
            return dict(status=status, conclusion=conclusion, macos=mac)

        def decide_tip(selected=run(), upgrade=None, changed=('src/cli.zig',), frozen=False, fast_forward=True):
            return auto_land.decide(frozen, fast_forward, selected, upgrade, list(changed))
        store = ('src/cli.zig', 'src/store.zig')
        self.assertEqual(decide_tip(frozen=True), 'frozen')
        self.assertEqual(decide_tip(fast_forward=False), 'not-fast-forward')
        self.assertEqual(decide_tip(selected=None), 'pending')
        self.assertEqual(decide_tip(selected=run('in_progress', None)), 'pending')
        self.assertEqual(decide_tip(selected=run(conclusion='failure')), 'red')
        self.assertEqual(decide_tip(selected=run(conclusion='cancelled')), 'red')
        # A strict tip waits for its upgrade run and its Mac aggregate.
        self.assertEqual(decide_tip(selected=run(mac='success'), changed=store), 'pending')
        self.assertEqual(decide_tip(selected=run(mac='success'), upgrade=run('queued', None), changed=store), 'pending')
        self.assertEqual(decide_tip(selected=run(mac='success'), upgrade=run(conclusion='failure'), changed=store),
                         'red')
        self.assertEqual(decide_tip(selected=run(mac=None), upgrade=run(), changed=store), 'red')
        self.assertEqual(decide_tip(selected=run(mac='skipped'), upgrade=run(), changed=store), 'red')
        self.assertEqual(decide_tip(selected=run(mac='success'), upgrade=run(), changed=store), 'land')
        self.assertEqual(decide_tip(), 'land')
        # A non-strict tip lands without an upgrade run, and a red one does not hold it.
        self.assertEqual(decide_tip(upgrade=run(conclusion='failure')), 'land')
        self.assertEqual(decide_tip(changed=('.github/workflows/check.yml',)), 'manual')
        self.assertEqual(decide_tip(selected=run(conclusion='failure'), changed=('.github/workflows/check.yml',)),
                         'red')

    def test_post_push_dispatch_requires_the_exact_pushed_sha(self):
        pushed, before, newer = 'a' * 40, 'b' * 40, 'c' * 40
        both = ['check.yml', 'previous-release-upgrade.yml']

        def run_dispatch(head):
            calls = []

            def gh(*args):
                calls.append(args)
                if 'POST' in args:
                    return '{"workflow_run_id": 7, "html_url": "https://example/run/7"}'
                return json.dumps({'head_sha': head})
            with mock.patch.dict(os.environ, GITHUB_REPOSITORY='o/r'), \
                    mock.patch.object(main_health, 'gh', gh), contextlib.redirect_stdout(io.StringIO()):
                main_health.dispatch(pushed, before, both)
            return [call[3].rsplit('/', 2)[1] for call in calls if 'POST' in call], calls

        workflows, calls = run_dispatch(pushed)
        self.assertEqual(workflows, both)
        self.assertIn(f'inputs[base]={before}', calls[0])
        # A run GitHub started on a newer main is not the pushed commit's post-push run.
        with self.assertRaises(SystemExit) as failure:
            run_dispatch(newer)
        self.assertIn(pushed, str(failure.exception))
        self.assertIn(f'check.yml ran on {newer}', str(failure.exception))
        self.assertIn(f'previous-release-upgrade.yml ran on {newer}', str(failure.exception))

    def test_landing_and_post_push_follow_actual_pushes_and_paths(self):
        with tempfile.TemporaryDirectory() as scratch, contextlib.chdir(scratch):
            def git(*args):
                return subprocess.run(['git', *args], check=True, capture_output=True, text=True).stdout.strip()

            def commit(path):
                Path(path).parent.mkdir(parents=True, exist_ok=True)
                Path(path).write_text(path)
                git('add', '-A')
                git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', path)
                return git('rev-parse', 'HEAD')
            git('init', '-q', '--bare', '-b', 'main', 'remote.git')
            git('clone', '-q', 'remote.git', 'work')
            os.chdir('work')
            stable = commit('README.md')
            # Git quotes non-ASCII names by default; a strict path must stay strict.
            store = commit('src/store_é.zig')
            cli = commit('src/cli.zig')
            git('push', '-q', 'origin', f'{stable}:refs/heads/stable', f'{cli}:refs/heads/main')
            self.assertEqual(main_health.required(stable, store), ['check.yml', 'previous-release-upgrade.yml'])
            green = dict(status='completed', conclusion='success', macos='success', html_url='u')
            self.assertEqual(auto_land.decide(False, True, green, None, main_health.changed(stable, store)),
                             'pending')

            # Two pushes: stable..store, then store..cli. Only cli has post-push runs.
            activity = [[dict(before=store, after=cli), dict(before=stable, after=store)]]
            exact = {('check.yml', cli): green, ('previous-release-upgrade.yml', cli): green}
            reports = []
            with mock.patch.dict(os.environ, GITHUB_REPOSITORY='o/r'), \
                    mock.patch.object(main_health, 'gh', lambda *args: json.dumps(activity)), \
                    mock.patch.object(main_health, 'latest', lambda workflow, sha, branch: exact.get((workflow, sha))), \
                    mock.patch.object(main_health, 'filed', lambda title: False), \
                    mock.patch.object(main_health, 'report', lambda title, body, label=None: reports.append(title)), \
                    mock.patch.object(sys, 'argv', ['main_health.py', 'check']), \
                    contextlib.redirect_stdout(io.StringIO()):
                main_health.main()
                # The store push never got its own runs: stable holds and the user is told.
                self.assertEqual(git('ls-remote', 'origin', 'refs/heads/stable').split()[0], stable)
                self.assertEqual(reports, [f'Main push {store[:12]} has no post-push CI'])
                # An older strict push's upgrade run does not cover a newer strict push.
                exact[('previous-release-upgrade.yml', 'older')] = green
                self.assertNotIn('previous-release-upgrade.yml',
                                 main_health.runs(store, [(store, stable), ('older', None)]))
                exact.update({('check.yml', store): green, ('previous-release-upgrade.yml', store): green})
                main_health.main()
                self.assertEqual(git('ls-remote', 'origin', 'refs/heads/stable').split()[0], cli)

    def test_selected_runs_mac_for_every_strict_path(self):
        # Auto-land relies on Selected's Mac aggregate for strict tips.
        available = set(re.findall(r'b\.step\(\s*"([a-z0-9-]+)"', Path('build.zig').read_text()))
        for pattern in STRICT:
            path = pattern.replace('*', '_x')
            self.assertEqual(strict([path]), [path])
            self.assertTrue(select([path], 'review', available)['native_required'], path)

    def test_auto_land_and_post_push_dispatch_wiring(self):
        on = workflow('auto-land.yml').split('\npermissions:', 1)[0]
        self.assertIn('workflows: [Selected checks, Previous installed-release upgrade]', on)
        self.assertIn("branches: ['wip/land-*']", on)
        self.assertIn('auto_land.py', workflow('auto-land.yml'))
        self.assertIn('group: auto-land\n  cancel-in-progress: false', workflow('auto-land.yml'))
        self.assertTrue(auto_land.BRANCH.fullmatch('wip/land-12'))
        self.assertFalse(auto_land.BRANCH.fullmatch('wip/land-12x'))
        for name in ('check.yml', 'previous-release-upgrade.yml'):
            self.assertIn('\n  workflow_dispatch:', workflow(name).split('\npermissions:', 1)[0], name)
        self.assertIn("contains(fromJSON('[\"push\", \"workflow_dispatch\"]'), github.event.workflow_run.event)",
                      workflow('main-health.yml'))

    def test_selected_runs_only_on_pull_requests_landing_tips_and_main(self):
        text = workflow('check.yml')
        on = text.split('\npermissions:', 1)[0]
        self.assertIn("  push:\n    branches: [main, 'wip/land-*']\n", on)
        self.assertNotIn('branches-ignore', on)
        self.assertNotIn('github-script', text, 'no duplicate-push suppression')
        for aggregate in ('linux', 'macos'):
            job = re.search(rf'(?ms)^  {aggregate}:\n(.*?)(?=^  [a-z_]+:|\Z)', text)[1]
            self.assertNotIn('cache_execution', job, 'cache proof is not gating')
        for build in ('linux_build', 'macos_build'):
            job = re.search(rf'(?ms)^  {build}:\n(.*?)(?=^  [a-z_]+:|\Z)', text)[1]
            self.assertNotIn('cache_execution.py', job)


if __name__ == '__main__':
    unittest.main()
