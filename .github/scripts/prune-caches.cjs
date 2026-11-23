module.exports = async function pruneCaches({github, context, core}) {
  const {actions} = github.rest;
  const caches = await github.paginate(actions.getActionsCacheList, {
    ...context.repo, per_page: 100,
  });
  const candidates = [];
  for (const cache of caches) {
    const pull = /^refs\/pull\/[1-9][0-9]*\/merge$/.test(cache.ref);
    if (!cache.key.startsWith('rui-') || (!pull && cache.ref !== 'refs/heads/main')) continue;
    const created = Date.parse(cache.created_at);
    if (!Number.isFinite(created)) throw new Error('Invalid cache creation time');
    const group = pull ? null : mainGroup(cache.key);
    candidates.push({cache, pull, created, group});
  }

  candidates.sort((a, b) => b.created - a.created || b.cache.id - a.cache.id);
  const retained = new Set();
  const obsolete = [];
  for (const {cache, pull, group} of candidates) {
    if (pull) {
      obsolete.push(cache);
      continue;
    }
    if (group === null) continue;
    // Each native tool identity keeps its own newest snapshot: while GitHub
    // rolls out a runner image, jobs on either image restore only their own
    // identity.
    const tools = toolIdentity(cache.key);
    const retentionGroup = tools === null ? group : `${group}@${tools}`;
    if (retained.has(retentionGroup)) obsolete.push(cache);
    retained.add(retentionGroup);
  }
  const deleting = new Set(obsolete.map(cache => cache.id));
  const bytes = {};
  for (const {cache, group} of candidates) {
    if (group === null || deleting.has(cache.id)) continue;
    bytes[group] = (bytes[group] || 0) + cache.size_in_bytes;
  }
  core.info(`Retained main cache bytes by group: ${JSON.stringify(bytes)}`);
  for (const cache of obsolete) {
    try {
      await actions.deleteActionsCacheById({...context.repo, cache_id: cache.id});
      core.info(`Deleted cache ${cache.id} (${cache.ref}, ${cache.size_in_bytes} bytes, key=${cache.key}, version=${cache.version})`);
    } catch (error) {
      if (error.status !== 404) throw error;
      core.info(`Cache ${cache.id} was already removed`);
    }
  }
};

// The native tool identity that build and build-runner keys carry after the
// compiler version (.github/actions/setup/caches/action.yml).
function toolIdentity(key) {
  const match = /^rui-(?:build-v[24]|runner-v2)-(?:Linux-X64|macOS-ARM64)-0\.17\.[0-9]+-([a-f0-9]{64})-/.exec(key);
  return match ? match[1] : null;
}

function mainGroup(key) {
  const partial = /^(.*)-partial-[1-9][0-9]*-[1-9][0-9]*$/.exec(key);
  if (partial) {
    const complete = mainGroup(partial[1]);
    return complete !== null && /^(build|runner)\//.test(complete) ? `partial/${complete}` : null;
  }
  if (/^rui-build-v4-Linux-X64-0\.17\.[0-9]+-[a-f0-9]{64}-compiled\.[a-f0-9]{64}-[a-f0-9]{64}$/.test(key)) {
    return 'build/Linux-X64/compiled';
  }
  const reordered = /^rui-build-v2-(Linux-X64|macOS-ARM64)-0\.17\.[0-9]+-[a-f0-9]{64}-([a-z][a-z0-9-]*)\.[a-f0-9]{64}-[a-f0-9]{64}$/.exec(key);
  if (reordered) return `build/${reordered[1]}/${reordered[2]}`;
  const runner = /^rui-runner-v2-(Linux-X64|macOS-ARM64)-0\.17\.[0-9]+-[a-f0-9]{64}-([a-f0-9]{16})-[a-f0-9]{64}$/.exec(key);
  if (runner) return `runner/${runner[1]}/${runner[2]}`;
  const compiler = /^rui-compiler-(Linux-X64|macOS-ARM64)-0\.17\.[0-9]+$/.exec(key);
  if (compiler) return `compiler/${compiler[1]}`;
  if (/^rui-packages-v1-[a-f0-9]{64}$/.test(key)) return 'packages';
  return null;
}
