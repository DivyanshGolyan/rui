// Illustrates replay call order, with all previously blocked calls settled.
// Uses native ECMAScript promises; does not execute OnePage or make model calls.
import assert from 'node:assert/strict';

async function evaluate(visible) {
  const calls = [];
  const pending = [];
  function operation(name) {
    calls.push(name);
    if (visible.has(name)) return Promise.resolve(`answer:${name}`);
    pending.push(name);
    return new Promise(() => {});
  }
  const workflow = Promise.all([
    (async () => {
      await operation('A');
      await operation('C');
    })(),
    (async () => {
      await Promise.resolve();
      await Promise.resolve();
      await operation('B');
    })(),
  ]);
  // Allow the finite microtask queue to drain, without settling pending work.
  await new Promise(resolve => setImmediate(resolve));
  void workflow;
  return { calls, pending };
}

const first = await evaluate(new Set());
const replay = await evaluate(new Set(first.pending));
assert.deepEqual(first.calls, ['A', 'B']);
assert.deepEqual(first.pending, ['A', 'B']);
assert.deepEqual(replay.calls, ['A', 'C', 'B']);
assert.deepEqual(replay.pending, ['C']);
console.log(JSON.stringify({ first, replay }, null, 2));
