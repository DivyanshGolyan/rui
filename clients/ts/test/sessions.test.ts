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

const spec = { workspace: tmpdir(), provider: "openai", model: "gpt-6.1-sol", effort: "low", compactAt: 100000, tools: ["bash" as const], permissionMode: "ask" as const, label: "first" };

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
		assert.deepEqual(listed.map((each) => [each.id, each.label, each.parent]), [[session.id, "first", null]]);

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

test("list returns newest first across page boundaries", { skip }, async () => {
	const rui = await connect();
	try {
		const ids = [];
		for (let index = 0; index < 11; index++) ids.push((await rui.sessions.create(spec, { idempotencyKey: `chat:order-${index}` })).id);
		assert.deepEqual((await rui.sessions.list()).map((each) => each.id), ids.reverse());
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

test("the feed lists entries, continues after a cursor, and reads long text", { skip }, async () => {
	const rui = await connect();
	try {
		await rui.pause();
		const session = await rui.sessions.create(spec, { idempotencyKey: "chat:feed" });
		const long = "é".repeat(20_000);
		await session.send("first", { idempotencyKey: "msg:a" });
		await session.send(long, { idempotencyKey: "msg:b" });

		const all = [];
		for await (const entry of session.listActivity({ kinds: ["admission"] })) all.push(entry);
		assert.equal(all.length, 2);
		assert.equal(all[0]?.kind, "admission");
		assert.equal(all[0]?.text, "first");
		assert.equal(all[0]?.key, "msg:a");
		assert.equal(all[1]?.truncated, true);
		assert.equal(all[1]?.text, undefined);
		assert.equal(await session.readContent(all[1] as never), long);
		assert.deepEqual(await session.readContentBytes(all[1] as never), Buffer.from(long));

		const rest = [];
		for await (const entry of session.listActivity({ kinds: ["admission"], after: all[0]?.cursor as string })) rest.push(entry);
		assert.deepEqual(rest.map((entry) => entry.cursor), [all[1]?.cursor]);

		// Following never ends: it yields what arrives and stops when the consumer does.
		const followed = session.listActivity({ kinds: ["admission"], after: all[1]?.cursor as string, follow: true });
		const next = followed.next();
		await session.send("third", { idempotencyKey: "msg:c" });
		assert.equal((await next).value?.text, "third");
		await followed.return(undefined);
	} finally {
		await rui.close();
	}
});

test("an idle following feed ends when its signal aborts", { skip }, async () => {
	const rui = await connect();
	try {
		await rui.pause();
		const session = await rui.sessions.create(spec, { idempotencyKey: "chat:abort" });
		const controller = new AbortController();
		const followed = session.listActivity({ follow: true, signal: controller.signal });
		const pending = followed.next(); // nothing will arrive
		setTimeout(() => controller.abort(), 300);
		const result = await Promise.race([pending, new Promise((resolve) => setTimeout(() => resolve("hung"), 5_000))]);
		assert.deepEqual(result, { value: undefined, done: true });
	} finally {
		await rui.close();
	}
});

test("inline text keeps its last character and kind filters may come in any order", { skip }, async () => {
	const rui = await connect();
	try {
		await rui.pause();
		const session = await rui.sessions.create(spec, { idempotencyKey: "chat:tail" });
		const texts = ["tail é", "tail €", "tail 😀"];
		for (const [index, text] of texts.entries()) await session.send(text, { idempotencyKey: `msg:${index}` });
		const seen = [];
		for await (const entry of session.listActivity({ kinds: ["stop", "admission", "admission"] })) {
			if (entry.kind === "admission") seen.push(entry.text);
		}
		assert.deepEqual(seen, texts);
	} finally {
		await rui.close();
	}
});
