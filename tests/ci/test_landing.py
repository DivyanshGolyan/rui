"""Landing-rule wiring: strict paths, post-push decisions and CI triggers."""
from pathlib import Path
import re
import unittest

from main_health import decide
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
