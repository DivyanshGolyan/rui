const {execFileSync} = require('node:child_process');
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

function publishBuild(key, env) {
  const output = execFileSync('python3', ['-B', 'tests/ci/cache_snapshot.py', '--publication-key', key],
    {env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit']});
  console.log(output.trim());
  return JSON.parse(output);
}

function publicationKeys(env, prepareBuild = publishBuild) {
  const common = {
    setupOutcome: env.SETUP_OUTCOME, workOutcome: env.WORK_OUTCOME,
    compilerReady: env.RUI_CACHE_COMPILER_READY === 'true',
    successful: env.JOB_SUCCESS === 'true',
    runId: env.GITHUB_RUN_ID, runAttempt: env.GITHUB_RUN_ATTEMPT,
  };
  const keys = {};
  for (const kind of ['compiler', 'build', 'packages', 'runner']) {
    let key = saveKey({...common, kind, key: env[`RUI_CACHE_${kind.toUpperCase()}_KEY`]});
    if (kind === 'build' && key) {
      try {
        const report = prepareBuild(key, env);
        if (!report || typeof report !== 'object' || Array.isArray(report) ||
            !['', key].includes(report.key) || (report.key && Object.hasOwn(report, 'skipped'))) {
          throw new Error('Invalid build publication report');
        }
        key = report.key;
      } catch (error) {
        console.log(`Build cache publication declined: ${error.message}`);
        key = '';
      }
    }
    keys[kind] = key;
  }
  return keys;
}

function main(env) {
  for (const [kind, key] of Object.entries(publicationKeys(env))) {
    appendFileSync(env.GITHUB_OUTPUT, `${kind}-key=${key}\n`);
  }
}

module.exports = {publicationKeys, saveKey};
if (require.main === module) main(process.env);
