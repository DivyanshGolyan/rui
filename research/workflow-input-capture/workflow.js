// Throwaway scanner/verifier fixture. All durable calls have stable keys.
const answers = new Map();
globalThis.load = row => answers.set(row.key, row.value);
globalThis.start = n => {
  function send(key, input) {
    emit({type: 'call', key, input});
    if (answers.has(key)) return Promise.resolve(answers.get(key));
    emit({type: 'pending', key});
    return new Promise(() => {});
  }
  Promise.all(Array.from({length: n}, async (_, i) => {
    const findings = await send(`scan/${i}`, `scan ${i}`);
    const verdicts = await Promise.all(findings.map(async (f, j) =>
      send(`verify/${i}/${j}`, `verify ${i}/${j} bytes=${f.text.length}`)));
    return verdicts.reduce((sum, x) => sum + x, 0);
  })).then(values => emit({type: 'done', value: values.reduce((a,b) => a+b,0)}), error => { globalThis.failure = String(error); });
};
