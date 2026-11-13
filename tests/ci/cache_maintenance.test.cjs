const assert = require('node:assert/strict');
const {execFileSync} = require('node:child_process');
const {mkdtempSync, readFileSync, readdirSync, rmSync} = require('node:fs');
const {tmpdir} = require('node:os');
const {join} = require('node:path');
const {test} = require('node:test');
const prune = require('../../.github/scripts/prune-caches.cjs');

function cache(id, ref, platform = 'Linux-X64', part = 'all') {
  return {
    id, ref, size_in_bytes: 100,
    created_at: new Date(Date.UTC(2026, 9, 1, 0, id)).toISOString(),
    key: `rui-build-v2-${platform}-0.17.0-${'a'.repeat(64)}-${'b'.repeat(64)}-${id.toString(16).padStart(64, '0')}-${part}`,
  };
}

async function run(caches, faults = {}) {
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

test('prune every PR snapshot and old main snapshots without crossing platform or partition boundaries', async () => {
  const main = 'refs/heads/main', open = 'refs/pull/12/merge', closed = 'refs/pull/13/merge';
  const caches = [
    cache(1, main), cache(2, main), cache(3, main),
    cache(4, open), cache(5, open), cache(6, open, 'macOS-ARM64'),
    cache(7, main, 'Linux-X64', 'execution'), cache(8, main, 'Linux-X64', 'callers'),
    cache(9, main, 'Linux-X64', 'baseline'), cache(10, main, 'macOS-ARM64'),
    cache(11, closed), {...cache(12, closed), key: 'rui-compiler-Linux-X64-0.17.0'},
    {...cache(13, open), key: 'rui-compiler-Linux-X64-0.17.0'},
    cache(14, 'refs/heads/feature'), cache(15, 'refs/pull/13/head'),
    {...cache(16, closed), key: 'other-cache'},
    {...cache(17, open), key: 'rui-actionlint-1.7.7-linux-amd64'},
    cache(18, 'refs/heads/main-other'),
    // Main keeps only its newest compiler per platform, so a Zig repin retires the old one.
    {...cache(19, main), key: 'rui-compiler-macOS-ARM64-0.17.0'},
    {...cache(20, main), key: 'rui-build-v2-lookalike'},
    {...cache(21, main), key: 'rui-compiler-macOS-ARM64-0.17.1'},
  ];
  // Equal timestamps use IDs. Recently accessed old caches still retire.
  caches[0].created_at = caches[1].created_at;
  caches[0].last_accessed_at = '2099-01-01T00:00:00Z';
  const result = await run(caches);
  assert.ifError(result.error);
  assert.deepEqual(result.ids, [3, 7, 8, 9, 10, 14, 15, 16, 18, 20, 21]);
});

test('build layouts share partition groups across repins without crossing parts', async () => {
  const main = 'refs/heads/main';
  const reordered = (id, part, platform = 'Linux-X64') => ({
    ...cache(id, main, platform, part),
    key: `rui-build-v2-${platform}-0.17.1-${'a'.repeat(64)}-${part}.${id.toString(16).padStart(64, '0')}-${'c'.repeat(64)}`,
  });
  const entries = [
    cache(1, main, 'Linux-X64', 'compiled'),
    reordered(2, 'compiled'), reordered(3, 'compiled'),
    reordered(4, 'baseline'), cache(5, main, 'Linux-X64', 'baseline'),
    reordered(6, 'compiled', 'macOS-ARM64'),
    {...reordered(7, 'compiled'), key: reordered(7, 'compiled').key + '-extra'},
    // A part whose name starts with another part's name is its own group.
    cache(8, main, 'Linux-X64', 'compiled-unit'), reordered(9, 'compiled-unit'),
  ];
  const result = await run(entries);
  assert.ifError(result.error);
  assert.deepEqual(result.ids, [3, 5, 6, 7, 9]);
});

test('build restores keep each part apart and seed parts without snapshots from baseline', () => {
  const root = `${__dirname}/../..`;
  const action = readFileSync(`${root}/.github/actions/setup/caches/action.yml`, 'utf8');
  const step = action.match(/- name: Name the build cache keys\n[\s\S]*?\n    - /)[0];
  const script = step.match(/^      run: \|\n((?: {8}.*\n)+)/m)[1].replace(/^ {8}/gm, '');
  const restore = [...action.matchAll(/restore-keys: \|\n((?: {10}.*\n)+)/g)].map(match => match[1]);
  assert.equal(restore.length, 2);
  const order = [...restore[0].matchAll(/build-keys\.outputs\.([a-z-]+)/g)].map(m => m[1]);
  assert.deepEqual(order, ['prefix-deps', 'prefix-part', 'prefix-seed']);
  assert.equal(restore[1], restore[0]);
  // Every part the workflows name, plus setup's default.
  const workflows = `${root}/.github/workflows`;
  const parts = new Set(['all']);
  for (const file of readdirSync(workflows).filter(file => file.endsWith('.yml'))) {
    for (const [, part] of readFileSync(`${workflows}/${file}`, 'utf8').matchAll(/^\s+check-part: (.*?)\s*$/gm)) {
      // The key's '.' terminator is unambiguous only while no part can contain it.
      assert.match(part, /^[a-z][a-z0-9-]*$/, `${file} names check part ${part}`);
      parts.add(part);
    }
  }
  for (const part of ['compiled', 'compiled-unit', 'codegen', 'baseline']) assert.ok(parts.has(part), part);
  const prefix = `rui-build-v2-Linux-X64-0.17.1-${'a'.repeat(64)}-`;
  const [d1, d2, s1, s2] = ['d', 'e', 'b', 'c'].map(c => c.repeat(64));
  // Run the step's own script, as the runner does.
  const keys = (part, deps, sources = s2) => {
    const dir = mkdtempSync(join(tmpdir(), 'rui-keys-'));
    try {
      const output = join(dir, 'output');
      execFileSync('bash', ['-ec', script], {
        env: {PATH: process.env.PATH, PREFIX: prefix, DEPS: deps, SOURCES: sources, CHECK_PART: part, GITHUB_OUTPUT: output},
      });
      return Object.fromEntries(readFileSync(output, 'utf8').trimEnd().split('\n').map(line => line.split(/=(.*)/s).slice(0, 2)));
    } finally { rmSync(dir, {recursive: true, force: true}); }
  };
  // actions/cache: an exact key, else the newest key matching the first restore
  // prefix that matches anything; empty restore keys are dropped.
  const restored = (part, deps, existing) => {
    const named = keys(part, deps);
    const prefixes = order.map(output => named[output]).filter(key => key !== '');
    assert.equal(new Set(prefixes).size, prefixes.length, `${part} repeats a restore key`);
    if (existing.includes(named.key)) return named.key;
    for (const restorePrefix of prefixes) {
      const match = existing.filter(key => key.startsWith(restorePrefix));
      if (match.length) return match[match.length - 1];
    }
    return null;
  };
  const key = (part, deps, sources = s1) => keys(part, deps, sources).key;
  // Existing snapshots, oldest first.
  const existing = [key('compiled', d1), key('codegen', d1), key('baseline', d1), key('baseline', d2), key('compiled-unit', d2), key('all', d2)];
  // A part main never saves starts from baseline at the current dependencies.
  assert.equal(restored('codegen', d2, existing.filter(k => !k.includes('codegen.'))), key('baseline', d2));
  // After a repin a part prefers its own older snapshot to the newer baseline,
  // and never another part whose name it starts (compiled-unit).
  assert.equal(restored('compiled', d2, existing), key('compiled', d1));
  assert.equal(restored('compiled-unit', d1, existing), key('compiled-unit', d2));
  assert.equal(restored('baseline', d2, existing), key('baseline', d2));
  assert.equal(restored('cache-execution', d1, existing), key('baseline', d1));
  for (const own of parts) {
    const named = keys(own, d1);
    for (const other of parts) {
      for (const deps of [d1, d2]) {
        const snapshot = key(other, deps);
        const reached = order.filter(output => named[output] !== '' && snapshot.startsWith(named[output]));
        if (own === other) assert.deepEqual(reached, deps === d1 ? ['prefix-deps', 'prefix-part'] : ['prefix-part']);
        else if (other === 'baseline' && deps === d1) assert.deepEqual(reached, ['prefix-seed'], `${own} seeds from baseline`);
        else assert.deepEqual(reached, [], `${own} restores ${other}: ${snapshot}`);
      }
    }
  }
});

test('main keeps the newest build runner per CPU model and the newest package set', async () => {
  const main = 'refs/heads/main';
  const runner = (id, platform, cpu, ref = main) => ({
    ...cache(id, ref), key: `rui-runner-v2-${platform}-0.17.0-${'a'.repeat(64)}-${cpu.repeat(16)}-${id.toString(16).padStart(64, '0')}`,
  });
  const packages = id => ({...cache(id, main), key: `rui-packages-v1-${id.toString(16).padStart(64, '0')}`});
  const caches = [
    runner(1, 'Linux-X64', 'b'), runner(2, 'Linux-X64', 'b'), runner(3, 'Linux-X64', 'c'),
    runner(4, 'macOS-ARM64', 'b'), runner(5, 'Linux-X64', 'b', 'refs/pull/12/merge'),
    packages(6), packages(7),
    {...runner(8, 'Linux-X64', 'd'), key: runner(8, 'Linux-X64', 'd').key.replace('0.17.0', '0.17.1')},
  ];
  const result = await run(caches);
  assert.ifError(result.error);
  assert.deepEqual(result.ids, [2, 3, 4, 7, 8]);
});

test('an unreadable inventory deletes nothing', async () => {
  const caches = Array.from({length: 101}, (_, i) => cache(i + 1, 'refs/pull/1/merge'));
  const result = await run(caches, {inventory: true});
  assert.ok(result.error);
  assert.equal(result.ids.length, 101);
  const pruned = await run(caches);
  assert.ifError(pruned.error);
  assert.deepEqual(pruned.ids, []);
});

test('current compiler and named main shard caches retain independent snapshots', async () => {
  const main = 'refs/heads/main';
  const entries = [
    cache(1, main, 'Linux-X64', 'test-full'),
    cache(2, main, 'Linux-X64', 'test-full'),
    cache(3, main, 'Linux-X64', 'full-callers'),
    cache(4, main, 'macOS-ARM64', 'codex-h2-integration'),
    {...cache(5, main), key: 'rui-compiler-Linux-X64-0.17.1'},
    cache(6, 'refs/heads/feature', 'Linux-X64', 'test-full'),
  ].map(entry => ({...entry, key: entry.key.replace('0.17.0', '0.17.1')}));
  const result = await run(entries);
  assert.ifError(result.error);
  assert.deepEqual(result.ids, [2, 3, 4, 5, 6]);
});

test('only already-absent deletion is recoverable', async () => {
  const caches = [cache(1, 'refs/pull/1/merge'), cache(2, 'refs/pull/1/merge')];
  const missing = await run(caches, {deletion: 404});
  assert.ifError(missing.error);
  assert.deepEqual(missing.ids, []);
  const denied = await run(caches, {deletion: 403});
  assert.equal(denied.error.status, 403);
  assert.deepEqual(denied.ids, [1, 2]);
});

test('cleanup follows every cache producer, including failed workflows with successful jobs', () => {
  const directory = `${__dirname}/../../.github/workflows`;
  const workflow = readFileSync(`${directory}/cache-maintenance.yml`, 'utf8');
  // Inspect the owning dependency and event declarations. Actionlint validates
  // complete YAML/Actions syntax; these assertions guard lifecycle ordering.
  const jobs = Object.fromEntries([...workflow.matchAll(/^  (\w+):\n((?: {4}[^\n]*\n|\n)+)/gm)]
    .map(([, name, body]) => [name, body]));
  assert.match(jobs.prune, /^    needs: \[baseline, runner\]\s*$/m,
    'prune must wait for baseline and runner post-job cache saves');
  assert.match(jobs.prune, /^    if:.*always\(\)/m,
    'successful matrix peers may save even if another peer fails');
  assert.doesNotMatch(jobs.prune, /needs\.baseline\.result|workflow_run\.conclusion/);
  assert.match(jobs.baseline, /github\.event_name != 'workflow_run'/,
    'completion events must not launch another baseline');
  assert.match(jobs.workflow_run, /types: \[completed\]/);
  for (const file of readdirSync(directory).filter(file => file.endsWith('.yml') && file !== 'cache-maintenance.yml')) {
    const producer = readFileSync(`${directory}/${file}`, 'utf8');
    if (!/uses: (?:\.\/\.github\/actions\/setup|actions\/cache(?:\/save)?@)/.test(producer)) continue;
    if (/^cache-mode: read$/m.test(producer) && producer.match(/^\s*cache-mode:/gm).length === 1) continue;
    const name = producer.match(/^name: (.+)$/m)[1];
    assert.ok(jobs.workflow_run.includes(name), `${file} needs post-publication cleanup`);
  }
  assert.match(jobs.prune, /ref: \$\{\{ github\.sha \}\}/);
  assert.doesNotMatch(jobs.prune, /workflow_run\.head_|actions\/download-artifact|actions\/cache|uses: \.\/\.github\/actions\/setup/,
    'privileged cleanup must use default-branch code, not producer code or caches');
});

test('post-publication cleanup retains new saves and reconciles later concurrent saves', async () => {
  // Exact hits publish nothing; fallback hits and cold builds publish new keys.
  // A failed matrix peer does not undo another peer's successful post-job save.
  for (const [ref, platform, part, limit] of [
    ['refs/heads/main', 'Linux-X64', 'baseline', 1],
    ['refs/heads/main', 'macOS-ARM64', 'baseline', 1],
    ['refs/heads/main', 'macOS-ARM64', 'all', 1],
  ]) {
    const original = Array.from({length: limit}, (_, i) => cache(i + 1, ref, platform, part));
    for (const saved of [false, true]) {
      const published = saved ? [...original, cache(10, ref, platform, part)] : original;
      const result = await run(published);
      assert.ifError(result.error);
      assert.deepEqual(result.ids, saved ? [10] : original.map(c => c.id));
      // Publication after this inventory temporarily exceeds the target. Its
      // own completion requests another cleanup; this is not an atomic quota.
      const later = [...published.filter(c => result.ids.includes(c.id)), cache(20, ref, platform, part)];
      const reconciled = await run(later);
      assert.ifError(reconciled.error);
      assert.deepEqual(reconciled.ids, [20]);
    }
  }
});
