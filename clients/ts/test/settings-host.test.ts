// A real Host receives generated settings through the TypeScript client, then
// proves the selected provider, Bash budget and MCP Adapter at public boundaries.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { once } from "node:events";
import { mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { createSecureServer } from "node:http2";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { Rui, type HostSettings } from "../src/index.ts";

const binary = process.env.RUI_BINARY;
const socket = process.env.RUI_TEST_MYSQL_SOCKET;
const password = process.env.RUI_TEST_MYSQL_ROOT_PASSWORD;
const admin = process.env.RUI_TEST_MYSQL_ADMIN;
const mysqlRequired = (process.env.RUI_TEST_REQUIRE_ENGINES ?? "").split(",").includes("mysql");

function response(index: number): string {
	const output = index === 1 ? [
		{ type: "function_call", id: "bash-item", call_id: "bash-call", name: "bash", arguments: JSON.stringify({ cmd: "sleep 5", description: "Observe the configured Bash timeout" }) },
		{ type: "function_call", id: "mcp-item", call_id: "mcp-call", name: "settings_echo", arguments: "{}" },
	] : [
		{ type: "message", id: "answer-item", status: "completed", role: "assistant", phase: "final_answer", content: [{ type: "output_text", text: "settings verified", annotations: [] }] },
	];
	const events: object[] = [];
	for (const [output_index, item] of output.entries()) {
		events.push({ type: "response.output_item.added", output_index, item: { type: item.type, id: item.id } });
		events.push({ type: "response.output_item.done", output_index, item });
	}
	events.push({ type: "response.completed", response: { id: `settings-${index}`, status: "completed", model: "gpt-6.1-sol", output, usage: { input_tokens: 7, output_tokens: 11, total_tokens: 18 } } });
	return events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n";
}

for (const engine of ["sqlite", "mysql"] as const) {
	test(`TypeScript settings serve codex, the Bash timeout and MCP on ${engine}`, {
		skip: !binary ? "set RUI_BINARY to a built rui" : engine === "mysql" && !mysqlRequired && (!socket || !password) ? "no RUI_TEST_MYSQL_* server" : false,
		timeout: 30_000,
	}, async (t) => {
		assert.ok(binary);
		if (engine === "mysql") assert.ok(socket && password && admin, "the live MySQL suite must supply its server and admin helper");
		const root = realpathSync(mkdtempSync(join(tmpdir(), "rui-ts-settings-")));
		const cert = join(root, "cert.pem");
		const key = join(root, "key.pem");
		execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1", "-days", "1"], { stdio: "pipe" });
		const provider = createSecureServer({ key: readFileSync(key), cert: readFileSync(cert) });
		let modelCalls = 0;
		const providerAuth: unknown[] = [];
		provider.on("stream", (stream, headers) => {
			stream.resume();
			stream.on("end", () => {
				providerAuth.push(headers.authorization);
				if (headers[":path"] === "/v1/models") {
					stream.respond({ ":status": 200, "content-type": "application/json" });
					stream.end(JSON.stringify({ object: "list", data: [] }));
					return;
				}
				stream.respond({ ":status": 200, "content-type": "text/event-stream" });
				stream.end(response(++modelCalls));
			});
		});
		const methods: string[] = [];
		const authorizations: (string | undefined)[] = [];
		const mcp = createServer((request, reply) => {
			let body = "";
			request.on("data", (chunk: Buffer) => { body += chunk.toString("utf8"); });
			request.on("end", () => {
				const message = JSON.parse(body);
				methods.push(message.method);
				authorizations.push(request.headers.authorization);
				const result = message.method === "tools/list"
					? { tools: [{ name: "settings_echo", description: "Echo settings test", inputSchema: { type: "object", properties: {} } }] }
					: { content: [{ type: "text", text: "mcp-settings-ok" }] };
				reply.writeHead(200, { "content-type": "application/json", connection: "close" });
				reply.end(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
			});
		});
		provider.listen(0, "127.0.0.1");
		mcp.listen(0, "127.0.0.1");
		const tokenName = "RUI_TS_SETTINGS_MCP_TOKEN";
		const urlName = "RUI_TS_SETTINGS_MYSQL_URL";
		const oldToken = process.env[tokenName];
		const oldUrl = process.env[urlName];
		process.env[tokenName] = "settings-token";
		let rui: Rui | undefined;
		const database = `rui_ts_settings_${process.pid}_${engine}`;
		let created = false;
		const sql = (input: string) => execFileSync(admin!, [], { input, stdio: ["pipe", "pipe", "pipe"] });
		try {
			await Promise.all([once(provider, "listening"), once(mcp, "listening")]);
			const providerAddress = provider.address();
			const mcpAddress = mcp.address();
			assert.ok(providerAddress && typeof providerAddress !== "string");
			assert.ok(mcpAddress && typeof mcpAddress !== "string");
			let store: HostSettings["store"] = { sqlite: { dir: join(root, "store") } };
			if (engine === "mysql") {
				sql(`CREATE DATABASE ${database} CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_bin`);
				created = true;
				const schema = execFileSync(binary, ["store", "schema", "--engine", "mysql"], { encoding: "utf8" });
				sql(`USE ${database};\n${schema}`);
				process.env[urlName] = `mysql://root:${encodeURIComponent(password!)}@${encodeURIComponent(socket!)}/${database}`;
				store = { mysql: { url: { env: Buffer.from(urlName) } } };
			}
			rui = await Rui.connect({
				store,
				providers: { codex: { endpoint: `https://127.0.0.1:${providerAddress.port}/v1/responses`, unauthenticated: true } },
				network: { caFile: Buffer.from(cert) },
				tools: { bash: { timeoutMs: 37 }, mcp: { fixture: { url: `http://127.0.0.1:${mcpAddress.port}/mcp`, bearerToken: { env: tokenName }, callTimeoutMs: 1000 } } },
			}, { binary });
			assert.equal(rui.hostInfo?.capabilities.providers.codex, "endpoint");
			assert.equal(rui.hostInfo?.capabilities.providers.openai, "unserved");
			assert.equal(rui.hostInfo?.capabilities.providers.chatgpt, "unserved");
			assert.ok(methods.includes("tools/list"), "configured MCP Adapter must be listed during start");
			const session = await rui.sessions.create({
				provider: "codex", model: "gpt-6.1-sol", effort: "low", compactAt: 100000,
				workspace: root, tools: ["bash", "settings_echo"], permissionMode: "bypass",
			}, { idempotencyKey: "settings:create" });
			await session.send("Exercise both configured tools", { idempotencyKey: "settings:send" });
			const results: string[] = [];
			for await (const entry of session.listActivity({ follow: true, signal: AbortSignal.any([t.signal, AbortSignal.timeout(20_000)]) })) {
				if (entry.kind === "tool_result") results.push(entry.text ?? await session.readContent(entry));
				if (entry.kind === "turn_ended") {
					assert.equal(entry.ending, "done");
					break;
				}
			}
			assert.ok(results.some((text) => text.includes("37 ms total budget")), "Bash result must report the configured default timeout");
			assert.ok(results.some((text) => text.includes("mcp-settings-ok")), "configured MCP tool must execute");
			assert.ok(methods.includes("tools/call"));
			assert.ok(authorizations.every((value) => value === "Bearer settings-token"));
			assert.ok(providerAuth.every((value) => value === undefined), "codex development endpoint must stay unauthenticated");
			assert.equal(modelCalls, 2);
		} finally {
			try {
				await rui?.close();
			} finally {
				provider.close();
				mcp.closeAllConnections();
				mcp.close();
				try {
					if (created) sql(`DROP DATABASE IF EXISTS ${database}`);
				} finally {
					if (oldToken === undefined) delete process.env[tokenName]; else process.env[tokenName] = oldToken;
					if (oldUrl === undefined) delete process.env[urlName]; else process.env[urlName] = oldUrl;
					rmSync(root, { recursive: true, force: true });
				}
			}
		}
	});
}
