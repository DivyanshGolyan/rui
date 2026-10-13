// Only trusted main workflows invoke this with actions:write. PR jobs never do.
module.exports = async function pruneCaches({github, context, core}) {
  const {actions, pulls} = github.rest;
  const caches = await github.paginate(actions.getActionsCacheList, {
    ...context.repo, per_page: 100,
  });
  const candidates = [];
  const states = new Map();
  for (const cache of caches) {
    const build = /^rui-build-v2-(Linux-X64|macOS-ARM64)-0\.16\.0-[a-f0-9]{64}-[a-f0-9]{64}-[a-f0-9]{64}-(all|execution|callers|baseline)$/.exec(cache.key);
    const compiler = /^rui-compiler-(Linux-X64|macOS-ARM64)-0\.16\.0$/.test(cache.key);
    const pull = /^refs\/pull\/([1-9][0-9]*)\/merge$/.exec(cache.ref);
    if ((!build && !compiler) || (!pull && cache.ref !== 'refs/heads/main')) continue;
    if (pull && !states.has(cache.ref)) {
      const {data} = await pulls.get({...context.repo, pull_number: Number(pull[1])});
      if (data.state !== 'open' && data.state !== 'closed') throw new Error('Unknown PR state');
      states.set(cache.ref, data.state);
    }
    const created = Date.parse(cache.created_at);
    if (!Number.isFinite(created)) throw new Error('Invalid cache creation time');
    candidates.push({cache, build, created});
  }

  // Plan from the complete inventory before deleting anything. Retain by creation,
  // not access: a frequently restored obsolete snapshot must not displace a new one.
  candidates.sort((a, b) => b.created - a.created || b.cache.id - a.cache.id);
  const retained = new Map();
  const obsolete = [];
  for (const {cache, build} of candidates) {
    if (states.get(cache.ref) === 'closed') {
      obsolete.push(cache);
    } else if (build) {
      const group = `${cache.ref}/${build[1]}/${build[2]}`;
      const count = (retained.get(group) || 0) + 1;
      retained.set(group, count);
      // Replace old tool/dependency generations too; this is a snapshot-count
      // policy, not a byte quota. Other cache namespaces and branch refs survive.
      if (count > (cache.ref === 'refs/heads/main' ? 2 : 1)) obsolete.push(cache);
    }
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
