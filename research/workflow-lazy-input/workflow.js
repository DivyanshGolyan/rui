// THROWAWAY: full finding text, no delivery scheduler or decoded-result cache.
const historicalAnswers = new Map();
globalThis.preload = (key, value) => historicalAnswers.set(key, value);
globalThis.cached = key => historicalAnswers.get(key);
function send(key, input) {
  emit({type: 'call', key, kind: 'message', input});
  let value;
  try { value = readAnswer(key); } catch (error) { return Promise.reject(error); }
  if (value !== undefined) return Promise.resolve(value);
  emit({type: 'pending', key});
  return new Promise(() => {});
}
async function submitVerifiers(i) {
  const findings = await send(`scan/${i}`, `scan ${i}`);
  return findings.map((finding, j) => send(`verify/${i}/${j}`, finding.text));
}
async function run(n, flow) {
  if (flow === 'identity') {
    const p = send('repeat', 'same input');
    const a = await p;
    a.changedLocally = true;
    const samePromiseValue = await p;
    const b = await send('repeat', 'same input');
    if (a !== samePromiseValue) throw Error('Promise identity changed');
    return {fresh: a !== b && b.changedLocally === undefined, samePromise: true};
  }
  if (flow === 'types') {
    if (await send('null', 'null input') !== null) throw Error('null lost');
    let caught = false;
    try { await send('failure', 'failure input'); }
    catch (e) { caught = e.code === 'saved failure'; }
    if (!caught) throw Error('failure lost');
    return await send('missing', 'missing input');
  }
  if (flow === 'keys') {
    for (const key of ['', 'a', 'aa', 'é', 'e\u0301', '鍵', 'x'.repeat(8192)]) {
      if ((await send(key, key)).key !== key) throw Error('key mismatch');
    }
    return 'keys match';
  }
  if (flow === 'cpu') { while (true) {} }
  if (flow === 'native-cpu') return burnNative();
  if (flow === 'wall') return stallNative();
  if (flow === 'parallel') {
    const totals = await Promise.all(Array.from({length: n}, async (_, i) => {
      const promises = await submitVerifiers(i);
      return (await Promise.all(promises)).reduce((a,b) => a+b, 0);
    }));
    return totals.reduce((a,b) => a+b,0);
  }
  // Each helper has returned before the next scanner is decoded. Retain only
  // verifier Promises, not scanner results; selective intentionally reaches two.
  const pending = [];
  for (let i = 0; i < (flow === 'selective' ? Math.min(n,2) : n); i++) {
    const promises = await submitVerifiers(i);
    pending.push(...promises);
  }
  return (await Promise.all(pending)).reduce((a,b) => a+b,0);
}
globalThis.start = (n, flow) => {
  run(n, flow).then(value => emit({type: 'done', value}), error => {
    globalThis.failure = String(error);
  });
};
