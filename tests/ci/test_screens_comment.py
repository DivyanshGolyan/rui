import unittest

import screens_comment as comment


def record(name, ok=True, reason=None):
    return {'ok': ok, 'reason': reason, 'files': {'png': name}}


def pair(name, size, before=None, after=None):
    return {'name': name, 'size': size, 'before': before, 'after': after}


def diff(**overrides):
    return {'changed': [], 'new': [], 'removed': [], 'failed': [], 'same_count': 0, **overrides}


class RenderTest(unittest.TestCase):
    def test_comparison_groups_sizes_escapes_and_orders_failures(self):
        old = record('baseline/old screen.png')
        new = record('new.png')
        failed = record('last.png', False, 'bad | frame\n<oops>')
        data = diff(changed=[pair('view | <main>', '140x40', old, new),
                             pair('view | <main>', '46x30', old, new)],
                    new=[pair('new', '46x30', None, new)],
                    failed=[pair('broken', '140x40', old, failed)],
                    removed=[pair('old', '46x30', old, None)], same_count=4)
        body = comment.render(data, 'owner/repo', 42, 'headsha', 'basesha')
        self.assertIn('2 changed, 1 new, 4 unchanged, 1 failed', body)
        self.assertIn('Head: `headsha`', body)
        self.assertIn('Base: `basesha`', body)
        self.assertLess(body.index('### Failures'), body.index('### Changed and new screens'))
        self.assertIn('bad &#124; frame &lt;oops&gt;', body)
        self.assertIn('view &#124; &lt;main&gt;', body)
        self.assertIn('https://raw.githubusercontent.com/owner/repo/pr-screens/pr-42/headsha/baseline/old%20screen.png', body)
        self.assertIn('![Last frame]', body)
        self.assertIn('| new | — | — / ![After]', body)
        self.assertIn('old (46x30)', body)
        self.assertIn('<summary>4 unchanged captures</summary>', body)

    def test_run_level_failure_shows_first_reason_and_artifact_link(self):
        failures = [{'side': 'candidate', 'shard': 2, 'reason': 'verify-rui: Host aborted | bad\nmore detail'}]
        body = comment.render(diff(), 'o/r', 7, 'head', 'base', capture_failures=failures, run_id=42)
        self.assertIn('0 changed, 0 new, 0 unchanged, 1 failed', body)
        self.assertIn('candidate shard 2', body)
        self.assertIn('capture failed: Host aborted &#124; bad', body)
        self.assertNotIn('more detail', body)
        self.assertIn('https://github.com/o/r/actions/runs/42', body)

    def test_unchanged_other_size_uses_shot_manifests(self):
        def capture(name, size, filename):
            return {'name': name, 'size': size, **record(filename)}
        data = diff(changed=[pair('screen', '140x40', record('baseline/old.png'), record('new.png'))],
                    same_count=2)
        shots = [capture('screen', '46x30', 'screen-small.png'),
                 capture('unrelated', '46x30', 'other.png')]
        baseline = [capture('screen', '46x30', 'screen-small.png')]
        body = comment.render(data, 'o/r', 7, 'head', 'base', shots, baseline)
        self.assertIn('1 changed, 0 new, 2 unchanged, 0 failed', body)
        self.assertIn('/head/baseline/screen-small.png', body)
        self.assertIn('/head/screen-small.png', body)
        self.assertNotIn('other.png', body)
        self.assertIn('/head/baseline/old.png', body)

    def test_manifest_missing_side_remains_empty(self):
        data = diff(new=[pair('screen', '140x40', None, record('large.png'))])
        shots = [{'name': 'screen', 'size': '46x30', **record('small.png')}]
        body = comment.render(data, 'o/r', 7, 'head', 'base', shots, [])
        self.assertIn('— / ![After](https://raw.githubusercontent.com/o/r/pr-screens/pr-7/head/small.png)', body)

    def test_missing_images_are_handled(self):
        body = comment.render(diff(failed=[pair('failed', '46x30', None,
                                               {'ok': False, 'reason': None, 'files': {}})]),
                              'o/r', 1, 'head', 'base')
        self.assertIn('Capture failed', body)
        self.assertIn('  —', body)

    def test_large_table_is_bounded_and_marked(self):
        rows = [pair(f'state-{i}', '140x40', record('a.png'), record('b.png')) for i in range(1000)]
        body = comment.render(diff(changed=rows), 'owner/repo', 1, 'h', 'b')
        self.assertLess(len(body), 65000)
        self.assertIn('Comment truncated', body)
        self.assertIn('| state-', body)
        self.assertNotIn('| state-999 |', body)


class UpsertTest(unittest.TestCase):
    def test_paginates_and_updates_existing_comment(self):
        calls = []
        def api(method, path, body=None):
            calls.append((method, path, body))
            if '/pulls/' in path:
                return {'state': 'open', 'head': {'sha': 'head'}}
            if method == 'GET' and path.endswith('&page=1'):
                return [{'id': i, 'body': 'other'} for i in range(100)]
            if method == 'GET':
                return [{'id': 100, 'body': comment.MARKER, 'user': {'login': 'attacker'}},
                        {'id': 101, 'body': comment.MARKER, 'user': {'login': 'github-actions[bot]'}}]
            return {'id': 101}
        self.assertEqual(comment.upsert(api, 'o/r', 7, 'head', 'new'), {'id': 101})
        self.assertEqual(calls[-1], ('PATCH', 'repos/o/r/issues/comments/101', {'body': 'new'}))
        self.assertIn('page=2', calls[1][1])
        self.assertNotIn('user', [path for _, path, _ in calls])

    def test_creates_when_no_comment_exists(self):
        calls = []
        def api(method, path, body=None):
            calls.append((method, path, body))
            if '/pulls/' in path:
                return {'state': 'open', 'head': {'sha': 'head'}}
            return [] if method == 'GET' else {'id': 4}
        comment.upsert(api, 'o/r', 7, 'head', 'new')
        self.assertEqual(calls[-1], ('POST', 'repos/o/r/issues/7/comments', {'body': 'new'}))

    def test_refuses_stale_or_closed_pr(self):
        for state, sha in [('closed', 'head'), ('open', 'new-head')]:
            with self.subTest(state=state, sha=sha):
                def api(method, path, body=None):
                    if '/pulls/' in path:
                        return {'state': state, 'head': {'sha': sha}}
                    self.assertEqual(method, 'GET')
                    return []
                with self.assertRaises(ValueError):
                    comment.upsert(api, 'o/r', 7, 'head', 'new')

    def test_both_failed_sides_show_their_own_last_frames(self):
        before = record('baseline/failed.png', False, 'before failed')
        after = record('failed.png', False, 'after failed')
        body = comment.render(diff(failed=[pair('bad', '140x40', before, after)]),
                              'o/r', 7, 'head', 'base')
        self.assertIn('before failed', body)
        self.assertIn('after failed', body)
        self.assertIn('/baseline/failed.png', body)
        self.assertIn('/head/failed.png', body)


if __name__ == '__main__':
    unittest.main()
