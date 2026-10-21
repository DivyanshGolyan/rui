"""Landing-rule wiring: strict paths, auto-land decisions and pushes, CI triggers."""
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
        self.assertIn("branches: ['wip/land-*']", on)

    def test_strict_patterns_match_like_github_path_filters(self):
        self.assertEqual(strict([
            'src/store.zig', 'src/server.zig', 'src/execution_turn.zig', 'build.zig', 'build.zig.zon',
            'install.sh', 'tests/integration/bash_integration.py', 'tests/integration/bash_recovery_integration.py',
            'src/cli.zig', 'src/store/nested.zig', 'tests/integration/host_process.py', 'build.zig.bak',
            'docs/install.sh']), [
            'build.zig', 'build.zig.zon', 'install.sh', 'src/execution_turn.zig', 'src/server.zig',
            'src/store.zig', 'tests/integration/bash_integration.py',
            'tests/integration/bash_recovery_integration.py'])

    def test_auto_land_decisions(self):
        def run(status='completed', conclusion='success', mac=None, covers=True):
            return dict(status=status, conclusion=conclusion, macos=mac, covers=covers)

        def decide_tip(selected=run(), upgrade=None, changed=('src/cli.zig',), fast_forward=True):
            return auto_land.decide(fast_forward, selected, upgrade, list(changed))
        store = ('src/cli.zig', 'src/store.zig')
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
        # A green Selected run whose selection does not span main..tip never lands.
        self.assertEqual(decide_tip(selected=run(mac='success', covers=False), upgrade=run(), changed=store),
                         'unqualified')

    def test_latest_takes_the_newest_push_or_dispatch_run_on_the_exact_commit(self):
        sha, other = 'a' * 40, 'b' * 40

        def row(id, event, head=sha, branch='wip/land-1', repo='o/r', conclusion='success'):
            return dict(id=id, event=event, head_sha=head, head_branch=branch, conclusion=conclusion,
                        head_repository=dict(full_name=repo))
        rows = {'push': [row(1, 'push', conclusion='cancelled')],
                'workflow_dispatch': [row(2, 'workflow_dispatch'), row(5, 'workflow_dispatch', head=other),
                                      row(6, 'workflow_dispatch', branch='wip/land-2'),
                                      row(7, 'workflow_dispatch', repo='fork/r')]}

        def gh(*args):
            event = args[1].rsplit('event=', 1)[1].split('&', 1)[0]
            self.assertIn(f'head_sha={sha}&branch=wip/land-1', args[1])
            return json.dumps(dict(workflow_runs=rows[event]))
        with mock.patch.dict(os.environ, GITHUB_REPOSITORY='o/r'), mock.patch.object(auto_land, 'gh', gh):
            # A dispatch replaces the cancelled push run; other commits, branches and forks never count.
            self.assertEqual(auto_land.latest(auto_land.UPGRADE, sha, 'wip/land-1')['id'], 2)
            rows['workflow_dispatch'] = rows['workflow_dispatch'][1:]
            self.assertEqual(auto_land.latest(auto_land.UPGRADE, sha, 'wip/land-1')['id'], 1)

    def test_auto_land_moves_main_and_stable_together_or_not_at_all(self):
        with tempfile.TemporaryDirectory() as scratch, contextlib.chdir(scratch):
            def git(*args):
                return subprocess.run(['git', *args], check=True, capture_output=True, text=True).stdout.strip()

            def commit(path, parent):
                git('checkout', '-q', '--detach', parent)
                Path(path).parent.mkdir(parents=True, exist_ok=True)
                Path(path).write_text(path)
                git('add', '-A')
                git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', path)
                return git('rev-parse', 'HEAD')

            def refs():
                return tuple(git('ls-remote', 'origin', f'refs/heads/{name}').split()[0] for name in ('main', 'stable'))
            git('init', '-q', '--bare', '-b', 'main', 'remote.git')
            git('clone', '-q', 'remote.git', 'work')
            os.chdir('work')
            Path('README.md').write_text('base')
            git('add', '-A')
            git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base')
            base = git('rev-parse', 'HEAD')
            # Git quotes non-ASCII names by default; a strict path must stay strict.
            tip = commit('src/store_é.zig', base)
            git('push', '-q', 'origin', f'{base}:refs/heads/main', f'{base}:refs/heads/stable',
                f'{tip}:refs/heads/wip/land-1')
            green = dict(status='completed', conclusion='success', html_url='u', event='push')

            def dispatched(from_base=None, **run):
                title = f'Selected checks from base {from_base}' if from_base else 'Selected checks'
                return dict(green, event='workflow_dispatch', display_title=title, **run)
            # Runs are keyed by exact workflow, commit and branch, as latest() filters them.
            runs = {('check.yml', tip, 'wip/land-1'): green}
            with mock.patch.object(auto_land, 'latest',
                                   lambda workflow, sha, branch: dict(runs.get((workflow, sha, branch)) or {}) or None), \
                    mock.patch.object(auto_land, 'macos', lambda run: 'success'), \
                    mock.patch.object(sys, 'argv', ['auto_land.py']), contextlib.redirect_stdout(io.StringIO()):
                # Strict without its upgrade run: nothing moves.
                auto_land.main()
                self.assertEqual(refs(), (base, base))
                # A cancelled push upgrade run does not land.
                runs[(auto_land.UPGRADE, tip, 'wip/land-1')] = dict(green, conclusion='cancelled')
                auto_land.main()
                self.assertEqual(refs(), (base, base))
                # A dispatched upgrade run on the exact tip replaces it, but a dispatched
                # Selected run lands only with a recorded base main contains.
                runs[(auto_land.UPGRADE, tip, 'wip/land-1')] = dispatched()
                for unqualified in (dispatched(), dispatched(tip), dispatched('f' * 40)):
                    runs[('check.yml', tip, 'wip/land-1')] = unqualified
                    auto_land.main()
                    self.assertEqual(refs(), (base, base))
                runs[('check.yml', tip, 'wip/land-1')] = dispatched(base)
                auto_land.main()
                self.assertEqual(refs(), (tip, tip))
                # A landed tip is skipped, not pushed again.
                auto_land.main()
                self.assertEqual(refs(), (tip, tip))

                # main moved between the decision and the push: stable alone could
                # fast-forward, but the atomic push moves neither.
                late = commit('src/cli.zig', tip)
                moved = commit('docs/other.md', tip)
                git('push', '-q', 'origin', f'{moved}:refs/heads/main')
                runs[('check.yml', late, 'wip/land-2')] = green
                self.assertFalse(auto_land.land('wip/land-2', late, tip))
                self.assertEqual(refs(), (moved, tip))

                # main moved forward to an ancestor of the tip: moved→restored is
                # clean, but ahead→restored undoes a strict change, so the push
                # made from the stale classification must not land.
                ahead = commit('src/store.zig', moved)
                git('rm', '-q', 'src/store.zig')
                restored = commit('src/cli2.zig', 'HEAD')
                git('push', '-q', 'origin', f'{ahead}:refs/heads/main')
                runs[('check.yml', restored, 'wip/land-4')] = green
                self.assertFalse(auto_land.land('wip/land-4', restored, moved))
                self.assertEqual(refs(), (ahead, tip))
                # A dispatch from a base main contains still misses the strict path that
                # moved..restored hides; only a base whose delta spans main..tip covers it.
                paths = auto_land.changed_paths(ahead, restored)[0]
                self.assertFalse(auto_land.covers(dispatched(moved), restored, ahead, paths))
                self.assertTrue(auto_land.covers(dispatched(ahead), restored, ahead, paths))
                git('push', '-q', '--force', 'origin', f'{moved}:refs/heads/main')

                # stable off main's line: main alone could fast-forward, but the
                # push fails loudly and main stays.
                side = commit('docs/side.md', base)
                git('push', '-q', '--force', 'origin', f'{side}:refs/heads/stable')
                after = commit('src/client.zig', moved)
                git('push', '-q', 'origin', f'{after}:refs/heads/wip/land-3')
                runs[('check.yml', after, 'wip/land-3')] = green
                with self.assertRaises(SystemExit) as failure:
                    auto_land.main()
                self.assertIn('neither moved', str(failure.exception))
                self.assertEqual(refs(), (moved, side))

    def test_preflight_allows_one_open_landing_stack(self):
        with tempfile.TemporaryDirectory() as scratch, contextlib.chdir(scratch):
            def git(*args):
                return subprocess.run(['git', *args], check=True, capture_output=True, text=True).stdout.strip()

            def commit(path, parent):
                git('checkout', '-q', '--detach', parent)
                Path(path).write_text(path)
                git('add', '-A')
                git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', path)
                return git('rev-parse', 'HEAD')

            def preflight(branch, sha):
                with contextlib.redirect_stdout(io.StringIO()):
                    auto_land.preflight(branch, sha)
            git('init', '-q', '--bare', '-b', 'main', 'remote.git')
            git('clone', '-q', 'remote.git', 'work')
            os.chdir('work')
            Path('README.md').write_text('base')
            git('add', '-A')
            git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base')
            base = git('rev-parse', 'HEAD')
            landed = commit('landed', base)
            git('push', '-q', 'origin', f'{landed}:refs/heads/main', f'{landed}:refs/heads/wip/land-3')
            # Zero open: a historical ref main contains never counts.
            first = commit('first', landed)
            preflight('wip/land-4', first)
            git('push', '-q', 'origin', f'{first}:refs/heads/wip/land-4')
            # One open: re-pushing that same branch passes.
            preflight('wip/land-4', commit('first-fix', first))
            # A second ref fails before any push, whether it contains the open
            # stack or sits beside it; so does a lower number.
            for candidate in (commit('second', first), commit('beside', landed)):
                with self.assertRaisesRegex(SystemExit, 'wip/land-4 .* still open'):
                    preflight('wip/land-5', candidate)
            with self.assertRaisesRegex(SystemExit, 'below wip/land-4'):
                preflight('wip/land-2', first)
            # Multiple open (already violated): every further push fails, even to one of them.
            beside = commit('beside', landed)
            git('push', '-q', 'origin', f'{beside}:refs/heads/wip/land-5')
            with self.assertRaisesRegex(SystemExit, 'wip/land-4 .* still open'):
                preflight('wip/land-5', commit('third', beside))
            # Retiring the abandoned stack restores one open stack.
            git('push', '-q', 'origin', ':refs/heads/wip/land-4')
            preflight('wip/land-5', commit('third', beside))
            with self.assertRaisesRegex(SystemExit, 'wip/land-5 .* still open'):
                preflight('wip/land-6', commit('combined', beside))

    def test_selected_runs_mac_for_every_strict_path(self):
        # Auto-land relies on Selected's Mac aggregate for strict tips.
        available = set(re.findall(r'b\.step\(\s*"([a-z0-9-]+)"', Path('build.zig').read_text()))
        for pattern in STRICT:
            path = pattern.replace('*', '_x')
            self.assertEqual(strict([path]), [path])
            self.assertTrue(select([path], 'review', available)['native_required'], path)

    def test_auto_land_wiring(self):
        on = workflow('auto-land.yml').split('\npermissions:', 1)[0]
        self.assertIn('workflows: [Selected checks, Previous installed-release upgrade]', on)
        self.assertIn("branches: ['wip/land-*']", on)
        self.assertIn('auto_land.py', workflow('auto-land.yml'))
        self.assertIn('group: auto-land\n  cancel-in-progress: false', workflow('auto-land.yml'))
        self.assertIn("""contains(fromJSON('["push", "workflow_dispatch"]'), github.event.workflow_run.event)""",
                      workflow('auto-land.yml'))
        # Auto-land parses the dispatch base from Selected's run name.
        name = re.search(r"(?m)^run-name: .*format\('([^']*)', inputs\.base\)", workflow('check.yml'))[1]
        self.assertTrue(auto_land.DISPATCH_BASE.fullmatch(name.format('0' * 40)))
        self.assertTrue(auto_land.BRANCH.fullmatch('wip/land-12'))
        self.assertFalse(auto_land.BRANCH.fullmatch('wip/land-12x'))

    def test_selected_runs_only_on_pull_requests_and_landing_tips(self):
        text = workflow('check.yml')
        on = text.split('\npermissions:', 1)[0]
        self.assertIn("  push:\n    branches: ['wip/land-*']\n", on)
        plan = re.search(r'(?ms)^  plan:\n(.*?)(?=^  [a-z_]+:|\Z)', text)[1]
        self.assertLess(plan.index('auto_land.py --preflight "$GITHUB_REF_NAME"'), plan.index('select_tests.py'))
        for aggregate in ('linux', 'macos'):
            job = re.search(rf'(?ms)^  {aggregate}:\n(.*?)(?=^  [a-z_]+:|\Z)', text)[1]
            self.assertNotIn('cache_execution', job, 'cache proof is not gating')
        for build in ('linux_build', 'macos_build'):
            job = re.search(rf'(?ms)^  {build}:\n(.*?)(?=^  [a-z_]+:|\Z)', text)[1]
            self.assertNotIn('cache_execution.py', job)


if __name__ == '__main__':
    unittest.main()
