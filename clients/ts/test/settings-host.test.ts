// A real Host receives generated settings through the TypeScript client, then
// proves the selected provider, Bash budget and MCP Adapter at public boundaries.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { once } from "node:events";
import { mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { createSecureServer } from "node:http2";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { setTimeout as delay } from "node:timers/promises";

import { Rui, type HostSettings } from "../src/index.ts";
import { WIRE_VERSION } from "../src/transport.ts";
import type { components } from "../src/wire.ts";

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

for (const [engine, adapter] of [["sqlite", "codex"], ["mysql", "codex"], ["mysql", "chatgpt"]] as const) {
	test(`TypeScript settings serve ${adapter}, the Bash timeout, MCP${adapter === "chatgpt" ? " and presets" : ""} on ${engine}`, {
		skip: !binary ? "set RUI_BINARY to a built rui" : engine === "mysql" && !mysqlRequired && (!socket || !password) ? "no RUI_TEST_MYSQL_* server" : false,
		timeout: 30_000,
	}, async (t) => {
		assert.ok(binary);
		if (engine === "mysql") assert.ok(socket && password && admin, "the live MySQL suite must supply its server and admin helper");
		const root = realpathSync(mkdtempSync(join(tmpdir(), "rui-ts-settings-")));
		const cert = join(root, "cert.pem");
		const key = join(root, "key.pem");
		execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1", "-days", "1"], { stdio: "pipe" });
		const token = `e30.${Buffer.from(JSON.stringify({ exp: 4102444800 })).toString("base64url")}.c2ln`;
		let modelCalls = 0;
		const providerAuth: unknown[] = [];
		const providerRequests: string[] = [];
		function answer(method: string | undefined, path: string | undefined, authorization: unknown) {
			providerRequests.push(`${method} ${path}`);
			assert.equal(method, path === "/v1/models" ? "GET" : "POST");
			providerAuth.push(authorization);
			if (path === "/v1/models") return {
				type: "application/json",
				body: JSON.stringify(adapter === "chatgpt" ? { models: [{ slug: "gpt-6.1-sol", display_name: "Fixture Sol", visibility: "list" }] } : { object: "list", data: [] }),
			};
			assert.equal(path, "/v1/responses");
			return { type: "text/event-stream", body: response(++modelCalls) };
		}
		// The plan fixture's existing loopback-only test transport is HTTP/1.1.
		const provider = adapter === "chatgpt" ? createServer((request, reply) => {
			request.resume();
			request.on("end", () => {
				const result = answer(request.method, request.url, request.headers.authorization);
				reply.writeHead(200, { "content-type": result.type, "content-length": Buffer.byteLength(result.body), connection: "close" });
				reply.end(result.body);
			});
		}) : createSecureServer({ key: readFileSync(key), cert: readFileSync(cert) }).on("stream", (stream, headers) => {
			stream.resume();
			stream.on("end", () => {
				const result = answer(headers[":method"], headers[":path"], headers.authorization);
				stream.respond({ ":status": 200, "content-type": result.type });
				stream.end(result.body);
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
		const database = `rui_ts_settings_${process.pid}_${engine}_${adapter}`;
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
			const endpoint = `${adapter === "chatgpt" ? "http" : "https"}://127.0.0.1:${providerAddress.port}/v1/responses`;
			const credentialFile = join(root, "chatgpt.json");
			let clientBinary = binary;
			if (adapter === "chatgpt") {
				// Same private v3 fixture record as chatgpt_plan_integration.py; never a real sign-in.
				const id = `e30.${Buffer.from(JSON.stringify({ sub: "plan-subject" })).toString("base64url")}.c2ln`;
				writeFileSync(credentialFile, `version=3\ngeneration=1\naccount_id=plan-subject\nclient_id=rui-test-plan-client\nfedramp=0\nid_token=${id}\naccess_token=${token}\nrefresh_token=fixture-refresh\nexpires_at=4102444800\nrefreshed_at=1750000000\nstate=ready\n`, { mode: 0o600 });
				const quote = (text: string) => "'" + text.replaceAll("'", "'\"'\"'") + "'";
				clientBinary = join(root, "fixture-rui");
				// exec keeps child ownership intact; only this test wrapper selects fixture transport.
				// The hidden fixture flag requires this env path even with an explicit credentialFile.
				writeFileSync(clientBinary, `#!/bin/sh\nexport RUI_CHATGPT_CREDENTIAL_FILE=${quote(credentialFile)}\nexec ${quote(binary)} "$@" --test-chatgpt-fixture-endpoint ${quote(endpoint)}\n`, { mode: 0o700 });
			}
			const spec = {
				provider: adapter, model: "gpt-6.1-sol", effort: "low" as const, compactAt: 100000,
				workspace: root, tools: ["bash", "settings_echo"], permissionMode: "bypass" as const,
			};
			rui = await Rui.connect({
				store,
				providers: adapter === "codex" ? { codex: { endpoint, unauthenticated: true } } : { chatgpt: { endpoint, credentialFile: Buffer.from(credentialFile) } },
				...(adapter === "codex" ? { network: { caFile: Buffer.from(cert) } } : {}),
				...(adapter === "chatgpt" ? { presets: { drift: spec } } : {}),
				tools: { bash: { timeoutMs: 37 }, mcp: { fixture: { url: `http://127.0.0.1:${mcpAddress.port}/mcp`, bearerToken: { env: tokenName }, callTimeoutMs: 1000 } } },
			}, { binary: clientBinary });
			assert.equal(rui.hostInfo?.capabilities.providers.codex, adapter === "codex" ? "endpoint" : "unserved");
			assert.equal(rui.hostInfo?.capabilities.providers.openai, "unserved");
			assert.equal(rui.hostInfo?.capabilities.providers.chatgpt, adapter === "chatgpt" ? "chatgpt_plan" : "unserved");
			assert.ok(methods.includes("tools/list"), "configured MCP Adapter must be listed during start");
			if (adapter === "chatgpt") {
				// Model-list refresh is asynchronous; the catalog may already contain this slug.
				const deadline = AbortSignal.any([t.signal, AbortSignal.timeout(10_000)]);
				for (;;) {
					deadline.throwIfAborted();
					const bytes = await rui.exchange("/v1/model-list", (canonicalStore) => JSON.stringify({
						version: WIRE_VERSION, kind: "model_list", store: canonicalStore,
					}), undefined, { responseMs: 1000 });
					const reply = JSON.parse(bytes.toString("utf8")) as components["schemas"]["ModelListReply"];
					const current = reply.providers.find((entry) => entry.provider === "chatgpt");
					if (current?.source === "live" && current.models.some((model) => model.id === "gpt-6.1-sol")) break;
					await delay(100, undefined, { signal: deadline });
				}
				const listed = await rui.models();
				assert.ok(listed.some((model) => model.provider === "chatgpt" && model.id === "gpt-6.1-sol"), "live ChatGPT listing must offer the preset's fixture model");
				assert.ok(providerRequests.includes("GET /v1/models"), "live listing must reach the sign-in fixture, not unknown-model fallback");
			}
			const session = await rui.sessions.create(adapter === "chatgpt" ? { preset: "drift" } : spec, { idempotencyKey: "settings:create" });
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
			assert.ok(providerAuth.length >= 2);
			assert.ok(providerAuth.every((value) => value === (adapter === "chatgpt" ? `Bearer ${token}` : undefined)), "the selected Adapter must use exactly its sign-in or unauthenticated fixture");
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
