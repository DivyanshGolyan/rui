import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { createServer, type ServerHttp2Session } from "node:http2";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { Rui, RuiRequestError } from "../src/index.ts";
import { WIRE_VERSION } from "../src/transport.ts";
import type { components } from "../src/wire.ts";

const binary = process.env.RUI_BINARY;

type CurrentReport = Extract<components["schemas"]["InspectSessionReply"], { profile: "current"; work: unknown }>;

async function currentReport(rui: Rui, session: string): Promise<CurrentReport> {
	return JSON.parse((await rui.exchange("/v1/inspect-session", (store) => JSON.stringify({
		version: WIRE_VERSION, kind: "inspect_session", store, session,
	} satisfies components["schemas"]["InspectSessionRequest"]))).toString("utf8")) as CurrentReport;
}

test("stopAction reaches the native owner and recovers its original answer", { skip: binary ? false : "set RUI_BINARY to a built rui", timeout: 30_000 }, async (t) => {
	const root = realpathSync(mkdtempSync(join(tmpdir(), "rui-ts-action-stop-")));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	let calls = 0;
	const connections = new Set<ServerHttp2Session>();
	const provider = createServer((request, response) => {
		request.resume();
		request.on("end", () => {
			if (request.url !== "/responses") {
				response.writeHead(200, { "content-type": "application/json" });
				response.end('{"data":[]}');
				return;
			}
			calls++;
			const item = calls === 1
				? { type: "function_call", id: "held-item", status: "completed", name: "bash", call_id: "held-call", arguments: JSON.stringify({ cmd: "exit 99", description: "Await approval" }) }
				: { type: "message", id: "done-item", status: "completed", role: "assistant", phase: "final_answer", content: [{ type: "output_text", text: "done", annotations: [] }] };
			const events = [
				{ type: "response.output_item.added", output_index: 0, item: { type: item.type, id: item.id } },
				{ type: "response.output_item.done", output_index: 0, item },
				{ type: "response.completed", response: { id: `response-${calls}`, status: "completed", output: [item] } },
			];
			response.writeHead(200, { "content-type": "text/event-stream" });
			response.end(events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n");
		});
	});
	provider.on("session", (connection) => {
		connections.add(connection);
		connection.on("close", () => connections.delete(connection));
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
		const spec = { workspace: root, connection: "codex", model: "gpt-6-sol", effort: "low", compactAt: 100000, tools: ["bash"], permissionMode: "ask" } satisfies Parameters<typeof rui.sessions.create>[0];
		const session = await rui.sessions.create(spec, { idempotencyKey: "session" });
		await session.send("run", { idempotencyKey: "message" });
		let action: string | undefined;
		for await (const entry of session.listActivity({ follow: true, signal: AbortSignal.any([t.signal, AbortSignal.timeout(20_000)]), kinds: ["approval_requested"] })) {
			if (entry.kind === "approval_requested") { action = entry.action; break; }
		}
		assert.ok(action, JSON.stringify({ calls, status: await session.status() }));
		const observe = JSON.parse((await rui.exchange("/v1/observe-command", (store) => JSON.stringify({
			version: WIRE_VERSION, kind: "observe_command", store, key: "message",
		} satisfies components["schemas"]["ObserveCommandRequest"]))).toString("utf8")) as components["schemas"]["ObserveCommandReply"];
		assert.ok("observation" in observe);
		const observation = observe.observation;
		assert.ok("kind" in observation && observation.kind === "message" && "work" in observation);
		assert.equal(observation.state, "waiting_for_permission");
		const waiting = await currentReport(rui, session.id);
		assert.deepEqual(observation.work, {
			state: waiting.work.state, first_action: waiting.work.first_action,
			actions: waiting.work.actions,
		});
		assert.equal(observation.work.state.kind, "approval");
		assert.equal(observation.work.first_action, action);
		assert.deepEqual(observation.work.actions, { stop: true, interrupt: null, decide: action });
		assert.deepEqual(waiting.actionable_permissions.map((permission) => permission.action), [action]);
		assert.equal(await session.stopAction(action, { idempotencyKey: "stop" }), null);
		const final = await session.readAction(action);
		assert.equal(final.state, "resolved");
		assert.ok(final.final);
		assert.equal(final.final.code, "cancelled");
		const current = await currentReport(rui, session.id);
		assert.deepEqual(current.actionable_permissions, []);
		assert.equal(current.work.first_action, null);
		assert.equal(current.work.actions.decide, null);
		assert.equal(await session.stopAction(action, { idempotencyKey: "stop" }), null);
		assert.equal(await session.stopAction(action, { idempotencyKey: "after" }), final.final.position);
		const foreign = await rui.sessions.create(spec, { idempotencyKey: "foreign" });
		await assert.rejects(foreign.stopAction(action), (error: unknown) => error instanceof RuiRequestError && error.code === "target_mismatch");
		await assert.rejects(session.stopAction("9223372036854775807"), (error: unknown) => error instanceof RuiRequestError && error.code === "unknown_action");
		await assert.rejects(session.stopAction("9223372036854775807", { idempotencyKey: "stop" }), (error: unknown) => error instanceof RuiRequestError && error.code === "idempotency_key_conflict");
	} finally {
		try { await rui?.close(); } finally {
			for (const connection of connections) connection.destroy();
			await new Promise<void>((resolve) => provider.close(() => resolve()));
		}
	}
});
