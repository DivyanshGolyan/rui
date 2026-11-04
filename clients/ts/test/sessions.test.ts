// Sessions against a real Rui, with the Host paused so no model call is made.
import assert from "node:assert/strict";
import { mkdtempSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { Rui, RuiRequestError } from "../src/index.ts";

const binary = process.env.RUI_BINARY;
const skip = binary ? false : "set RUI_BINARY to a built rui";

async function connect(): Promise<Rui> {
	const root = realpathSync(mkdtempSync(join(tmpdir(), "rui-ts-")));
	return Rui.connect({
		database: join(root, "store"),
		provider: { baseUrl: "https://api.openai.com/v1", key: "sk-ts-client-test" },
		binary: binary ?? "rui",
	});
}

const spec = { workspace: tmpdir(), provider: "openai", model: "gpt-6.1-sol", tools: ["bash" as const], permissionMode: "ask" as const, label: "first" };

test("create, list, send, update, interrupt and stop a Session", { skip }, async () => {
	const rui = await connect();
	try {
		await rui.pause();
		const session = await rui.sessions.create(spec, { idempotencyKey: "chat:1" });
		assert.match(session.id, /^[0-9a-z]{6}$/);

		// A repeat of the same key returns the same Session; changed input conflicts.
		assert.equal((await rui.sessions.create(spec, { idempotencyKey: "chat:1" })).id, session.id);
		await assert.rejects(
			rui.sessions.create({ ...spec, label: "other" }, { idempotencyKey: "chat:1" }),
			(error: unknown) => error instanceof RuiRequestError && error.code === "idempotency_key_conflict",
		);

		const listed = await rui.sessions.list();
		assert.deepEqual(listed.map((each) => [each.id, each.label]), [[session.id, "first"]]);

		const receipt = await session.send("hello", { idempotencyKey: "msg:1", env: { PATH: "/usr/bin" } });
		assert.match(receipt.messageId, /^[0-9]+$/);
		assert.equal((await session.send("hello", { idempotencyKey: "msg:1" })).messageId, receipt.messageId);

		await session.update({ label: "renamed" });
		assert.equal((await rui.sessions.list())[0]?.label, "renamed");
		await session.update({ label: null });
		assert.equal((await rui.sessions.list())[0]?.label, null);

		await session.interrupt(); // no model call is current: nothing is sent
		await session.stop();

		await assert.rejects(
			rui.getSession("zzzzzz").update({ label: "x" }),
			(error: unknown) => error instanceof RuiRequestError && error.code === "unknown_session",
		);
	} finally {
		await rui.close();
	}
});

test("models lists each provider's models", { skip }, async () => {
	const rui = await connect();
	try {
		const models = await rui.models();
		assert.ok(models.some((model) => model.provider === "openai" && model.id === "gpt-6.1-sol" && model.known), JSON.stringify(models));
	} finally {
		await rui.close();
	}
});

test("a paused Host takes Messages and resumes", { skip }, async () => {
	const rui = await connect();
	try {
		await rui.pause();
		await rui.resume();
		await rui.pause();
	} finally {
		await rui.close();
	}
});
