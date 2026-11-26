// Host N pi AgentSessions in one Node process (pi's documented SDK embedding, pi 1.x API).
// usage: node pi_sdk_many.mjs <pi-coding-agent dist/index.js> N <workspace root>
// Each session gets its own cwd and an in-memory SessionManager; every prompt
// is started and left pending against the holding fixture.
import { pathToFileURL } from "node:url";
import { mkdirSync } from "node:fs";
const [entry, nStr, root] = process.argv.slice(2);
const pi = await import(pathToFileURL(entry).href);
const { ModelRuntime, SessionManager, createAgentSession } = pi;
const modelRuntime = await ModelRuntime.create();
const model = modelRuntime.getModel("fake", "fake-model");
if (!model) { console.error("fake model not found"); process.exit(2); }
const n = Number(nStr);
const sessions = [];
for (let i = 0; i < n; i++) {
  const cwd = `${root}/ws${i}`; mkdirSync(cwd, { recursive: true });
  const { session } = await createAgentSession({ cwd, model, modelRuntime, sessionManager: SessionManager.inMemory() });
  sessions.push(session);
  session.prompt(`Task ruiprobe${i}x: reply with the word hi.`).catch((e) => console.error(`session ${i}:`, e?.message));
}
console.log(`started ${n}`);
setInterval(() => {}, 1 << 30);
