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
    def test_upgrade_check_runs_only_by_stable_dispatch(self):
        on = workflow('previous-release-upgrade.yml').split('\npermissions:', 1)[0]
        self.assertEqual(re.findall(r'(?m)^  ([a-z_]+):', on), ['workflow_dispatch'])

    def test_upgrade_concurrency_keeps_main_shas(self):
        text = workflow('previous-release-upgrade.yml')
        template = re.search(r'(?m)^  group: (.+)$', text)[1]

        def group(event, ref, sha):
            github = SimpleNamespace(event_name=event, ref=ref, sha=sha)
            return re.sub(r'\$\{\{(.*?)\}\}', lambda match: str(eval(
                match[1].strip().replace('&&', 'and').replace('||', 'or'),
                {'github': github})), template)

        self.assertIn('  cancel-in-progress: true', text)
        self.assertNotEqual(group('workflow_dispatch', 'refs/heads/main', 'a' * 40),
                            group('workflow_dispatch', 'refs/heads/main', 'b' * 40))
        self.assertEqual(group('workflow_dispatch', 'refs/heads/main', 'a' * 40),
                         group('workflow_dispatch', 'refs/heads/main', 'a' * 40))

    def test_strict_patterns_match_like_github_path_filters(self):
        self.assertEqual(strict([
            'src/store.zig', 'src/server.zig', 'src/execution_turn.zig', 'build.zig', 'build.zig.zon',
            'src/server_execution.zig', 'src/server_host.zig',
            'install.sh', 'tests/integration/bash_integration.py', 'tests/integration/bash_recovery_integration.py',
            'src/cli.zig', 'src/store/nested.zig', 'tests/integration/host_process.py', 'build.zig.bak',
            'docs/install.sh']), [
            'build.zig', 'build.zig.zon', 'install.sh', 'src/execution_turn.zig', 'src/server.zig',
            'src/server_execution.zig', 'src/server_host.zig',
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
                        head_repository=dict(full_name=repo), display_title='Selected checks')
        rows = [row(1, 'push', conclusion='cancelled'), row(2, 'workflow_dispatch'),
                row(5, 'workflow_dispatch', head=other), row(6, 'workflow_dispatch', branch='wip/land-2'),
                row(7, 'workflow_dispatch', repo='fork/r'), row(8, 'pull_request'), row(9, 'schedule')]

        def gh(*args):
            # GitHub's branch and head_sha filters can each falsely omit exact runs.
            if any(f'{field}=' in args[1] for field in ('head_sha', 'branch', 'event')):
                return json.dumps(dict(workflow_runs=[]))
            return json.dumps([dict(workflow_runs=rows)])
        with mock.patch.dict(os.environ, GITHUB_REPOSITORY='o/r'), mock.patch.object(auto_land, 'gh', gh):
            # A dispatch replaces the cancelled push run; other commits, branches and forks never count.
            self.assertEqual(auto_land.latest(auto_land.UPGRADE, sha, 'wip/land-1'), rows[1])
            rows.pop(1)
            self.assertEqual(auto_land.latest(auto_land.UPGRADE, sha, 'wip/land-1')['id'], 1)
            # Main's ordinary diagnostic Selected dispatch is not a stable run,
            # and must not hide an existing queued or failed stable qualification.
            rows = [
                dict(row(10, 'workflow_dispatch', branch='main'), status='queued',
                     display_title='Stable qualification from base ' + other),
                dict(row(11, 'workflow_dispatch', branch='main'), display_title='Selected checks')]
            self.assertEqual(auto_land.latest('check.yml', sha, 'main')['id'], 10)
            self.assertEqual(auto_land.latest(auto_land.UPGRADE, sha, 'main')['id'], 11)
            rows.pop(0)
            self.assertIsNone(auto_land.latest('check.yml', sha, 'main'))

    def test_qualification_discovers_all_pages_and_holds_dispatch_on_lookup_errors(self):
        sha, base = 'a' * 40, 'b' * 40
        existing = dict(id=2, event='workflow_dispatch', head_sha=sha, head_branch='main',
                        head_repository=dict(full_name='o/r'), status='queued', conclusion=None,
                        display_title='Stable qualification from base ' + base)
        unrelated = dict(existing, id=3, head_sha=base)
        pages = [dict(workflow_runs=[unrelated]), dict(workflow_runs=[existing])]
        response = json.dumps(pages)
        failure = None
        failing_workflow = 'check.yml'
        dispatches = []

        def gh(*args):
            if args[0] == 'workflow':
                dispatches.append(args[2])
                return ''
            self.assertEqual(args[0], 'api')
            self.assertIn('--paginate', args)
            self.assertIn('--slurp', args)
            name = args[1].split('/workflows/', 1)[1].split('/runs', 1)[0]
            self.assertEqual(args[1], f'repos/o/r/actions/workflows/{name}/runs?per_page=100')
            if name == failing_workflow:
                if failure:
                    raise failure
                return response
            return json.dumps(pages)

        def git(*args):
            if args[0] == 'fetch':
                return ''
            self.assertEqual(args[0], 'rev-parse')
            return sha if args[1] == 'origin/main' else base

        with mock.patch.dict(os.environ, GITHUB_REPOSITORY='o/r'), \
                mock.patch.object(auto_land, 'gh', gh), mock.patch.object(auto_land, 'git', git), \
                mock.patch.object(auto_land, 'contains', return_value=True), \
                contextlib.redirect_stdout(io.StringIO()):
            # A matching run on a later page is never absence, regardless of outcome.
            for status, conclusion in (('queued', None), ('in_progress', None),
                                       ('completed', 'cancelled'), ('completed', 'failure'),
                                       ('completed', 'skipped')):
                existing.update(status=status, conclusion=conclusion)
                response = json.dumps(pages)
                auto_land.qualify_main()
                self.assertEqual(dispatches, [])
            # The highest matching ID wins even if a later page has a newer match.
            pages[0]['workflow_runs'].append(dict(existing, id=1))
            response = json.dumps(pages)
            self.assertEqual(auto_land.latest('check.yml', sha, 'main')['id'], 2)
            # Only complete, valid history with no exact match permits submission.
            for failing_workflow in ('check.yml', auto_land.UPGRADE):
                for absent in ([dict(workflow_runs=[unrelated]), dict(workflow_runs=[])],
                               [dict(workflow_runs=[])]):
                    response = json.dumps(absent)
                    auto_land.qualify_main()
                    self.assertEqual(dispatches, [failing_workflow])
                    dispatches.clear()
                # Initial API failures and failures after receiving a page both propagate.
                for partial in ('', json.dumps(pages[:1])):
                    failure = subprocess.CalledProcessError(1, ['gh', 'api'], output=partial,
                                                            stderr='injected pagination failure')
                    with self.assertRaises(subprocess.CalledProcessError):
                        auto_land.qualify_main()
                    self.assertEqual(dispatches, [])
                failure = None
                for malformed in ('not JSON', '{}', '[]', '[{}]', '[{"workflow_runs": null}]',
                                  '[{"workflow_runs": [null]}]',
                                  json.dumps([dict(workflow_runs=[dict(existing, event=None)])]),
                                  json.dumps([dict(workflow_runs=[dict(existing, id='2')])]),
                                  json.dumps([dict(workflow_runs=[dict(existing, head_repository=None)])]),
                                  json.dumps([dict(workflow_runs=[dict(existing, display_title=None)])]),
                                  json.dumps([*pages, {}])):
                    response = malformed
                    with self.assertRaises(ValueError):
                        auto_land.qualify_main()
                    self.assertEqual(dispatches, [])

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
            fail_dispatch = set()

            def dispatch(*args):
                workflow = args[2]
                if workflow in fail_dispatch:
                    raise subprocess.CalledProcessError(1, ['gh', *args], stderr='injected before submit')
                sha = git('rev-parse', 'origin/main')
                dispatches.append((sha, args))
                title = 'Previous installed-release upgrade'
                if workflow == 'check.yml':
                    base_arg = next(arg[5:] for arg in args if arg.startswith('base='))
                    title = 'Stable qualification from base ' + base_arg
                runs[(workflow, sha, 'main')] = dict(green, event='workflow_dispatch', status='queued',
                    conclusion=None, macos=None, display_title=title)
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
                auto_land.promote_stable()
                self.assertEqual({(sha, args[2]) for sha, args in dispatches},
                                 {(tip, 'check.yml'), (tip, auto_land.UPGRADE)})
                self.assertTrue(all('--ref' in args and 'main' in args for _, args in dispatches))
                # A landed tip is skipped, not pushed again.
                auto_land.main()
                self.assertEqual(refs(), (tip, base))
                auto_land.promote_stable()
                self.assertEqual(refs(), (tip, base))
                # A job stopped after submitting Mac must recover only the absent
                # upgrade. A failed submit propagates; it never retries Mac.
                del runs[(auto_land.UPGRADE, tip, 'main')]
                fail_dispatch.add(auto_land.UPGRADE)
                before = len(dispatches)
                with self.assertRaises(subprocess.CalledProcessError):
                    auto_land.qualify_main()
                self.assertEqual(len(dispatches), before)
                fail_dispatch.clear()
                auto_land.promote_stable()
                self.assertEqual(len(dispatches), before + 1)
                self.assertEqual(dispatches[-1][1][2], auto_land.UPGRADE)
                # Complete loss between main push and dispatch recovers both runs.
                del runs[('check.yml', tip, 'main')]
                del runs[(auto_land.UPGRADE, tip, 'main')]
                before = len(dispatches)
                with mock.patch.object(sys, 'argv', ['auto_land.py', '--promote-stable']):
                    auto_land.main()
                self.assertEqual(len(dispatches), before + 2)
                # Existing queued/offline/running/red/cancelled/skipped runs are
                # not absence, so repeated recovery never retries native tests.
                before = len(dispatches)
                for status, conclusion in (('queued', None), ('in_progress', None),
                                           ('completed', 'failure'), ('completed', 'cancelled'),
                                           ('completed', 'skipped')):
                    for name in ('check.yml', auto_land.UPGRADE):
                        runs[(name, tip, 'main')].update(status=status, conclusion=conclusion)
                    auto_land.promote_stable()
                    auto_land.qualify_main()
                    self.assertEqual(refs(), (tip, base))
                    self.assertEqual(len(dispatches), before)
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
                self.assertEqual(dispatches[-1][1], ('workflow', 'run', auto_land.RELEASE, '--ref', 'main',
                                                     '-f', f'sha={tip}'))

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
                # Only the promoted SHA is released, not the skipped older candidate.
                self.assertEqual(dispatches[-1][1][-1], f'sha={ahead}')
                # Replayed/older completions and repeated promotion are harmless no-ops.
                before = len(dispatches)
                auto_land.promote_stable()
                auto_land.promote_stable()
                self.assertEqual(refs(), (ahead, ahead))
                self.assertEqual(len(dispatches), before, 'an unchanged stable is not released again')
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
                before = len(dispatches)
                auto_land.qualify_main()
                auto_land.promote_stable()
                self.assertEqual(len(dispatches), before, 'already qualified main is a no-op')

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
                        elif event == 'pull_request' and selection['mac_required']:
                            # test_platform_boundary owns which PR paths run Mac.
                            self.assertEqual(json.loads(outputs['targets']), selection['targets'])
                            self.assertEqual(json.loads(outputs['native_targets']), selection['native_targets'])
                        else:
                            self.assertEqual(json.loads(outputs['targets']), selection['targets'])
                            self.assertEqual(json.loads(outputs['native_targets']), [])
                            self.assertEqual(outputs['native'], 'false')

    def test_auto_land_wiring(self):
        on = workflow('auto-land.yml').split('\npermissions:', 1)[0]
        self.assertIn('workflows: [Selected checks, Previous installed-release upgrade]', on)
        self.assertIn("branches: ['wip/land-*', main]", on)
        self.assertIn('  push:\n    branches: [main]\n', on)
        self.assertIn('auto_land.py', workflow('auto-land.yml'))
        text = workflow('auto-land.yml')
        self.assertNotRegex(text, r'(?m)^concurrency:')
        completion = re.search(r'(?ms)^  completion:\n(.*?)(?=^  [a-z_]+:|\Z)', text)[1]
        land = re.search(r'(?ms)^  land:\n(.*?)(?=^  [a-z_]+:|\Z)', text)[1]
        self.assertNotIn('concurrency:', completion, 'a pending parent must not lock main')
        self.assertIn('actions: read', completion)
        self.assertIn('contents: read', completion)
        self.assertIn('needs: completion', land)
        self.assertIn('group: auto-land\n      cancel-in-progress: false', land)
        condition = re.search(r'(?m)^    if: \$\{\{ (.*) \}\}$', land)[1]

        def eligible(event, result='skipped', ref='refs/heads/main', source='push', repo='o/r'):
            github = SimpleNamespace(event_name=event, ref=ref, repository='o/r', event=SimpleNamespace(
                repository=SimpleNamespace(private=False), workflow_run=SimpleNamespace(
                    event=source, head_repository=SimpleNamespace(full_name=repo))))
            needs = SimpleNamespace(completion=SimpleNamespace(result=result))
            return eval(condition.replace('&&', 'and').replace('||', 'or').replace('!', 'not '),
                        dict(github=github, needs=needs, always=lambda: True,
                             fromJSON=json.loads, contains=lambda rows, row: row in rows))

        self.assertTrue(eligible('workflow_dispatch', 'success'))
        self.assertTrue(eligible('push'), 'a merged PR still wakes stable promotion')
        for result in ('failure', 'cancelled', 'timed_out', 'skipped'):
            self.assertFalse(eligible('workflow_dispatch', result))
            self.assertTrue(eligible('workflow_run', result), 'normal Linux landing remains independent')
        self.assertFalse(eligible('workflow_dispatch', 'success', ref='refs/heads/other'))
        self.assertFalse(eligible('workflow_run', source='pull_request'))
        self.assertFalse(eligible('workflow_run', repo='fork/r'))
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

    def test_completion_wait_executes_the_workflow_with_provenance_and_a_hard_deadline(self):
        job = re.search(r'(?ms)^  completion:\n(.*?)(?=^  [a-z_]+:|\Z)', workflow('auto-land.yml'))[1]
        script = textwrap.dedent(job.split('        run: |\n', 1)[1])
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            (root / 'tests').symlink_to(Path('tests').resolve(), target_is_directory=True)
            (root / 'gh').write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$CALLS"
if [ "$1" = api ]; then cat "$PARENT"; exit; fi
test "$1 $2" = 'run watch' || exit 70
case "$WATCH" in success) exit 0;; failure) exit 9;; timeout) exec sleep 10;; esac
exit 71
''')
            # Execute a real subprocess deadline at a test scale, while pinning
            # the actual workflow's production 120s + 5s kill bound.
            (root / 'timeout').write_text(f'''#!{sys.executable}
