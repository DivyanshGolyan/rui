import assert from "node:assert/strict";
import { execFile, execFileSync } from "node:child_process";
import { once } from "node:events";
import { mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { createSecureServer } from "node:http2";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const binary = process.env.RUI_BINARY;
const repository = fileURLToPath(new URL("../../../", import.meta.url));
const client = fileURLToPath(new URL("../src/index.ts", import.meta.url));
const run = promisify(execFile);

/** The one `ts` block under `heading` in a Markdown file, exactly as a reader copies it. */
function example(file: string, heading: string): string {
	const text = readFileSync(join(repository, file), "utf8");
	const start = text.indexOf(`\n${heading}\n`);
	assert.notEqual(start, -1, `${file} has no "${heading}" section`);
	const section = text.slice(start + heading.length + 2).split(/\n#{1,2} /)[0] as string;
	const blocks = [...section.matchAll(/```ts\n([\s\S]*?)```/g)];
	assert.equal(blocks.length, 1, `${file} "${heading}" must hold exactly one ts example`);
	return (blocks[0] as RegExpMatchArray)[1] as string;
}

const EXAMPLES = [
	{ file: "README.md", heading: "## Start an agent from TypeScript" },
	{ file: "docs/integrating-rui.md", heading: "## Send work and wait for an answer" },
] as const;

/**
 * Runs every TypeScript example a new user copies, unchanged except for where `ruicode` points:
 * a stand-in that sends the example's own settings to a local provider and this build's `rui`.
 */
test("TS-9 the documented TypeScript examples answer and fail loudly", { skip: binary ? false : "set RUI_BINARY to a built rui", timeout: 60_000 }, async (t) => {
	const root = realpathSync(mkdtempSync(join(tmpdir(), "rui-ts-docs-")));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	const cert = join(root, "cert.pem");
	const key = join(root, "key.pem");
	execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1", "-days", "1"], { stdio: "pipe" });
	const provider = createSecureServer({ key: readFileSync(key), cert: readFileSync(cert) });
	provider.on("stream", (stream, headers) => {
		stream.resume();
		stream.on("end", () => {
			if (headers.authorization !== "Bearer good-key") {
				stream.respond({ ":status": 401, "content-type": "application/json" });
				stream.end(JSON.stringify({ error: { message: "Incorrect API key provided.", type: "invalid_request_error", code: "invalid_api_key" } }));
			} else if (headers[":path"] === "/v1/models") {
				stream.respond({ ":status": 200, "content-type": "application/json" });
				stream.end(JSON.stringify({ object: "list", data: [{ id: "model-a", object: "model", owned_by: "fixture" }] }));
			} else {
				const item = { type: "message", id: "msg-1", status: "completed", role: "assistant", phase: "final_answer", content: [{ type: "output_text", text: "fixture answer", annotations: [] }] };
				stream.respond({ ":status": 200, "content-type": "text/event-stream" });
				stream.end([
					{ type: "response.output_item.added", output_index: 0, item: { type: "message", id: item.id } },
					{ type: "response.output_item.done", output_index: 0, item },
					{ type: "response.completed", response: { id: "resp-1", status: "completed", model: "model-a", output: [item], usage: { input_tokens: 7, output_tokens: 3, total_tokens: 10 } } },
				].map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n");
			}
		});
	});
	provider.listen(0, "127.0.0.1");
	await once(provider, "listening");
	t.after(() => provider.close());
	const address = provider.address();
	assert.ok(address && typeof address !== "string");
	writeFileSync(join(root, "ruicode.mts"), `import { Rui as Client } from ${JSON.stringify(client)};
export const Rui = {
	connect(settings: any, options: any = {}) {
		const openai = { ...settings.providers.openai, endpoint: "https://127.0.0.1:${address.port}/v1/responses" };
		return Client.connect({ ...settings, providers: { openai }, network: { caFile: ${JSON.stringify(cert)} } }, { ...options, binary: ${JSON.stringify(binary)} });
	},
};
`);

	for (const { file, heading } of EXAMPLES) {
		const source = example(file, heading);
		assert.equal(source.split('from "ruicode"').length, 2, `${file} example must import ruicode once`);
		const name = `${file.replace(/\W/g, "-")}.mts`;
		writeFileSync(join(root, name), source.replace('from "ruicode"', 'from "./ruicode.mts"'));
		const execute = (env: Record<string, string>) => run(process.execPath, ["--experimental-strip-types", "--no-warnings", name], {
			cwd: root, env: { PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: root, TMPDIR: tmpdir(), RUI_MODEL: "model-a", ...env },
		});

		const answered = await execute({ OPENAI_API_KEY: "good-key" });
		assert.match(answered.stdout, /fixture answer/, `${file}: ${answered.stderr}`);

		await assert.rejects(execute({ OPENAI_API_KEY: "wrong-key" }), (error: { code?: number; stdout: string; stderr: string }) => {
			assert.notEqual(error.code, 0, file);
			assert.match(error.stderr, /provider_api_key_rejected/, `${file}: ${error.stderr}`);
			return true;
		});
		await assert.rejects(execute({}), (error: { code?: number; stdout: string; stderr: string }) => {
			assert.notEqual(error.code, 0, file);
			assert.match(error.stderr, /OPENAI_API_KEY/, `${file}: ${error.stderr}`);
			return true;
		});
	}
});
