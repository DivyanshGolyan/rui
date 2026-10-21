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
                    run_id = 7 + sum('POST' in call for call in calls)
                    return json.dumps({'workflow_run_id': run_id, 'html_url': f'https://example/run/{run_id}'})
                return json.dumps({'head_sha': head})
            with mock.patch.dict(os.environ, GITHUB_REPOSITORY='o/r'), \
                    mock.patch.object(main_health, 'gh', gh), contextlib.redirect_stdout(io.StringIO()):
                main_health.dispatch(pushed, before, both)
            return [call[3].rsplit('/', 2)[1] for call in calls if 'POST' in call], calls

        workflows, calls = run_dispatch(pushed)
        # A dispatched run's completion starts no workflow_run, so main health is dispatched
        # last, to wait for exactly the runs just created.
        self.assertEqual(workflows, [*both, 'main-health.yml'])
        self.assertIn(f'inputs[base]={before}', calls[0])
        health = [call for call in calls if 'POST' in call][-1]
        self.assertIn(f'inputs[sha]={pushed}', health)
        self.assertIn('inputs[runs]=8 9', health)
        # A run GitHub started on a newer main is not the pushed commit's post-push run.
        with self.assertRaises(SystemExit) as failure:
            run_dispatch(newer)
        self.assertIn(pushed, str(failure.exception))
        self.assertIn(f'check.yml ran on {newer}', str(failure.exception))
        self.assertIn(f'previous-release-upgrade.yml ran on {newer}', str(failure.exception))

    def test_health_waits_for_exactly_its_runs_to_complete(self):
        sha, other = 'a' * 40, 'b' * 40

        def emitter(path='.github/workflows/check.yml', status='completed', conclusion='success', **change):
            return dict(dict(path=path, head_repository=dict(full_name='o/r'), head_branch='main',
                             event='workflow_dispatch', head_sha=sha, status=status, conclusion=conclusion), **change)

        def run_wait(states, run_ids=('1', '2'), limit=3600):
            """states maps run ID to the run each successive read returns; returns the clock at exit."""
            clock = [0.0]
            reads = {run_id: iter(runs) for run_id, runs in states.items()}

            def gh(*args):
                return json.dumps(next(reads[args[1].rsplit('/', 1)[1]]))
            fake_time = mock.Mock(monotonic=lambda: clock[0], sleep=lambda seconds: clock.__setitem__(0, clock[0] + seconds))
            with mock.patch.dict(os.environ, GITHUB_REPOSITORY='o/r'), mock.patch.object(main_health, 'gh', gh), \
                    mock.patch.object(main_health, 'time', fake_time), contextlib.redirect_stdout(io.StringIO()):
                main_health.wait(sha, list(run_ids), limit)
            return clock[0]

        upgrade = '.github/workflows/previous-release-upgrade.yml'
        # Either finish order: return only after both, including a cancelled whole run.
        self.assertEqual(run_wait({'1': [emitter(status='queued'), emitter(status='in_progress'), emitter()],
                                   '2': [emitter(upgrade, conclusion='cancelled')]}), 60)
        self.assertEqual(run_wait({'1': [emitter()],
                                   '2': [emitter(upgrade, status='in_progress'), emitter(upgrade, conclusion='failure')]}),
                         30)
        # Wrong identity or no completion before the deadline: no decision.
        for wrong in (dict(head_sha=other), dict(head_branch='wip/land-3'), dict(event='pull_request'),
                      dict(path='.github/workflows/main-health.yml'), dict(head_repository=dict(full_name='fork/r'))):
            with self.assertRaises(SystemExit):
                run_wait({'1': [emitter(**wrong)]}, ['1'])
        with self.assertRaises(SystemExit):
            run_wait({'1': [emitter(status='in_progress')] * 10}, ['1'], limit=90)
        for run_ids in ([], ['1 2'], ['x']):
            with self.assertRaises(SystemExit):
                run_wait({}, run_ids)

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
            git('rm', '-q', 'src/store_é.zig')
            git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'Revert store')
            revert = git('rev-parse', 'HEAD')
            cli = commit('src/cli.zig')
            git('push', '-q', 'origin', f'{stable}:refs/heads/stable', f'{cli}:refs/heads/main')
            self.assertEqual(main_health.required(stable, store), ['check.yml', 'previous-release-upgrade.yml'])
            green = dict(status='completed', conclusion='success', macos='success', html_url='u')
            red = dict(green, conclusion='failure')
            self.assertEqual(auto_land.decide(False, True, green, None, main_health.changed(stable, store)),
                             'pending')

            def stable_ref():
                return git('ls-remote', 'origin', 'refs/heads/stable').split()[0]
            # Three pushes, newest first: store (red, already reverted and frozen), its revert, then cli.
            complete = [dict(before=revert, after=cli), dict(before=store, after=revert),
                        dict(before=stable, after=store)]
            activity = []
            exact = {('check.yml', store): red, ('previous-release-upgrade.yml', store): green,
                     ('check.yml', revert): green, ('check.yml', cli): green}
            reports, dispatched = [], []
            with mock.patch.dict(os.environ, GITHUB_REPOSITORY='o/r'), \
                    mock.patch.object(main_health, 'gh', lambda *args: json.dumps([activity])), \
                    mock.patch.object(main_health, 'latest', lambda workflow, sha, branch: exact.get((workflow, sha))), \
                    mock.patch.object(auto_land, 'latest', lambda workflow, sha, branch: exact.get((workflow, sha))), \
                    mock.patch.object(auto_land, 'dispatch', lambda *args: dispatched.append(args)), \
                    mock.patch.object(main_health, 'filed', lambda title: title.startswith('Landing frozen')), \
                    mock.patch.object(main_health, 'report', lambda title, body, label=None: reports.append(title)), \
                    mock.patch.object(sys, 'argv', ['main_health.py', 'check']), \
                    contextlib.redirect_stdout(io.StringIO()):
                # Missing or partial push history never stands in for a push boundary.
                for seen in ([], complete[:1], complete[:2]):
                    activity[:] = seen
                    with self.assertRaises(SystemExit):
                        main_health.main()
                    with self.assertRaises(SystemExit):
                        auto_land.repair(cli)
                    self.assertEqual((stable_ref(), dispatched), (stable, []))
                activity[:] = complete
                main_health.main()
                # The revert is clean against stable but undid a strict change, so it needs its
                # own upgrade run; once cli follows, that run can never exist.
                self.assertEqual(stable_ref(), stable)
                self.assertEqual(reports, [f'Main push {revert[:12]} has no post-push CI'])
                # An older strict push's upgrade run does not cover a newer strict push.
                self.assertNotIn('previous-release-upgrade.yml',
                                 main_health.runs(revert, [(revert, store), (store, stable)]))
                # Before landing on a main head without its own runs, auto-land starts them.
                exact[('check.yml', cli)] = None
                auto_land.repair(cli)
                self.assertEqual(dispatched, [(cli, revert, ['check.yml'])])
                exact.update({('previous-release-upgrade.yml', revert): green, ('check.yml', cli): green})
                main_health.main()
                self.assertEqual(stable_ref(), cli)

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
        health = workflow('main-health.yml')
        self.assertIn("contains(fromJSON('[\"push\", \"workflow_dispatch\"]'), github.event.workflow_run.event)", health)
        self.assertIn('\n  workflow_dispatch:', health.split('\npermissions:', 1)[0])
        waiter = re.search(r'(?ms)^  wait:\n(.*?)(?=^  [a-z_]+:|\Z)', health)[1]
        decider = re.search(r'(?ms)^  decide:\n(.*?)(?=^  [a-z_]+:|\Z)', health)[1]
        # Waits stay outside the decision group, so a newer push never replaces an older slow
        # push's wait; the serialized decision replays every push since stable.
        self.assertNotIn('concurrency', waiter)
        self.assertNotIn('\nconcurrency:', health)
        self.assertIn('group: main-health', decider)
        self.assertIn('needs: wait', decider)
        self.assertIn("needs.wait.result == 'success'", decider)
        self.assertIn('main_health.py wait', waiter)
        self.assertNotIn('write', waiter)
        self.assertGreater(int(re.search(r'timeout-minutes: (\d+)', waiter)[1]) * 60, main_health.WAIT)

    def test_selected_runs_only_on_pull_requests_landing_tips_and_main(self):
        text = workflow('check.yml')
        on = text.split('\npermissions:', 1)[0]
        self.assertIn("  push:\n    branches: [main, 'wip/land-*']\n", on)
        for aggregate in ('linux', 'macos'):
            job = re.search(rf'(?ms)^  {aggregate}:\n(.*?)(?=^  [a-z_]+:|\Z)', text)[1]
            self.assertNotIn('cache_execution', job, 'cache proof is not gating')
        for build in ('linux_build', 'macos_build'):
            job = re.search(rf'(?ms)^  {build}:\n(.*?)(?=^  [a-z_]+:|\Z)', text)[1]
            self.assertNotIn('cache_execution.py', job)


if __name__ == '__main__':
    unittest.main()
