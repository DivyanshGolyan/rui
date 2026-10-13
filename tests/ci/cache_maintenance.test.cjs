const assert = require('node:assert/strict');
const {test} = require('node:test');
const prune = require('../../.github/scripts/prune-caches.cjs');

function cache(id, ref, platform = 'Linux-X64', part = 'all') {
  return {
    id, ref, size_in_bytes: 100,
    created_at: new Date(Date.UTC(2026, 9, 1, 0, id)).toISOString(),
    key: `rui-build-v2-${platform}-0.16.0-${'a'.repeat(64)}-${'b'.repeat(64)}-${id.toString(16).padStart(64, '0')}-${part}`,
  };
}

async function run(caches, states, faults = {}) {
  const remaining = new Map(caches.map(c => [c.id, c]));
  let error;
  try {
    await prune({
      context: {repo: {owner: 'test', repo: 'rui'}}, core: {info() {}},
      github: {
        // Model the SDK's paginated inventory, including candidates after page 1.
        paginate: async () => {
          if (faults.inventory) throw new Error('Inventory unavailable');
          return [caches.slice(0, 100), caches.slice(100)].flat();
        },
        rest: {
          pulls: {get: async ({pull_number}) => {
            if (!(pull_number in states)) throw Object.assign(new Error('PR unavailable'), {status: 404});
            return {data: {state: states[pull_number]}};
          }},
          actions: {
            getActionsCacheList() {},
            deleteActionsCacheById: async ({cache_id}) => {
              if (faults.deletion === 404) remaining.delete(cache_id);
              if (faults.deletion) throw Object.assign(new Error('Delete failed'), {status: faults.deletion});
              remaining.delete(cache_id);
            },
          },
        },
      },
    });
  } catch (failure) { error = failure; }
  return {ids: [...remaining.keys()].sort((a, b) => a - b), error};
}

test('prune closed PRs and old snapshots without crossing ref, platform or partition boundaries', async () => {
  const main = 'refs/heads/main', open = 'refs/pull/12/merge', closed = 'refs/pull/13/merge';
  const caches = [
    cache(1, main), cache(2, main), cache(3, main),
    cache(4, open), cache(5, open), cache(6, open, 'macOS-ARM64'),
    cache(7, open, 'Linux-X64', 'execution'), cache(8, open, 'Linux-X64', 'callers'),
    cache(9, main, 'Linux-X64', 'baseline'), cache(10, main, 'macOS-ARM64'),
    cache(11, closed), {...cache(12, closed), key: 'rui-compiler-Linux-X64-0.16.0'},
    {...cache(13, open), key: 'rui-compiler-Linux-X64-0.16.0'},
    cache(14, 'refs/heads/feature'), cache(15, 'refs/pull/13/head'),
    {...cache(16, closed), key: 'other-cache'},
    {...cache(17, closed), key: 'rui-build-v2-lookalike'},
    cache(18, 'refs/heads/main-other'),
    {...cache(19, main), key: 'rui-compiler-macOS-ARM64-0.16.0'},
  ];
  // Equal timestamps use IDs. Recently accessed old caches still retire.
  caches[0].created_at = caches[1].created_at;
  caches[0].last_accessed_at = '2099-01-01T00:00:00Z';
  const result = await run(caches, {12: 'open', 13: 'closed'});
  assert.ifError(result.error);
  assert.deepEqual(result.ids, [2, 3, 5, 6, 7, 8, 9, 10, 13, 14, 15, 16, 17, 18, 19]);
});

test('a late read failure cannot leave an earlier closed PR partially pruned', async () => {
  const caches = Array.from({length: 101}, (_, i) => cache(i + 1, 'refs/pull/1/merge'));
  caches.push(cache(102, 'refs/pull/2/merge'));
  for (const [states, faults] of [[{1: 'closed'}, {}], [{1: 'closed', 2: 'unknown'}, {}], [{}, {inventory: true}]]) {
    const result = await run(caches, states, faults);
    assert.ok(result.error);
    assert.equal(result.ids.length, 102);
  }
  const result = await run(caches, {1: 'closed', 2: 'closed'});
  assert.ifError(result.error);
  assert.deepEqual(result.ids, []);
});

test('only already-absent deletion is recoverable', async () => {
  const caches = [cache(1, 'refs/pull/1/merge'), cache(2, 'refs/pull/1/merge')];
  const missing = await run(caches, {1: 'closed'}, {deletion: 404});
  assert.ifError(missing.error);
  assert.deepEqual(missing.ids, []);
  const denied = await run(caches, {1: 'closed'}, {deletion: 403});
  assert.equal(denied.error.status, 403);
  assert.deepEqual(denied.ids, [1, 2]);
});