import subprocess, sys
assert sys.argv[1:3] == ['--kill-after=5s', '120s'], sys.argv
try:
    raise SystemExit(subprocess.run(sys.argv[3:], timeout=0.5).returncode)
except subprocess.TimeoutExpired:
    raise SystemExit(124)
''')
            for name in ('gh', 'timeout'):
                (root / name).chmod(0o755)
            selected = dict(path='.github/workflows/check.yml', event='workflow_dispatch',
                            head_branch='main', head_repository=dict(full_name='o/r'),
                            display_title='Stable qualification from base ' + 'a' * 40)
            env = dict(os.environ, PATH=f'{root}{os.pathsep}{os.environ["PATH"]}',
                       GITHUB_REPOSITORY='o/r', COMPLETED_RUN='42', PARENT=str(root / 'parent'),
                       CALLS=str(root / 'calls'))
            for mode, code in (('success', 0), ('failure', 9), ('timeout', 124)):
                with self.subTest(mode=mode):
                    (root / 'parent').write_text(json.dumps(selected))
                    (root / 'calls').write_text('')
                    result = subprocess.run(['bash', '-c', script], cwd=root, env=dict(env, WATCH=mode),
                                            capture_output=True, text=True, timeout=15)
                    self.assertEqual(result.returncode, code, result.stderr)
                    self.assertEqual((root / 'calls').read_text().splitlines(), [
                        'api repos/o/r/actions/runs/42', 'run watch 42 --exit-status --repo o/r'])
            for parent in (dict(selected, head_branch='other'), dict(selected, event='pull_request'),
                           dict(selected, head_repository=dict(full_name='fork/r')),
                           dict(selected, path='.github/workflows/other.yml'),
                           dict(selected, display_title='Selected checks')):
                (root / 'parent').write_text(json.dumps(parent))
                (root / 'calls').write_text('')
                result = subprocess.run(['bash', '-c', script], cwd=root, env=dict(env, WATCH='success'),
                                        capture_output=True, text=True, timeout=15)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('run watch', (root / 'calls').read_text())
            (root / 'parent').write_text(json.dumps(dict(selected,
                path='.github/workflows/previous-release-upgrade.yml', display_title='upgrade')))
            result = subprocess.run(['bash', '-c', script], cwd=root, env=dict(env, WATCH='success'),
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_native_completion_explicitly_wakes_the_serialized_writer(self):
        for name, needs in (('check.yml', '[linux, macos, cache_execution]'),
                            ('previous-release-upgrade.yml', 'upgrade')):
            with self.subTest(workflow=name):
                job = re.search(r'(?ms)^  completion:\n(.*?)(?=^  [a-z_]+:|\Z)', workflow(name))
                self.assertIsNotNone(job, 'bot completion cannot rely on workflow_run')
                job = job[1]
                self.assertIn('needs: ' + needs, job)
                self.assertIn("github.event_name == 'workflow_dispatch'", job)
                self.assertIn("github.ref == 'refs/heads/main'", job)
                self.assertIn('always()', job)
                self.assertIn('actions: write', job)
                self.assertIn('contents: read', job)
                self.assertNotIn('contents: write', job)
                self.assertNotIn('concurrency:', job)
                self.assertIn('gh workflow run auto-land.yml --repo "$GITHUB_REPOSITORY" --ref main '
                              '-f completed_run="$GITHUB_RUN_ID"', job)
                if name == 'check.yml':
                    self.assertIn('inputs.stable', job)

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
