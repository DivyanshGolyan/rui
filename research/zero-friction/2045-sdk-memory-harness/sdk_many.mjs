// Host N agents in one Node process through a vendor SDK.
// usage: node sdk_many.mjs codex|claude <node_modules> N <workspace root>
import { pathToFileURL } from "node:url";
import { mkdirSync } from "node:fs";
const [which, nm, nStr, root] = process.argv.slice(2);
const n = Number(nStr);
const p = (i) => `Task ruiprobe${i}x: reply with the word hi.`;
if (which === "codex") {
  const { Codex } = await import(pathToFileURL(`${nm}/@openai/codex-sdk/dist/index.js`).href);
  const codex = new Codex();
  for (let i = 0; i < n; i++) {
    const cwd = `${root}/ws${i}`; mkdirSync(cwd, { recursive: true });
    const t = codex.startThread({ workingDirectory: cwd, skipGitRepoCheck: true });
    t.run(p(i)).catch((e) => console.error(`thread ${i}:`, e?.message));
  }
} else {
  const { query } = await import(pathToFileURL(`${nm}/@anthropic-ai/claude-agent-sdk/sdk.mjs`).href);
  for (let i = 0; i < n; i++) {
    const cwd = `${root}/ws${i}`; mkdirSync(cwd, { recursive: true });
    const q = query({ prompt: p(i), options: { cwd, model: "claude-sonnet-4-5" } });
    (async () => { try { for await (const m of q) {} } catch (e) { console.error(`query ${i}:`, e?.message); } })();
  }
}
console.log(`started ${n}`);
setInterval(() => {}, 1 << 30);
