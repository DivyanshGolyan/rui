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
import textwrap
from types import SimpleNamespace
import unittest
from unittest import mock

import auto_land
from select_tests import CHECK_COVERS, select
from strict_paths import STRICT, strict


def workflow(name):
    return Path('.github/workflows', name).read_text()


class LandingTest(unittest.TestCase):
    def test_upgrade_check_runs_on_exactly_the_strict_paths(self):
        text = workflow('previous-release-upgrade.yml')
        on = text.split('\npermissions:', 1)[0]
        lists = re.findall(r"(?m)^    paths:\n((?:      - '[^']+'\n)+)", on)
        self.assertEqual(len(lists), 1, 'strict PRs filter; stable dispatch never filters')
        for block in lists:
            self.assertEqual(tuple(re.findall(r"'([^']+)'", block)), STRICT)
        self.assertNotIn('  push:', on)
        self.assertIn('  workflow_dispatch:', on)

    def test_upgrade_concurrency_cancels_superseded_prs_but_keeps_main_shas(self):
        text = workflow('previous-release-upgrade.yml')
        template = re.search(r'(?m)^  group: (.+)$', text)[1]

        def group(event, ref, sha):
            github = SimpleNamespace(event_name=event, ref=ref, sha=sha)
            return re.sub(r'\$\{\{(.*?)\}\}', lambda match: str(eval(
                match[1].strip().replace('&&', 'and').replace('||', 'or'),
                {'github': github})), template)

        self.assertIn('  cancel-in-progress: true', text)
        self.assertEqual(group('pull_request', 'refs/pull/3/merge', 'a' * 40),
                         group('pull_request', 'refs/pull/3/merge', 'b' * 40))
        self.assertNotEqual(group('pull_request', 'refs/pull/3/merge', 'a' * 40),
                            group('pull_request', 'refs/pull/4/merge', 'a' * 40))
        self.assertNotEqual(group('workflow_dispatch', 'refs/heads/main', 'a' * 40),
                            group('workflow_dispatch', 'refs/heads/main', 'b' * 40))
        self.assertEqual(group('workflow_dispatch', 'refs/heads/main', 'a' * 40),
                         group('workflow_dispatch', 'refs/heads/main', 'a' * 40))

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
        def run(status='completed', conclusion='success', linux='success', covers=True):
            return dict(status=status, conclusion=conclusion, linux=linux, covers=covers)

        def decide_tip(selected=run(), changed=('src/cli.zig',), fast_forward=True):
            return auto_land.decide(fast_forward, selected, list(changed))
        store = ('src/cli.zig', 'src/store.zig')
        self.assertEqual(decide_tip(fast_forward=False), 'not-fast-forward')
        self.assertEqual(decide_tip(selected=None), 'pending')
        self.assertEqual(decide_tip(selected=run('in_progress', None, linux=None)), 'pending')
        for failed in ('failure', 'cancelled', 'skipped'):
            self.assertEqual(decide_tip(selected=run(linux=failed)), 'red')
        # Strict and non-strict tips use the Linux aggregate, not Mac or overall status.
        for changed in (store, ('src/cli.zig',)):
            self.assertEqual(decide_tip(selected=run('in_progress', None), changed=changed), 'land')
            self.assertEqual(decide_tip(selected=run(conclusion='failure'), changed=changed), 'land')
        self.assertEqual(decide_tip(changed=('.github/workflows/check.yml',)), 'manual')
        self.assertEqual(decide_tip(selected=run(linux='failure'), changed=('.github/workflows/check.yml',)),
                         'red')
        # A green Selected run whose selection does not span main..tip never lands.
        self.assertEqual(decide_tip(selected=run(covers=False), changed=store),
                         'unqualified')

    def test_stable_requires_completed_mac_and_upgrade_not_a_skipped_selector(self):
        selected = dict(status='completed', conclusion='success', macos='success', covers=True,
                        display_title='Stable qualification from base ' + 'a' * 40)
        upgrade = dict(status='completed', conclusion='success')
        self.assertTrue(auto_land.stable_ready(selected, upgrade))
        self.assertFalse(auto_land.stable_ready(None, upgrade))
        self.assertFalse(auto_land.stable_ready(selected, None))
        for verdict in (None, 'skipped', 'failure', 'cancelled'):
            self.assertFalse(auto_land.stable_ready(dict(selected, macos=verdict), upgrade))
            self.assertFalse(auto_land.stable_ready(selected, dict(upgrade, conclusion=verdict)))
        self.assertFalse(auto_land.stable_ready(dict(selected, status='in_progress'), upgrade))
        self.assertFalse(auto_land.stable_ready(selected, dict(upgrade, status='queued')))
        self.assertFalse(auto_land.stable_ready(dict(selected, display_title='Selected checks'), upgrade))
        self.assertFalse(auto_land.stable_ready(dict(selected, covers=False), upgrade))

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

    def test_main_and_stable_advance_independently_on_exact_sha_evidence(self):
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
            green = dict(status='completed', conclusion='success', html_url='u', event='push',
                         linux='success', macos='success')

            def dispatched(from_base=None, **run):
                title = f'Selected checks from base {from_base}' if from_base else 'Selected checks'
                return dict(green, event='workflow_dispatch', display_title=title, **run)
            # Runs are keyed by exact workflow, commit and branch, as latest() filters them.
            runs = {('check.yml', tip, 'wip/land-1'): green}
            dispatches = []

            def dispatch(*args):
                dispatches.append((git('rev-parse', 'origin/main'), args))
                return ''

            with mock.patch.object(auto_land, 'latest',
                                   lambda workflow, sha, branch: dict(runs.get((workflow, sha, branch)) or {}) or None), \
                    mock.patch.object(auto_land, 'aggregate', lambda run, name: run.get(name)), \
                    mock.patch.object(auto_land, 'gh', dispatch), \
                    mock.patch.object(sys, 'argv', ['auto_land.py']), contextlib.redirect_stdout(io.StringIO()):
                # A dispatch must cover the current main delta even when Linux passes.
                for unqualified in (dispatched(), dispatched(tip), dispatched('f' * 40)):
                    runs[('check.yml', tip, 'wip/land-1')] = unqualified
                    auto_land.main()
                    self.assertEqual(refs(), (base, base))
                runs[('check.yml', tip, 'wip/land-1')] = dispatched(base)
                auto_land.main()
                self.assertEqual(refs(), (tip, base))
                self.assertEqual({(sha, args[2]) for sha, args in dispatches},
                                 {(tip, 'check.yml'), (tip, auto_land.UPGRADE)})
                self.assertTrue(all('--ref' in args and 'main' in args for _, args in dispatches))
                # A landed tip is skipped, not pushed again.
                auto_land.main()
                self.assertEqual(refs(), (tip, base))
                auto_land.promote_stable()
                self.assertEqual(refs(), (tip, base))
                # Qualification on the landing branch cannot qualify stable.
                runs[(auto_land.UPGRADE, tip, 'wip/land-1')] = green
                auto_land.promote_stable()
                self.assertEqual(refs(), (tip, base))
                runs[('check.yml', tip, 'main')] = dict(green, event='workflow_dispatch',
                    display_title='Stable qualification from base ' + base)
                runs[(auto_land.UPGRADE, tip, 'main')] = dict(green, conclusion='failure')
                auto_land.promote_stable()
                self.assertEqual(refs(), (tip, base))
                runs[(auto_land.UPGRADE, tip, 'main')] = green
                # Passing workflows cannot omit mapped native targets by selecting
                # from the candidate itself or from a branch stable does not contain.
                side = commit('docs/side.md', base)
                for bad_base in (tip, side):
                    runs[('check.yml', tip, 'main')] = dict(green, event='workflow_dispatch',
                        display_title='Stable qualification from base ' + bad_base)
                    auto_land.promote_stable()
                    self.assertEqual(refs(), (tip, base), bad_base)
                runs[('check.yml', tip, 'main')] = dict(green, event='workflow_dispatch',
                    display_title='Stable qualification from base ' + base)
                auto_land.promote_stable()
                self.assertEqual(refs(), (tip, tip))

                # A changed main cannot be overwritten using an earlier coverage decision.
                late = commit('src/cli.zig', tip)
                moved = commit('docs/other.md', tip)
                git('push', '-q', 'origin', f'{moved}:refs/heads/main')
                runs[('check.yml', late, 'wip/land-2')] = green
                self.assertFalse(auto_land.land('wip/land-2', late, tip))
                self.assertEqual(refs(), (moved, tip))

                # A stale dispatch base must still cover a strict path hidden by a later undo.
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
                # An ancestor's green checks never qualify a descendant.
                runs[('check.yml', ahead, 'main')] = dict(green, event='workflow_dispatch',
                    display_title='Stable qualification from base ' + tip)
                auto_land.promote_stable()
                self.assertEqual(refs(), (ahead, tip))
                # Two qualified main commits: promote the newest, not the first completion.
                runs[(auto_land.UPGRADE, moved, 'main')] = green
                runs[('check.yml', moved, 'main')] = dict(green, event='workflow_dispatch',
                    display_title='Stable qualification from base ' + tip)
                runs[(auto_land.UPGRADE, ahead, 'main')] = green
                auto_land.promote_stable()
                self.assertEqual(refs(), (ahead, ahead))
                # Replayed/older completions and repeated promotion are harmless no-ops.
                auto_land.promote_stable()
                auto_land.promote_stable()
                self.assertEqual(refs(), (ahead, ahead))
                # Stable advanced since the dispatch base: ancestor identity alone
                # cannot cover a changed-then-reverted strict path hidden by that base.
                git('push', '-q', 'origin', f'{restored}:refs/heads/main')
                runs[(auto_land.UPGRADE, restored, 'main')] = green
                for old_base in (tip, moved):
                    runs[('check.yml', restored, 'main')] = dict(green, event='workflow_dispatch',
                        display_title='Stable qualification from base ' + old_base)
                    auto_land.promote_stable()
                    self.assertEqual(refs(), (restored, ahead))
                runs[('check.yml', restored, 'main')] = dict(green, event='workflow_dispatch',
                    display_title='Stable qualification from base ' + ahead)
                auto_land.promote_stable()
                self.assertEqual(refs(), (restored, restored))
                # A covering older base remains valid after stable moves.
                newest = commit('docs/newest.md', restored)
                git('push', '-q', 'origin', f'{newest}:refs/heads/main')
                runs[(auto_land.UPGRADE, newest, 'main')] = green
                runs[('check.yml', newest, 'main')] = dict(green, event='workflow_dispatch',
                    display_title='Stable qualification from base ' + ahead)
                auto_land.promote_stable()
                self.assertEqual(refs(), (newest, newest))

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
        # Native mappings remain available for post-main stable qualification.
        available = set(re.findall(r'b\.step\(\s*"([a-z0-9-]+)"', Path('build.zig').read_text()))
        for pattern in STRICT:
            path = pattern.replace('*', '_x')
            self.assertEqual(strict([path]), [path])
            self.assertTrue(select([path], 'review', available)['native_required'], path)

    def test_executed_plan_keeps_main_linux_only_and_forces_real_stable_mac(self):
        script = textwrap.dedent(re.search(
            r"(?ms)^          python3 - <<'PY'\n(.*?)^          PY$", workflow('check.yml'))[1])
        available = set(re.findall(r'b\.step\(\s*"([a-z0-9-]+)"', Path('build.zig').read_text()))
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            (root / 'tests').symlink_to(Path('tests').resolve(), target_is_directory=True)
            for path in ('README.md', 'tests/qualification/model-output/main.go', 'src/store.zig'):
                selection = select([path], 'review', available)
                for event, stable in (('push', False), ('workflow_dispatch', True), ('pull_request', False)):
                    with self.subTest(path=path, event=event, stable=stable):
                        (root / 'selection.json').write_text(json.dumps(selection))
                        (root / 'output').write_text('')
                        subprocess.run([sys.executable, '-B', '-c', script], cwd=root, check=True,
                            env=dict(os.environ, STABLE=str(stable).lower(), EVENT_NAME=event,
                                     GITHUB_REF_NAME='main' if stable else 'wip/land-21',
                                     GITHUB_OUTPUT=str(root / 'output'),
                                     GITHUB_STEP_SUMMARY=str(root / 'summary')))
                        outputs = dict(line.split('=', 1) for line in (root / 'output').read_text().splitlines())
                        if stable:
                            expected = sorted((set(selection['native_targets']) - CHECK_COVERS)
                                              | {'check', 'admission-debug-integration'})
                            self.assertEqual(json.loads(outputs['targets']), [])
                            self.assertEqual(json.loads(outputs['native_targets']), expected)
                            self.assertEqual(outputs['native'], 'true')
                            self.assertEqual(outputs['retry'], 'false')
                            self.assertTrue(json.loads(outputs['macos_matrix'])['include'])
                        else:
                            self.assertEqual(json.loads(outputs['targets']), selection['targets'])
                            expected = selection['native_targets'] if event == 'pull_request' else []
                            self.assertEqual(json.loads(outputs['native_targets']), expected)
                            self.assertEqual(outputs['native'], str(bool(expected)).lower())

    def test_auto_land_wiring(self):
        on = workflow('auto-land.yml').split('\npermissions:', 1)[0]
        self.assertIn('workflows: [Selected checks, Previous installed-release upgrade]', on)
        self.assertIn("branches: ['wip/land-*', main]", on)
        self.assertIn('auto_land.py', workflow('auto-land.yml'))
        self.assertIn('group: auto-land\n  cancel-in-progress: false', workflow('auto-land.yml'))
        self.assertIn('actions: write', workflow('auto-land.yml'))
        self.assertIn('auto_land.py --promote-stable', workflow('auto-land.yml'))
        self.assertIn("""contains(fromJSON('["push", "workflow_dispatch"]'), github.event.workflow_run.event)""",
                      workflow('auto-land.yml'))
        # Auto-land parses the dispatch base from Selected's run name.
        names = re.findall(r"format\('([^']*)', inputs\.base\)", workflow('check.yml'))
        self.assertTrue(any(auto_land.DISPATCH_BASE.fullmatch(name.format('0' * 40)) for name in names))
        self.assertTrue(any(auto_land.STABLE_BASE.fullmatch(name.format('0' * 40)) for name in names))
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
