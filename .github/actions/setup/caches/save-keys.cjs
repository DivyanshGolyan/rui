const {appendFileSync} = require('node:fs');

function saveKey({kind, key, setupOutcome, workOutcome,
  compilerReady = false, successful = false, runId, runAttempt}) {
  if (!key) return '';
  if (kind === 'compiler') return compilerReady ? key : '';
  if (setupOutcome !== 'success') return '';
  switch (kind) {
    case 'build':
    case 'runner':
      if (workOutcome === 'success') return key;
      if (!['failure', 'cancelled'].includes(workOutcome)) return '';
      if (!/^[1-9][0-9]*$/.test(runId) || !/^[1-9][0-9]*$/.test(runAttempt)) {
        throw new Error('Partial compilation needs a run ID and attempt');
      }
      return `${key}-partial-${runId}-${runAttempt}`;
    case 'packages':
      return successful ? key : '';
    default:
      throw new Error(`Unknown cache kind: ${kind}`);
  }
}

function main(env) {
  const common = {
    setupOutcome: env.SETUP_OUTCOME, workOutcome: env.WORK_OUTCOME,
    compilerReady: env.RUI_CACHE_COMPILER_READY === 'true',
    successful: env.JOB_SUCCESS === 'true',
    runId: env.GITHUB_RUN_ID, runAttempt: env.GITHUB_RUN_ATTEMPT,
  };
  for (const kind of ['compiler', 'build', 'packages', 'runner']) {
    const key = saveKey({...common, kind, key: env[`RUI_CACHE_${kind.toUpperCase()}_KEY`]});
    appendFileSync(env.GITHUB_OUTPUT, `${kind}-key=${key}\n`);
  }
}

module.exports = {saveKey};
if (require.main === module) main(process.env);
