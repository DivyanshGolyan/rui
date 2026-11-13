// Only trusted main workflows invoke this with actions:write. PR jobs never do.
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
    candidates.push({cache, pull, created});
  }

  // Plan from the complete inventory before deleting anything. Retain by creation,
  // not access: a frequently restored obsolete snapshot must not displace a new one.
  candidates.sort((a, b) => b.created - a.created || b.cache.id - a.cache.id);
  const retained = new Set();
  const obsolete = [];
  for (const {cache, pull} of candidates) {
    // Only main publishes (setup's publish-caches default), so a PR's Rui cache
    // came from a run before that rule and only takes quota from main's.
    if (pull) {
      obsolete.push(cache);
      continue;
    }
    // Main keeps the newest snapshot of each group, replacing old tool,
    // dependency and build-runner generations too. This is a snapshot-count
    // policy, not a byte quota; ungrouped namespaces survive.
    const group = mainGroup(cache.key);
    if (group === null) continue;
    if (retained.has(group)) obsolete.push(cache);
    retained.add(group);
  }
  for (const cache of obsolete) {
    try {
      await actions.deleteActionsCacheById({...context.repo, cache_id: cache.id});
      core.info(`Deleted cache ${cache.id} (${cache.ref}, ${cache.size_in_bytes} bytes)`);
    } catch (error) {
      if (error.status !== 404) throw error;
      core.info(`Cache ${cache.id} was already removed`);
    }
  }
};

function mainGroup(key) {
  // Both layouts share a group so the newest snapshot wins during migration.
  const reordered = /^rui-build-v2-(Linux-X64|macOS-ARM64)-0\.17\.[0-9]+-[a-f0-9]{64}-([a-z][a-z0-9-]*)-[a-f0-9]{64}-[a-f0-9]{64}$/.exec(key);
  if (reordered) return `build/${reordered[1]}/${reordered[2]}`;
  const build = /^rui-build-v2-(Linux-X64|macOS-ARM64)-0\.17\.[0-9]+-[a-f0-9]{64}-[a-f0-9]{64}-[a-f0-9]{64}-([a-z][a-z0-9-]*)$/.exec(key);
  if (build) return `build/${build[1]}/${build[2]}`;
  const runner = /^rui-runner-v2-(Linux-X64|macOS-ARM64)-0\.17\.[0-9]+-[a-f0-9]{64}-([a-f0-9]{16})-[a-f0-9]{64}$/.exec(key);
  if (runner) return `runner/${runner[1]}/${runner[2]}`;
  const compiler = /^rui-compiler-(Linux-X64|macOS-ARM64)-0\.17\.[0-9]+$/.exec(key);
  if (compiler) return `compiler/${compiler[1]}`;
  if (/^rui-packages-v1-[a-f0-9]{64}$/.test(key)) return 'packages';
  return null;
}
