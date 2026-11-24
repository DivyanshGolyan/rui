import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { Rui, RuiRequestError } from "../src/index.ts";
import { Session, Sessions, type AppToolSpec, type Link } from "../src/sessions.ts";
import { WIRE_VERSION } from "../src/transport.ts";

const binary = process.env.RUI_BINARY;

const alpha: AppToolSpec = {
	name: "alpha",
	description: "Alpha runs the first app tool.",
	inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"] },
	replay: "safe",
	restartLimit: 2,
	waitMs: 5000,
};
const beta: AppToolSpec = { name: "beta", description: "Beta has the default policy.", inputSchema: { type: "object" } };
const gamma: AppToolSpec = { name: "gamma", description: "Gamma replaces the set.", inputSchema: { type: "object" } };

test("TS-16 app_tools_request_shape sends appTools in the configure request with wire names", async () => {
	const bodies: { configuration: Record<string, unknown>; session: string }[] = [];
	const link: Link = {
		async exchange(path, build) {
			assert.equal(path, "/v1/configure");
			const request = JSON.parse(build("/store"));
			bodies.push({ configuration: request.configuration, session: request.session });
			return Buffer.from(JSON.stringify({ answer: { status: "accepted", session: "abc123" } }));
		},
	};
	await new Sessions(link).create({ workspace: "/caller", model: "gpt-6.1-sol", appTools: [alpha, beta] }, { idempotencyKey: "app-tools:create" });
	await new Session(link, "abc123").update({ appTools: [] }, { idempotencyKey: "app-tools:clear" });
	assert.deepEqual(bodies[0]!.configuration.appTools, [
		{ name: "alpha", description: alpha.description, input_schema: alpha.inputSchema, replay: "safe", restart_limit: 2, wait_ms: 5000 },
		{ name: "beta", description: beta.description, input_schema: beta.inputSchema },
	]);
	assert.deepEqual(bodies[1]!.configuration, { appTools: [] });
});

test("TS-16 app_tools_round_trip declares, replaces, clears and refuses a child on a real Host", { skip: binary ? false : "set RUI_BINARY to a built rui", timeout: 60_000 }, async (t) => {
	const root = realpathSync(mkdtempSync(join(tmpdir(), "rui-ts-app-tools-")));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	const provider = createServer((request, response) => {
		request.resume();
		request.on("end", () => {
			response.writeHead(200, { "content-type": "application/json" });
			response.end('{"data":[]}');
		});
	});
	provider.listen(0, "127.0.0.1");
	await once(provider, "listening");
	const address = provider.address();
	assert.ok(address && typeof address !== "string");
	let rui: Rui | undefined;
	try {
		rui = await Rui.connect({
			store: { sqlite: { dir: join(root, "store") } },
			providers: { codex: { endpoint: `http://127.0.0.1:${address.port}/responses`, unauthenticated: true } },
		}, { binary: binary ?? "rui" });
		const session = await rui.sessions.create({
			workspace: root, connection: "codex", model: "gpt-6-sol", effort: "low", compactAt: 100000, tools: ["bash"], permissionMode: "ask", appTools: [alpha, beta],
		}, { idempotencyKey: "app-tools:root" });
		assert.deepEqual((await session.status()).appTools, ["alpha", "beta"]);

		await session.update({ appTools: [gamma] }, { idempotencyKey: "app-tools:replace" });
		assert.deepEqual((await session.status()).appTools, ["gamma"]);

		await session.update({ appTools: [] }, { idempotencyKey: "app-tools:clear" });
		assert.deepEqual((await session.status()).appTools, []);

		const child = rui.sessions.create({ parent: session.id, model: "gpt-6-sol", tools: ["bash"], permissionMode: "ask", appTools: [alpha] }, { idempotencyKey: "app-tools:child" });
		await assert.rejects(child, (error: unknown) => error instanceof RuiRequestError && error.code === "app_tools_on_child");
	} finally {
		await rui?.close();
		provider.close();
	}
});
