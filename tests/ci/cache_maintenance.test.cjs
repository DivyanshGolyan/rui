const assert = require('node:assert/strict');
const {execFileSync} = require('node:child_process');
const {existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync} = require('node:fs');
const {tmpdir} = require('node:os');
const {join} = require('node:path');
const {test} = require('node:test');
const prune = require('../../.github/scripts/prune-caches.cjs');
const {publicationKeys, saveKey} = require('../../.github/actions/setup/caches/save-keys.cjs');

function cache(id, ref, platform = 'Linux-X64', part = 'all') {
  return {
    id, ref, size_in_bytes: 100,
    created_at: new Date(Date.UTC(2026, 9, 1, 0, id)).toISOString(),
    key: `rui-build-v2-${platform}-0.17.0-${'a'.repeat(64)}-${part}.${id.toString(16).padStart(64, '0')}-${'b'.repeat(64)}`,
  };
}

async function run(caches, faults = {}) {
  const remaining = new Map(caches.map(c => [c.id, c]));
  let error;
  const logs = [];
  try {
    await prune({
      context: {repo: {owner: 'test', repo: 'rui'}}, core: {info(message) { logs.push(message); }},
      github: {
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
  return {ids: [...remaining.keys()].sort((a, b) => a - b), error, logs};
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
    {...cache(19, main), key: 'rui-compiler-macOS-ARM64-0.17.0'},
    {...cache(20, main), key: 'rui-build-v2-lookalike'},
    {...cache(21, main), key: 'rui-compiler-macOS-ARM64-0.17.1'},
  ];
  caches[0].created_at = caches[1].created_at;
  caches[0].last_accessed_at = '2099-01-01T00:00:00Z';
  const result = await run(caches);
  assert.ifError(result.error);
  assert.deepEqual(result.ids, [3, 7, 8, 9, 10, 14, 15, 16, 18, 20, 21]);
});

test('maintenance attributes deleted snapshots and reports retained group bytes', async () => {
  const main = 'refs/heads/main';
  const old = {...cache(1, main), version: 'old-format'};
  const newest = {...cache(2, main), size_in_bytes: 6400};
  const compiler = {...cache(3, main), key: 'rui-compiler-Linux-X64-0.17.1', size_in_bytes: 86};
  const result = await run([old, newest, compiler]);
  assert.ifError(result.error);
  assert.deepEqual(result.ids, [2, 3]);
  assert.equal(result.logs[0], 'Retained main cache bytes by group: {"compiler/Linux-X64":86,"build/Linux-X64/all":6400}');
  assert.ok(result.logs.some(line => line.includes(`key=${old.key}, version=old-format`)));
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
    cache(8, main, 'Linux-X64', 'compiled-unit'), reordered(9, 'compiled-unit'),
  ];
  const result = await run(entries);
  assert.ifError(result.error);
  assert.deepEqual(result.ids, [3, 5, 6, 7, 9]);
});

function buildKeyPolicy() {
  const action = readFileSync(`${__dirname}/../../.github/actions/setup/caches/action.yml`, 'utf8');
  const step = action.match(/- name: Name the build cache keys\n[\s\S]*?\n    - /)[0];
  const script = step.match(/^      run: \|\n((?: {8}.*\n)+)/m)[1].replace(/^ {8}/gm, '');
  const restore = [...action.matchAll(/restore-keys: \|\n((?: {10}.*\n)+)/g)].map(match => match[1]);
  assert.equal(restore.length, 1);
  const order = [...restore[0].matchAll(/build-keys\.outputs\.([a-z-]+)/g)].map(m => m[1]);
  const keys = (part, deps, sources, platform = 'Linux-X64') => {
    const [os, arch] = platform.split('-');
    const expressions = {'runner.os': os, 'runner.arch': arch, 'steps.tools.outputs.identity': 'a'.repeat(64)};
    const prefix = step.match(/^        PREFIX: (.*)$/m)[1].replace(/\$\{\{ (.*?) \}\}/g, (_, name) => {
      assert.ok(Object.hasOwn(expressions, name), `unknown prefix input ${name}`);
      return expressions[name];
    });
    const dir = mkdtempSync(join(tmpdir(), 'rui-keys-'));
    try {
      const output = join(dir, 'output');
      execFileSync('bash', ['-ec', script], {
        env: {PATH: process.env.PATH, PREFIX: prefix, DEPS: deps, SOURCES: sources, CHECK_PART: part, GITHUB_OUTPUT: output},
      });
      return Object.fromEntries(readFileSync(output, 'utf8').trimEnd().split('\n').map(line => line.split(/=(.*)/s).slice(0, 2)));
    } finally { rmSync(dir, {recursive: true, force: true}); }
  };
  return {keys, order, step};
}

test('build restores keep each part apart and seed parts without snapshots from baseline', () => {
  const root = `${__dirname}/../..`;
  const {keys: nameKeys, order} = buildKeyPolicy();
  assert.deepEqual(order, ['prefix-deps', 'prefix-part', 'prefix-seed']);
  const workflows = `${root}/.github/workflows`;
  const parts = new Set(['all']);
  for (const file of readdirSync(workflows).filter(file => file.endsWith('.yml'))) {
    for (const [, part] of readFileSync(`${workflows}/${file}`, 'utf8').matchAll(/^\s+(?:check|cache)-part: (.*?)\s*$/gm)) {
      if (part === '${{ matrix.part }}') {
        const matrix = readFileSync(`${workflows}/${file}`, 'utf8').match(/^        part: \[(.*?)\]/m);
        assert.ok(matrix, `${file} must enumerate its cache parts`);
        for (const value of matrix[1].split(', ')) {
          assert.match(value, /^[a-z][a-z0-9-]*$/);
          parts.add(value);
        }
        continue;
      }
      assert.match(part, /^[a-z][a-z0-9-]*$/, `${file} names check part ${part}`);
      parts.add(part);
    }
  }
  for (const part of ['compiled', 'compiled-unit', 'baseline']) assert.ok(parts.has(part), part);
  // The single PR job restores the snapshot main's Linux producer publishes, never an
  // `all` namespace nobody writes.
  const check = readFileSync(`${workflows}/check.yml`, 'utf8');
  const job = name => check.match(new RegExp(`^  ${name}:\\n([\\s\\S]*?)(?=^  [a-z_]+:\\n|$(?![\\s\\S]))`, 'm'))[1];
  const setupOf = body => body.match(/- uses: \.\/\.github\/actions\/setup\n(?: {8,}.*\n)+/)[0];
  const prSetup = setupOf(job('pr_linux'));
  const prPart = (prSetup.match(/^ +cache-part: (.*)$/m) || prSetup.match(/^ +check-part: (.*)$/m) || [, 'all'])[1];
  const producer = setupOf(job('linux_build'));
  assert.match(producer, /^ +check-part: compiled$/m);
  assert.match(producer, /^ +publish-caches: \$\{\{ github\.ref == 'refs\/heads\/main' && /m);
  const v2 = `rui-build-v2-Linux-X64-0.17.1-${'a'.repeat(64)}-`;
  const prKeys = nameKeys(prPart, 'd'.repeat(64), 'b'.repeat(64));
  assert.deepEqual(order.map(output => prKeys[output]).filter(key => key !== ''), [
    `rui-build-v4-Linux-X64-0.17.1-${'a'.repeat(64)}-compiled.${'d'.repeat(64)}-`,
    `rui-build-v4-Linux-X64-0.17.1-${'a'.repeat(64)}-compiled.`,
    `${v2}baseline.${'d'.repeat(64)}-`,
  ], 'linux pr restores main\'s compiled producer snapshot');
  assert.match(prSetup, /^ +publish-caches: 'false'$/m);
  const setupAction = readFileSync(`${root}/.github/actions/setup/action.yml`, 'utf8');
  assert.match(setupAction, /- uses: \.\/\.github\/actions\/setup\/caches\n +id: caches\n +with:\n +check-part: \$\{\{ inputs\.cache-part \|\| inputs\.check-part \}\}\n/,
               'setup restores cache-part when a job names one');
  // CI-32: exercise the actual setup guard across cache and setup states.
  const cacheAction = readFileSync(`${root}/.github/actions/setup/caches/action.yml`, 'utf8');
  assert.match(cacheAction, /packages-hit:\n +description: [^\n]+\n +value: \$\{\{ steps\.packages-cache\.outputs\.cache-hit \}\}/);
  assert.match(cacheAction, /id: packages-cache\n[\s\S]*?path: zig-pkg\n +key: rui-packages-v1-\$\{\{ hashFiles\('build\.zig\.zon'\) \}\}\n +restore-keys: rui-packages-v1-/);
  const guard = setupAction.match(/- name: Fetch the existing pinned dependency graph\n +if: \$\{\{ (.*?) \}\}/)[1];
  const decideFetch = values => {
    const expression = guard.replace(/inputs\.(?:compiled|cold)|steps\.caches\.outputs\.(?:packages-hit|build-hit)/g, name => {
      assert.ok(Object.hasOwn(values, name), `unknown guard input ${name}`);
      return JSON.stringify(values[name]);
    });
    assert.match(expression, /^[\s\w'"!=&|().-]+$/);
    return Function(`return (${expression})`)();
  };
  for (const compiled of ['true', 'false']) {
    for (const cold of ['true', 'false']) {
      for (const buildHit of ['true', 'false', '']) {
        for (const packagesHit of ['true', 'false', '']) {
          const values = {'inputs.compiled': compiled, 'inputs.cold': cold,
            'steps.caches.outputs.build-hit': buildHit, 'steps.caches.outputs.packages-hit': packagesHit};
          assert.equal(decideFetch(values), compiled !== 'true' && (cold === 'true' || packagesHit !== 'true'),
            JSON.stringify(values));
        }
      }
    }
  }
  const [d1, d2, s1, s2] = ['d', 'e', 'b', 'c'].map(c => c.repeat(64));
  const keys = (part, deps, sources = s2) => nameKeys(part, deps, sources);
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
  const existing = [key('compiled', d1), key('codegen', d1), key('baseline', d1), key('baseline', d2), key('compiled-unit', d2), key('all', d2)];
  assert.equal(restored('codegen', d2, existing.filter(k => !k.includes('codegen.'))), key('baseline', d2));
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
  // Every key above starts with setup's native tool identity. Linux runner
  // images that differ only in Ubuntu package revisions (glibc 2.39-0ubuntu8.9
  // and 8.12 split the fleet on 18 Nov 2026) name one identity, so they share
  // snapshots; a different perl or glibc version is a different identity.
  if (!existsSync('/etc/os-release')) return;
  const action = readFileSync(`${root}/.github/actions/setup/caches/action.yml`, 'utf8');
  const tools = action.match(/- name: Identify the actual native build tools\n[\s\S]*?^      run: \|\n((?: {8}.*\n|\n)+)/m)[1].replace(/^ {8}/gm, '');
  const identity = image => {
    const dir = mkdtempSync(join(tmpdir(), 'rui-tools-'));
    try {
      const stub = (name, text) => writeFileSync(join(dir, name), `#!/bin/sh\nprintf '%s\\n' '${text}'\n`, {mode: 0o755});
      stub('cc', `gcc (Ubuntu 13.3.0-${image.gcc}) 13.3.0`);
      stub('ldd', `ldd (Ubuntu GLIBC 2.39-${image.glibcPackage}) 2.39`);
      stub('ld', `GNU ld (GNU Binutils for Ubuntu) 2.42-${image.binutils}`);
      stub('getconf', `glibc ${image.glibc}`);
      stub('perl', `perl ${image.perl}`);
      const output = join(dir, 'output');
      execFileSync('bash', ['-ec', tools], {env: {PATH: `${dir}:${process.env.PATH}`, RUNNER_TEMP: dir, GITHUB_OUTPUT: output}, stdio: ['ignore', 'ignore', 'inherit']});
      return readFileSync(output, 'utf8').match(/^identity=([a-f0-9]{64})$/m)[1];
    } finally { rmSync(dir, {recursive: true, force: true}); }
  };
  const image = {gcc: '6ubuntu2~24.04', glibcPackage: '0ubuntu8.9', binutils: '4ubuntu2.5', glibc: '2.39', perl: 'v5.38.2'};
  const base = identity(image);
  for (const [change, same] of [
    [{glibcPackage: '0ubuntu8.12'}, true], [{gcc: '6ubuntu2~24.04.1'}, true], [{binutils: '4ubuntu2.6'}, true],
    [{glibcPackage: '0ubuntu8.12', gcc: '6ubuntu2~24.04.1', binutils: '4ubuntu2.6'}, true],
    [{perl: 'v5.40.0'}, false], [{glibc: '2.41'}, false],
  ]) assert.equal(identity({...image, ...change}) === base, same, JSON.stringify(change));
});

test('compiled restores its v4 snapshot, then seeds from the v2 baseline', () => {
  const {keys, order, step} = buildKeyPolicy();
  const [deps, sources, otherDeps] = ['b', 'c', 'd'].map(c => c.repeat(64));
  assert.match(step, /SOURCES: \$\{\{ hashFiles\('build.zig', 'build\/\*\*', 'src\/\*\*', 'tests\/integration\/\*\*'\) \}\}/);
  const v2 = `rui-build-v2-Linux-X64-0.17.1-${'a'.repeat(64)}-`;
  const v4 = v2.replace('-v2-', '-v4-');
  const named = keys('compiled', deps, sources);
  assert.equal(named.key, `${v4}compiled.${deps}-${sources}`);
  const prefixes = order.map(field => named[field]);
  assert.deepEqual(prefixes, [`${v4}compiled.${deps}-`, `${v4}compiled.`, `${v2}baseline.${deps}-`]);
  const restore = existing => {
    if (existing.includes(named.key)) return {key: named.key, exact: true};
    for (const prefix of prefixes) {
      const matched = existing.filter(key => key.startsWith(prefix));
      if (matched.length) return {key: matched[matched.length - 1], exact: false};
    }
    return {key: null, exact: false};
  };
  const ordered = [
    `${v4}compiled.${deps}-${'e'.repeat(64)}`,
    `${v4}compiled.${otherDeps}-${sources}`,
    `${v2}baseline.${deps}-${sources}`,
  ];
  for (let i = 0; i < ordered.length; i++) {
    assert.deepEqual(restore(ordered.slice(i)), {key: ordered[i], exact: false}, `restore priority ${i}`);
  }
  assert.deepEqual(restore([...ordered, named.key]), {key: named.key, exact: true});
  for (const retired of [`${v2}compiled.${deps}-${sources}`, `${v2.replace('-v2-', '-v3-')}compiled.${deps}-${sources}`]) {
    assert.deepEqual(restore([retired]), {key: null, exact: false}, `${retired} is never restored`);
  }
  const partial = saveKey({kind: 'build', key: named.key, setupOutcome: 'success', workOutcome: 'failure', runId: '1', runAttempt: '1'});
  assert.deepEqual(restore([partial]), {key: partial, exact: false});
  assert.equal(saveKey({kind: 'build', key: named.key, setupOutcome: 'success', workOutcome: 'success'}), named.key);
  for (const platform of ['Linux-X64', 'Linux-ARM64', 'macOS-ARM64', 'Windows-X64']) {
    for (const part of ['all', 'compiled', 'compiled-unit', 'compiled-other', 'codegen', 'baseline']) {
      if (platform === 'Linux-X64' && part === 'compiled') continue;
      const ordinary = keys(part, deps, sources, platform);
      // macOS compiled publishes under v3 so its combined build never exact-hits the rest-only v2 snapshot.
      const version = platform === 'macOS-ARM64' && part === 'compiled' ? 'v3' : 'v2';
      const prefix = `rui-build-${version}-${platform}-0.17.1-${'a'.repeat(64)}-`;
      assert.equal(ordinary.key, `${prefix}${part}.${deps}-${sources}`);
      const restoreKeys = order.map(field => ordinary[field]).filter(Boolean);
      assert.equal(new Set(restoreKeys).size, restoreKeys.length, `${platform}/${part} duplicates fallbacks`);
    }
  }
});

function compiledSnapshot(id, partial = false, tools = 'a') {
  const entry = cache(id, 'refs/heads/main', 'Linux-X64', 'compiled');
  entry.key = `rui-build-v4-Linux-X64-0.17.1-${tools.repeat(64)}-compiled.${'b'.repeat(64)}-${id.toString(16).padStart(64, '0')}`;
  if (partial) entry.key += '-partial-123-1';
  return entry;
}

test('newest complete and partial v4 snapshots survive older ones of each kind', async () => {
  const entries = [compiledSnapshot(1), compiledSnapshot(2, true), compiledSnapshot(3), compiledSnapshot(4, true), compiledSnapshot(5)];
  const result = await run(entries);
  assert.ifError(result.error);
  assert.deepEqual(result.ids, [4, 5]);
});

test('compiled retention keeps the newest complete and partial snapshot per tool identity', async () => {
  // Each kind has two snapshots so the oracle also checks newest wins; when the
  // two come from different native tool identities (two runner images during a
  // rollout), each is the newest of its own identity.
  for (let state = 0; state < 4; state++) {
    for (const [older, newer] of [['a', 'a'], ['a', 'c']]) {
      const entries = [], kept = [];
      let id = 0;
      for (const partial of [false, true]) {
        if (!(state & (1 << Number(partial)))) continue;
        const first = compiledSnapshot(++id, partial, older);
        const latest = compiledSnapshot(++id, partial, newer);
        entries.push(first, latest);
        if (older !== newer) kept.push(first.id);
        kept.push(latest.id);
      }
      const result = await run(entries);
      assert.ifError(result.error);
      assert.deepEqual(result.ids, kept.sort((a, b) => a - b), `state=${state}, tools=${older}/${newer}`);
    }
  }
});

test('mixed runner-image fleet keeps the newest snapshot of each identity', async () => {
  // A mixed runner-image fleet (18 Nov 2026: glibc package 8.9 and 8.12 named
  // two identities): every group keeps the newest snapshot of each identity,
  // and an identity's older snapshot still goes.
  const main = 'refs/heads/main';
  const tools = c => c.repeat(64), seq = n => n.toString(16).padStart(64, '0');
  const fleet = [
    {id: 1, key: `rui-build-v4-Linux-X64-0.17.1-${tools('a')}-compiled.${tools('d')}-${seq(1)}`},
    {id: 2, key: `rui-build-v4-Linux-X64-0.17.1-${tools('c')}-compiled.${tools('d')}-${seq(2)}`},
    {id: 3, key: `rui-build-v4-Linux-X64-0.17.1-${tools('a')}-compiled.${tools('d')}-${seq(3)}`},
    {id: 4, key: `rui-build-v2-Linux-X64-0.17.1-${tools('c')}-baseline.${tools('d')}-${seq(4)}`},
    {id: 5, key: `rui-build-v2-Linux-X64-0.17.1-${tools('a')}-baseline.${tools('d')}-${seq(5)}`},
    {id: 6, key: `rui-build-v2-Linux-X64-0.17.1-${tools('c')}-compiled-unit.${tools('d')}-${seq(6)}`},
    {id: 7, key: `rui-build-v2-Linux-X64-0.17.1-${tools('a')}-compiled-unit.${tools('d')}-${seq(7)}-partial-9-1`},
    {id: 8, key: `rui-runner-v2-Linux-X64-0.17.1-${tools('a')}-${'e'.repeat(16)}-${seq(8)}`},
    {id: 9, key: `rui-runner-v2-Linux-X64-0.17.1-${tools('c')}-${'e'.repeat(16)}-${seq(9)}`},
    {id: 10, key: `rui-build-v2-macOS-ARM64-0.17.1-${tools('a')}-compiled.${tools('d')}-${seq(10)}`},
    {id: 11, key: `rui-build-v3-macOS-ARM64-0.17.1-${tools('a')}-compiled.${tools('d')}-${seq(11)}`},
    {id: 12, key: `rui-build-v2-Linux-X64-0.17.1-${tools('c')}-baseline.${tools('d')}-${seq(12)}`},
    {id: 13, key: `rui-build-v3-macOS-ARM64-0.17.1-${tools('a')}-compiled.${tools('d')}-${seq(13)}-partial-9-1`},
    {id: 14, key: `rui-build-v3-macOS-ARM64-0.17.1-${tools('a')}-compiled-unit.${tools('d')}-${seq(14)}`},
  ].map(({id, key}) => ({...cache(id, main), key}));
  const mixed = await run(fleet);
  assert.ifError(mixed.error);
  // 10 is the leftover v2 macOS compiled snapshot, pruned by the v3 snapshot 11 of its identity.
  // 13 is a v3 partial in its own partial group; 14 is a v3 compiled-unit look-alike in its own group.
  assert.deepEqual(mixed.ids, [2, 3, 5, 6, 7, 8, 9, 11, 12, 13, 14]);
});

test('malformed v4 lookalikes never join the compiled group', async () => {
  const valid = compiledSnapshot(10).key;
  const lookalikes = [
    valid + '-extra', valid.replace('-compiled.', '-compiled-unit.'),
    valid.replace('Linux-X64', 'macOS-ARM64'), valid.replace('Linux-X64', 'Linux-ARM64'),
    valid.replace('0.17.1', '0.18.1'), valid.replace('a'.repeat(64), 'a'.repeat(63)),
    valid.replace('a'.repeat(64), 'A'.repeat(64)), valid.replace('compiled.', 'compiled-'),
    valid + '-partial-0-1', valid + '-partial-123-no', valid + '-partial-123-1-extra',
    valid + '-partial-123-1-partial-124-1',
  ].map((key, i) => ({...cache(i + 20, 'refs/heads/main'), key}));
  const current = compiledSnapshot(1);
  for (const extra of [[], [compiledSnapshot(2)]]) {
    const result = await run([current, ...lookalikes, ...extra]);
    assert.ifError(result.error);
    assert.deepEqual(result.ids, [...(extra.length ? [2] : [1]), ...lookalikes.map(entry => entry.id)]);
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
  const jobs = Object.fromEntries([...workflow.matchAll(/^  (\w+):\n((?: {4}[^\n]*\n|\n)+)/gm)]
    .map(([, name, body]) => [name, body]));
  assert.match(jobs.prune, /^    needs: \[baseline, compiled, runner, previous_release\]\s*$/m,
    'prune must wait for every warmer, including failed-job cache saves');
  assert.match(jobs.prune, /^    if:.*always\(\)/m,
    'successful matrix peers may save even if another peer fails');
  assert.doesNotMatch(jobs.prune, /needs\.baseline\.result|workflow_run\.conclusion/);
  assert.match(jobs.baseline, /github\.event_name != 'workflow_run'/,
    'completion events must not launch another baseline');
  for (const name of ['compiled', 'runner', 'previous_release']) {
    assert.match(jobs[name], /github\.event_name != 'workflow_run'/, name);
  }
  assert.match(jobs.workflow_run, /types: \[completed\]/);
  for (const file of readdirSync(directory).filter(file => file.endsWith('.yml') && file !== 'cache-maintenance.yml')) {
    const producer = readFileSync(`${directory}/${file}`, 'utf8');
    if (!/uses: (?:\.\/\.github\/actions\/setup|actions\/cache(?:\/save)?@)/.test(producer)) continue;
    if (/^cache-mode: read$/m.test(producer) && producer.match(/^\s*cache-mode:/gm).length === 1) continue;
    // A producer whose every setup restores only (publish-caches: 'false') saves nothing for cleanup to prune.
    const setups = producer.match(/uses: \.\/\.github\/actions\/setup$/gm)?.length ?? 0;
    if (setups > 0 && producer.match(/publish-caches: 'false'/g)?.length === setups
        && !/uses: actions\/cache(?:\/save)?@/.test(producer)) continue;
    const name = producer.match(/^name: (.+)$/m)[1];
    assert.ok(jobs.workflow_run.includes(name), `${file} needs post-publication cleanup`);
  }
  assert.match(jobs.prune, /ref: \$\{\{ github\.sha \}\}/);
  assert.doesNotMatch(jobs.prune, /workflow_run\.head_|actions\/download-artifact|actions\/cache|uses: \.\/\.github\/actions\/setup/,
    'privileged cleanup must use default-branch code, not producer code or caches');
});

test('post-publication cleanup retains partial saves and reconciles later concurrent saves', async () => {
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
      const later = [...published.filter(c => result.ids.includes(c.id)), cache(20, ref, platform, part)];
      const reconciled = await run(later);
      assert.ifError(reconciled.error);
      assert.deepEqual(reconciled.ids, [20]);
    }
  }
});

function workflowJobs(source) {
  return Object.fromEntries([...source.matchAll(/^  ([a-z_]+):\n((?: {4}[^\n]*\n|\n)+)/gm)]
    .map(([, name, body]) => [name, body]));
}

function workflowSteps(source) {
  return source.split(/(?=^ {6}- )/m).slice(1);
}

test('maintenance warms both producer parts on both platforms using the consumer commands', () => {
  const root = `${__dirname}/../..`;
  const jobs = workflowJobs(readFileSync(`${root}/.github/workflows/cache-maintenance.yml`, 'utf8'));
  const consumers = workflowJobs(readFileSync(`${root}/.github/workflows/check.yml`, 'utf8'));
  assert.match(jobs.compiled, /runner: \[ubuntu-24.04, macos-15\]/);
  assert.match(jobs.compiled, /part: \[compiled, compiled-unit\]/);
  assert.match(jobs.compiled, /check-part: \$\{\{ matrix.part \}\}/);
  assert.match(jobs.compiled, /matrix.part == 'compiled-unit' && 'unit' \|\| matrix.runner == 'macos-15' && 'all' \|\| 'rest'/);
  const command = 'python3 -B tests/ci/build_artifact.py build "$TARGETS" --part "$PART"';
  assert.ok(jobs.compiled.includes(command));
  assert.ok(consumers.linux_build.includes(command));
  assert.match(consumers.linux_build_unit, /build_artifact.py build "\$TARGETS" --part unit/);
  assert.match(consumers.linux_build, /check-part: compiled\s/);
  assert.match(consumers.linux_build_unit, /check-part: compiled-unit\s/);
  assert.match(consumers.linux_build, /^    timeout-minutes: 60$/m);
  assert.match(consumers.linux_build_unit, /^    timeout-minutes: 15$/m);
  // macOS has one producer for every part: no unit job, and it compiles all of them.
  assert.match(consumers.macos_build, /build "\$TARGETS" --part all/);
  assert.match(consumers.macos_build, /check-part: compiled\s/);
  assert.match(consumers.macos_build, /^    timeout-minutes: 90$/m);
  assert.equal(consumers.macos_build_unit, undefined);
  assert.match(jobs.compiled, /\["check-full","test-logic","admission-debug-integration","stack-frames","deep-modules"\]/);
  assert.match(jobs.compiled, /\["check-full","test-logic","admission-debug-integration"\]/);
  assert.match(jobs.compiled, /^    timeout-minutes: 120$/m);
});

test('publishers save after work without capping setup or shard recovery', () => {
  const directory = `${__dirname}/../../.github/workflows`;
  for (const file of readdirSync(directory).filter(file => file.endsWith('.yml'))) {
    const jobs = workflowJobs(readFileSync(`${directory}/${file}`, 'utf8'));
    for (const [name, body] of Object.entries(jobs)) {
      const steps = workflowSteps(body);
      const setup = steps.findIndex(step => /uses: \.\/\.github\/actions\/setup\n/.test(step));
      if (setup < 0 || steps[setup].includes("publish-caches: 'false'")) continue;
      const save = steps.findIndex(step => /save-only: 'true'/.test(step));
      const label = `${file}/${name}`;
      assert.ok(save > setup, `${label} must save after setup and work`);
      assert.match(steps[save], name === 'previous_release' ? /if: \$\{\{ success\(\) \}\}/ : /if: \$\{\{ always\(\) \}\}/, label);
      assert.match(steps[save], /uses: \.\/\.github\/actions\/setup\/caches\n/, label);
      assert.doesNotMatch(steps[save], /timeout-minutes:/, `${label} uploads retain the save window`);
      assert.doesNotMatch(steps[setup], /timeout-minutes:/, `${label} must not cap cold setup`);
      assert.match(steps[setup], /id: setup\n/, label);
      assert.match(steps[save], /setup-outcome: .*steps\.setup\.outcome/, label);
      assert.match(steps[save], /work-outcome: \$\{\{ steps\.compile\.outcome \}\}/, label);
      const compile = steps.findIndex(step => /id: compile\n/.test(step));
      assert.ok(setup < compile && compile < save, `${label} must name the actual work outcome`);
      const bisect = steps.findIndex(step => /name: Bisect/.test(step));
      if (bisect >= 0) assert.ok(save < bisect, `${label} saves before long bisect`);
      const work = steps.slice(setup + 1, save).filter(step => /^(?:        |      - )run:/m.test(step));
      assert.ok(work.length, `${label} must do work before saving`);
      if (name === 'linux_suites' || name === 'macos_suites') {
        const restore = steps.find(step => /id: restore\n/.test(step));
        assert.doesNotMatch(restore, /timeout-minutes:/, `${label} must retain fallback rebuild recovery`);
        assert.doesNotMatch(steps[compile], /timeout-minutes:/, `${label} configuration follows an uncapped rebuild`);
      }
      for (const [index, step] of steps.entries()) {
        if (index === compile || !step.includes('timeout-minutes:')) continue;
        if (/name: Run (?:selected targets|required native targets)/.test(step)) {
          assert.match(step, name === 'macos_suites' ? /timeout-minutes: 45\n/ : /timeout-minutes: 35\n/, label);
        } else {
          assert.match(step, /name: Bisect .*promotion batch/, `${label} introduced an unrelated step cap`);
          assert.match(step, /timeout-minutes: 240\n/, label);
        }
      }
    }
  }
});

test('capture only missing exact keys, preserving fallback and cold misses even after failure', () => {
  const action = readFileSync(`${__dirname}/../../.github/actions/setup/caches/action.yml`, 'utf8');
  const capture = action.match(/- name: Capture missing exact keys for the later save\n[\s\S]*?(?=^    - name: Select publication)/m)[0];
  assert.match(capture, /always\(\) && inputs.save-only != 'true'/);
  const script = capture.match(/^      run: \|\n((?: {8}.*\n)+)/m)[1].replace(/^ {8}/gm, '');
  const caches = ['COMPILER', 'BUILD', 'PACKAGES', 'RUNNER'];
  const migratedBuildKey = buildKeyPolicy().keys('compiled', 'b'.repeat(64), 'c'.repeat(64)).key;
  for (const publish of ['true', 'false']) {
    for (let state = 0; state < 3 ** caches.length; state++) {
      const env = {PATH: process.env.PATH, PUBLISH: publish};
      let rest = state;
      for (const cache of caches) {
        const status = rest % 3; rest = Math.floor(rest / 3);
        env[`${cache}_KEY`] = status === 2 ? '' : cache === 'BUILD' ? migratedBuildKey : `key-${cache}`;
        env[`${cache}_HIT`] = status === 0 ? 'true' : status === 1 ? 'false' : '';
      }
      const directory = mkdtempSync(join(tmpdir(), 'rui-cache-save-'));
      try {
        const output = join(directory, 'env');
        execFileSync('bash', ['-c', `false\n${script}`], {env: {...env, GITHUB_ENV: output}});
        const actual = Object.fromEntries(readFileSync(output, 'utf8').trimEnd().split('\n').map(line => line.split('=')));
        for (const cache of caches) {
          const expected = publish === 'true' && env[`${cache}_HIT`] !== 'true' ? env[`${cache}_KEY`] : '';
          assert.equal(actual[`RUI_CACHE_${cache}_KEY`], expected, `${publish}/${state}/${cache}`);
        }
      } finally { rmSync(directory, {recursive: true, force: true}); }
    }
  }
  const saves = action.split(/(?=^    - uses: actions\/cache\/save@)/m).slice(1);
  assert.equal(saves.length, caches.length);
  for (const [index, step] of saves.entries()) {
    const cache = caches[index];
    assert.ok(step.includes(`steps.save-keys.outputs.${cache.toLowerCase()}-key != ''`));
    assert.ok(step.includes(`key: \${{ steps.save-keys.outputs.${cache.toLowerCase()}-key }}`));
    assert.match(step, cache === 'PACKAGES' ? /success\(\) && inputs.save-only == 'true'/ : /always\(\) && inputs.save-only == 'true'/);
  }
  assert.match(action, /run: node \.github\/actions\/setup\/caches\/save-keys\.cjs/);
  assert.match(action, /SETUP_OUTCOME: \$\{\{ inputs.setup-outcome \}\}/);
  assert.match(action, /WORK_OUTCOME: \$\{\{ inputs.work-outcome \}\}/);
  assert.match(action, /JOB_SUCCESS: \$\{\{ job.status == 'success' \}\}/);
  const setup = readFileSync(`${__dirname}/../../.github/actions/setup/action.yml`, 'utf8');
  assert.match(setup, /test "\$\("\$RUNNER_TEMP\/rui-zig\/zig" version\)" = 0\.17\.1\n        echo "RUI_CACHE_COMPILER_READY=true"/);
});

function publisherEnv(work = 'success') {
  return {
    PATH: process.env.PATH, RUI_CACHE_BUILD_KEY: `rui-build-v4-Linux-X64-0.17.1-${'a'.repeat(64)}-compiled.${'b'.repeat(64)}-${'c'.repeat(64)}`,
    GITHUB_REF: 'refs/heads/main', GITHUB_EVENT_NAME: 'push', RUNNER_OS: 'Linux', RUNNER_ARCH: 'X64',
    SETUP_OUTCOME: 'success', WORK_OUTCOME: work, JOB_SUCCESS: String(work === 'success'),
    GITHUB_RUN_ID: '42', GITHUB_RUN_ATTEMPT: '2', RUI_CACHE_COMPILER_READY: 'true',
    RUI_CACHE_COMPILER_KEY: 'compiler', RUI_CACHE_PACKAGES_KEY: 'packages', RUI_CACHE_RUNNER_KEY: 'runner',
  };
}

test('every complete or partial build candidate passes the same final publication owner', () => {
  for (const work of ['success', 'failure', 'cancelled']) {
    for (const setup of ['success', 'failure']) {
      for (const exact of [false, true]) {
        const env = {...publisherEnv(work), SETUP_OUTCOME: setup};
        if (exact) env.RUI_CACHE_BUILD_KEY = '';
        const calls = [];
        const result = publicationKeys(env, (key, actualEnv) => {
          calls.push(key);
          assert.equal(actualEnv, env);
          assert.equal(actualEnv.RUI_CACHE_BUILD_KEY, env.RUI_CACHE_BUILD_KEY);
          return {key: ''};
        });
        const candidate = saveKey({kind: 'build', key: env.RUI_CACHE_BUILD_KEY, setupOutcome: setup,
          workOutcome: work, runId: '42', runAttempt: '2'});
        assert.deepEqual(calls, candidate ? [candidate] : [], `${work}/${setup}/${exact}`);
        assert.equal(result.build, '');
        assert.equal(result.compiler, 'compiler');
        assert.equal(result.runner, saveKey({kind: 'runner', key: 'runner', setupOutcome: setup,
          workOutcome: work, runId: '42', runAttempt: '2'}));
      }
    }
  }
  const env = publisherEnv();
  assert.equal(publicationKeys(env, key => ({key, invalidated_manifests: 0})).build, env.RUI_CACHE_BUILD_KEY);
  assert.equal(publicationKeys({...env, JOB_SUCCESS: 'false'}, key => ({key, invalidated_manifests: 0})).build,
    env.RUI_CACHE_BUILD_KEY, 'later job failure preserves completed, compacted work');
});

test('a bad compaction bridge response suppresses only the build publication', () => {
  const env = publisherEnv();
  const reports = [null, [], false, 'scalar', 0, {}, {key: 'replacement'}, {key: env.RUI_CACHE_BUILD_KEY, skipped: 'audit failed'}];
  const originalLog = console.log;
  const messages = [];
  console.log = message => messages.push(message);
  try {
    for (const report of reports) {
      assert.deepEqual(publicationKeys(env, () => report),
        {compiler: 'compiler', build: '', packages: 'packages', runner: 'runner'});
    }
    assert.deepEqual(publicationKeys(env, () => { throw new Error('child failed'); }),
      {compiler: 'compiler', build: '', packages: 'packages', runner: 'runner'});
  } finally { console.log = originalLog; }
  assert.equal(messages.length, reports.length + 1);
  assert.ok(messages.every(line => line.startsWith('Build cache publication declined: ')));
});

test('real publication bridge declines untrimmed Linux partials and complete candidates without qualified work', () => {
  for (const work of ['success', 'failure', 'cancelled']) {
    const env = publisherEnv(work);
    const result = publicationKeys(env);
    assert.equal(result.build, '', work);
    assert.equal(result.compiler, 'compiler', work);
    assert.equal(result.runner, work === 'success' ? 'runner' : 'runner-partial-42-2', work);
  }
  const action = readFileSync(`${__dirname}/../../.github/actions/setup/caches/action.yml`, 'utf8');
  assert.doesNotMatch(action, /cache_snapshot\.py --prune/,
    'the action cannot bypass the publication owner with an independent success-only GC step');
});

function saveGuard(step, values, successful) {
  const expression = step.match(/^ {6,8}if: \$\{\{ (.*) \}\}$/m)[1];
  return expression.split(' && ').every(term => {
    if (term === 'always()') return true;
    if (term === 'success()') return successful;
    const match = term.match(/^([\w.-]+) (==|!=) '([^']*)'$/);
    assert.ok(match, `unsupported save guard: ${term}`);
    assert.ok(Object.hasOwn(values, match[1]), `missing guard input: ${match[1]}`);
    return match[2] === '==' ? values[match[1]] === match[3] : values[match[1]] !== match[3];
  });
}

test('every saved cache x work outcome x restore state chooses exact, partial, or none', () => {
  const root = `${__dirname}/../..`;
  const action = readFileSync(`${root}/.github/actions/setup/caches/action.yml`, 'utf8');
  const saves = Object.fromEntries(action.split(/(?=^    - uses: actions\/cache\/save@)/m).slice(1)
    .map(step => [step.match(/key: \$\{\{ steps.save-keys.outputs.([a-z]+)-key \}\}/)[1], step]));
  const maintenance = workflowJobs(readFileSync(`${root}/.github/workflows/cache-maintenance.yml`, 'utf8'));
  const external = {
    'previous-release': workflowSteps(maintenance.previous_release).find(step => step.includes('name: Publish the previous-release compilation')),
    actionlint: workflowSteps(maintenance.baseline).find(step => step.includes('uses: actions/cache/save@')),
  };
  for (const [kind, step] of Object.entries(external)) {
    assert.doesNotMatch(step, /always\(\)/, `${kind} remains save-on-success`);
    assert.match(step, /success\(\)/);
    assert.match(step, /outcome == 'success'/, `${kind} must finish its own work`);
    assert.match(step, /key: \$\{\{ steps\.(?:restore|actionlint-cache).outputs.cache-primary-key \}\}/);
  }
  const kinds = ['compiler', 'build', 'packages', 'runner', 'previous-release', 'actionlint'];
  const outcomes = [
    {name: 'setup/install failed', setupOutcome: 'failure', workOutcome: 'skipped', compilerReady: false, successful: false,
      expected: ['none', 'none', 'none', 'none', 'none', 'none']},
    {name: 'fetch failed after verified compiler', setupOutcome: 'failure', workOutcome: 'skipped', compilerReady: true, successful: false,
      expected: ['exact', 'none', 'none', 'none', 'none', 'none']},
    {name: 'compile failed', setupOutcome: 'success', workOutcome: 'failure', compilerReady: true, successful: false,
      expected: ['exact', 'partial', 'none', 'partial', 'none', 'none']},
    {name: 'compile step timed out', setupOutcome: 'success', workOutcome: 'failure', compilerReady: true, successful: false,
      expected: ['exact', 'partial', 'none', 'partial', 'none', 'none']},
    {name: 'compile cancelled', setupOutcome: 'success', workOutcome: 'cancelled', compilerReady: true, successful: false,
      expected: ['exact', 'partial', 'none', 'partial', 'none', 'none']},
    {name: 'success', setupOutcome: 'success', workOutcome: 'success', compilerReady: true, successful: true,
      expected: ['exact', 'exact', 'exact', 'exact', 'exact', 'exact']},
    {name: 'later unrelated failure', setupOutcome: 'success', workOutcome: 'success', compilerReady: true, successful: false,
      expected: ['exact', 'exact', 'none', 'exact', 'none', 'none']},
    {name: 'compile skipped', setupOutcome: 'success', workOutcome: 'skipped', compilerReady: true, successful: true,
      expected: ['exact', 'none', 'exact', 'none', 'none', 'none']},
  ];
  for (const outcome of outcomes) {
    for (const restore of ['exact hit', 'prefix hit', 'miss']) {
      const exactHit = restore === 'exact hit';
      const directory = mkdtempSync(join(tmpdir(), 'rui-publication-domain-'));
      try {
        const output = join(directory, 'output');
        const keys = Object.fromEntries(kinds.map(kind => [kind, `key-${kind}`]));
        const env = {
          PATH: process.env.PATH, GITHUB_OUTPUT: output, GITHUB_RUN_ID: '123', GITHUB_RUN_ATTEMPT: '2',
          SETUP_OUTCOME: outcome.setupOutcome, WORK_OUTCOME: outcome.workOutcome,
          JOB_SUCCESS: String(outcome.successful), RUI_CACHE_COMPILER_READY: String(outcome.compilerReady),
        };
        for (const kind of Object.keys(saves)) env[`RUI_CACHE_${kind.toUpperCase()}_KEY`] = exactHit ? '' : keys[kind];
        execFileSync(process.execPath, [`${root}/.github/actions/setup/caches/save-keys.cjs`], {env});
        const selected = Object.fromEntries(readFileSync(output, 'utf8').trimEnd().split('\n').map(line => line.split('=')));
        for (const [index, kind] of kinds.entries()) {
          const label = `${kind}/${outcome.name}/${restore}`;
          const choice = exactHit ? 'none' : outcome.expected[index];
          const expected = choice === 'none' ? '' : choice === 'exact' ? keys[kind] : `${keys[kind]}-partial-123-2`;
          let actual;
          if (Object.hasOwn(saves, kind)) {
            const value = selected[`${kind}-key`];
            assert.equal(value, saveKey({...outcome, kind, key: exactHit ? '' : keys[kind], runId: '123', runAttempt: '2'}), label);
            const values = {'inputs.save-only': 'true', [`steps.save-keys.outputs.${kind}-key`]: value};
            actual = saveGuard(saves[kind], values, outcome.successful) ? value : '';
          } else {
            const prefix = kind === 'actionlint' ? 'actionlint-cache' : 'restore';
            const values = {
              'runner.os': 'Linux', 'steps.compile.outcome': outcome.workOutcome,
              'steps.actionlint-install.outcome': outcome.workOutcome,
              [`steps.${prefix}.outputs.cache-hit`]: exactHit ? 'true' : restore === 'prefix hit' ? 'false' : '',
              [`steps.${prefix}.outputs.cache-primary-key`]: keys[kind],
            };
            actual = saveGuard(external[kind], values, outcome.successful) ? keys[kind] : '';
          }
          assert.equal(actual, expected, label);
        }
      } finally { rmSync(directory, {recursive: true, force: true}); }
    }
  }
  for (const kind of Object.keys(saves)) {
    assert.equal(saveKey({kind, key: '', setupOutcome: 'success', workOutcome: 'success', compilerReady: true, successful: true}), '', `${kind}/skipped restore or read-only publisher`);
  }
});

test('partial compilation restores by existing prefixes without claiming an exact hit', () => {
  const digest = 'a'.repeat(64);
  for (const [kind, key, prefix] of [
    ['build', `rui-build-v2-Linux-X64-0.17.1-${digest}-compiled.${digest}-${digest}`, `rui-build-v2-Linux-X64-0.17.1-${digest}-compiled.${digest}-`],
    ['runner', `rui-runner-v2-Linux-X64-0.17.1-${digest}-${'b'.repeat(16)}-${digest}`, `rui-runner-v2-Linux-X64-0.17.1-${digest}-${'b'.repeat(16)}-`],
  ]) {
    const partial = saveKey({kind, key, setupOutcome: 'success', workOutcome: 'failure', runId: '123', runAttempt: '1'});
    assert.ok(partial.startsWith(prefix));
    assert.notEqual(partial, key, 'partial restore cannot set an exact cache-hit');
    const resumed = saveKey({kind, key, setupOutcome: 'success', workOutcome: 'success'});
    assert.equal(resumed, key, 'resuming must still be able to publish completed work');
    assert.notEqual(saveKey({kind, key, setupOutcome: 'success', workOutcome: 'failure', runId: '123', runAttempt: '2'}), partial);
  }
  const setup = readFileSync(`${__dirname}/../../.github/actions/setup/action.yml`, 'utf8');
  assert.match(setup, /- name: Fetch the screen observer's pinned package graph\n +if: .*steps\.caches\.outputs\.build-hit != 'true'/,
    'the separate screen graph still fetches on a partial build snapshot');
});

test('prune retains newest partial per build or CPU prefix independently of complete snapshots', async () => {
  const main = 'refs/heads/main';
  const build = (id, part = 'compiled', platform = 'Linux-X64') => ({
    ...cache(id, main, platform, part),
    key: `rui-build-v2-${platform}-0.17.1-${'a'.repeat(64)}-${part}.${id.toString(16).padStart(64, '0')}-${'b'.repeat(64)}`,
  });
  const runner = (id, cpu = 'c') => ({...cache(id, main), key: `rui-runner-v2-Linux-X64-0.17.1-${'a'.repeat(64)}-${cpu.repeat(16)}-${'b'.repeat(64)}`});
  const partial = (entry, attempt = 1) => ({...entry, key: `${entry.key}-partial-123-${attempt}`});
  const entries = [
    cache(1, main, 'Linux-X64', 'compiled'),
    partial(cache(2, main, 'Linux-X64', 'compiled')),
    partial(build(3), 2), build(4), partial(build(5, 'compiled-unit')),
    partial(build(6, 'compiled', 'macOS-ARM64')), runner(7),
    partial(runner(8)), partial(runner(9), 2), partial(runner(10, 'd')),
    {...partial(build(11)), ref: 'refs/pull/1/merge'},
    {...build(12), key: `${build(12).key}-partial-invalid-1`},
    {...cache(13, main), key: 'rui-compiler-Linux-X64-0.17.1-partial-123-1'},
    partial(build(14), 3),
  ];
  const result = await run(entries);
  assert.ifError(result.error);
  assert.deepEqual(result.ids, [4, 5, 6, 7, 9, 10, 12, 13, 14]);
});

test('existing job timeout budgets rise only in a job that absorbs the budgets it replaces', () => {
  const directory = `${__dirname}/../../.github/workflows`;
  // A job that absorbs others may take the sum of the budgets it replaces (CI-33); nothing else may rise.
  const absorbed = {
    // macos_build replaces macos_build (60) and macos_build_unit (60).
    'check.yml': {macos_build: 120, macos_suites: 105 /* the three former suite rows at 35 each */},
  };
  for (const [file, expected] of [
    ['cache-maintenance.yml', {baseline: '30', runner: '15', previous_release: '45'}],
    ['check.yml', {linux_build: '60', linux_build_unit: '15', macos_build: '90', macos_typecheck: '15', cache_execution: '20', linux_suites: '${{ inputs.promotion && 300 || 35 }}', macos_suites: '${{ inputs.promotion && 300 || 60 }}'}],
    ['renderer-contracts.yml', {contracts: '${{ inputs.batch-base && 300 || 45 }}', mutations: '60'}],
  ]) {
    const jobs = workflowJobs(readFileSync(`${directory}/${file}`, 'utf8'));
    for (const [name, budget] of Object.entries(expected)) {
      assert.equal(jobs[name].match(/^    timeout-minutes: (.*)$/m)[1], budget, `${file}/${name}`);
      const replaced = absorbed[file]?.[name];
      if (replaced !== undefined) {
        const minutes = Number(budget.match(/\|\| (\d+) \}\}$/)?.[1] ?? budget);
        assert.ok(minutes <= replaced, `${file}/${name} may not exceed the sum it absorbs (${replaced})`);
      }
    }
  }
});

function deadlineValues(text) {
  if (/^[0-9]+$/.test(text)) return {condition: null, minutes: [Number(text)]};
  const conditional = text.match(/^\$\{\{ (.*?) && ([0-9]+) \|\| ([0-9]+) \}\}$/);
  assert.ok(conditional, `unsupported deadline expression: ${text}`);
  return {condition: conditional[1], minutes: [Number(conditional[2]), Number(conditional[3])]};
}

test('new work deadlines derive a save window and cover recorded green durations plus margin', () => {
  const green = {
    'check.yml': {
      linux_build: [851, '43732653500'],
      linux_build_unit: [480, '43819213128'],
      macos_typecheck: [449, '43819213128'],
      // PROVISIONAL: the sum of the separate rest (1117 s) and unit (760 s) green runs, until a combined run is recorded.
      macos_build: [1877, '43720387127'],
      cache_execution: [351, '42755585733'],
    },
    'cache-maintenance.yml': {
      baseline: [568, '43433947643'],
      compiled: [1877, '43720387127'],
      runner: [99, '43381025988'],
      previous_release: [354, '43381025988'],
    },
    'renderer-contracts.yml': {
      contracts: [725, '43732653500'],
      mutations: [464, '42754650502'],
    },
  };
  const marginSeconds = 120;
  const observedSetupSeconds = 213;
  const retryWindows = 4;
  const fetch = readFileSync(`${__dirname}/../../src/fetch_dependencies.sh`, 'utf8');
  const retrySeconds = Math.max(...[...fetch.matchAll(/--retry-max-time (\d+)/g)].map(m => Number(m[1])));
  const requestSeconds = Math.max(...[...fetch.matchAll(/--max-time (\d+)/g)].map(m => Number(m[1])));
  for (const [file, observations] of Object.entries(green)) {
    const source = readFileSync(`${__dirname}/../../.github/workflows/${file}`, 'utf8');
    const setup = Number(source.match(/^# setup-allowance-minutes: (\d+)$/m)[1]);
    const reserve = Number(source.match(/^# save-reserve-minutes: (\d+)$/m)[1]);
    assert.ok(setup * 60 >= observedSetupSeconds + retryWindows * (retrySeconds + requestSeconds), `${file} must account for cold fetch, not just warm setup`);
    assert.ok(reserve >= 3, `${file} must leave at least three minutes for publication`);
    assert.match(source, /Selected 43832831879: setup 213 s/);
    const jobs = workflowJobs(source);
    const measured = new Set();
    for (const [name, body] of Object.entries(jobs)) {
      const steps = workflowSteps(body);
      const setupStep = steps.find(step => /uses: \.\/\.github\/actions\/setup\n/.test(step));
      if (!setupStep || setupStep.includes("publish-caches: 'false'")) continue;
      const compile = steps.find(step => /id: compile\n/.test(step));
      assert.ok(compile, `${file}/${name} must identify the work whose outcome is saved`);
      if (name === 'linux_suites' || name === 'macos_suites') {
        assert.doesNotMatch(compile, /timeout-minutes:/, `${file}/${name} follows unbounded artifact recovery`);
        continue;
      }
      const recorded = observations[name];
      assert.ok(recorded, `${file}/${name} needs an independently recorded green duration`);
      measured.add(name);
      const timing = compile.match(/# Cache timing: green (\d+) s, run (\d+); minimum margin (\d+) s\./);
      assert.ok(timing, `${file}/${name} must cite the timing next to the deadline decision`);
      assert.equal(Number(timing[1]), recorded[0], `${file}/${name} green duration`);
      assert.equal(timing[2], recorded[1], `${file}/${name} evidence run`);
      assert.equal(Number(timing[3]), marginSeconds, `${file}/${name} minimum margin`);
      const budget = deadlineValues(body.match(/^    timeout-minutes: (.*)$/m)[1]);
      const limits = budget.minutes.map(minutes => minutes - setup - reserve);
      const minimumSeconds = recorded[0] + marginSeconds;
      const fits = limits.every(minutes => minutes * 60 >= minimumSeconds);
      const deadline = compile.match(/^        timeout-minutes: (.*)$/m);
      if (!fits) {
        assert.equal(deadline, null, `${file}/${name} must not cap work when the measured minimum cannot fit`);
      } else {
        assert.ok(deadline, `${file}/${name} can reserve a measured save window`);
        const actual = deadlineValues(deadline[1]);
        assert.equal(actual.condition, budget.condition, `${file}/${name} must follow the job's promotion condition`);
        assert.deepEqual(actual.minutes, limits, `${file}/${name} deadline must equal job - cold setup - save reserve`);
        for (const minutes of actual.minutes) assert.ok(minutes * 60 >= minimumSeconds, `${file}/${name} would time out a recent green run`);
      }
    }
    assert.deepEqual([...measured].sort(), Object.keys(observations).sort(), `${file} timing records must cover real work steps`);
  }
});
