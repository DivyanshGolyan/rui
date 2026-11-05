import assert from "node:assert/strict";
import test from "node:test";

import { FEED_KINDS } from "../src/feed.ts";
import { Session, Sessions, type SessionSpec, type SessionUpdate, type Link } from "../src/sessions.ts";
import type { components } from "../src/wire.ts";
import { WIRE_VERSION } from "../src/transport.ts";

test("configuration preserves omitted, null and value states and normalizes tools", async () => {
	const requests: components["schemas"]["ConfigureRequest"][] = [];
	const link: Link = {
		async exchange(_path, build) {
			requests.push(JSON.parse(build("store")));
			return Buffer.from(JSON.stringify({ answer: { status: "accepted" } }));
		},
	};
	const session = new Session(link, "session");
	await session.update({ tools: ["write", "bash", "write"], compactAt: 0, effort: null, label: 'a"\nlabel' });
	await session.update({ compactAt: 2000, effort: "", label: null });
	await session.update({});
	const [first, second, third] = requests;
	assert.ok(first && second && third);
	assert.equal(first.version, WIRE_VERSION);
	assert.deepEqual(first.configuration, {
		workspace: { state: "omitted" },
		provider: { state: "omitted" },
		model: { state: "omitted" },
		instructions: { state: "omitted" },
		tools: { state: "value", value: ["bash", "write"] },
		permission_mode: { state: "omitted" },
		output_schema: { state: "omitted" },
		compaction_trigger: { state: "value", value: "0" },
		output_reservation: { state: "omitted" },
		reasoning_effort: { state: "null" },
		label: { state: "value", value: 'a"\nlabel' },
	});
	assert.deepEqual(second.configuration.compaction_trigger, { state: "value", value: "2000" });
	assert.deepEqual(second.configuration.reasoning_effort, { state: "value", value: "" });
	assert.deepEqual(second.configuration.label, { state: "null" });
	for (const field of Object.values(third.configuration)) assert.deepEqual(field, { state: "omitted" });
});

test("interrupt requests every feed kind", async () => {
	const link: Link = {
		async exchange(path, build) {
			assert.equal(path, "/v1/activity-page");
			assert.deepEqual(JSON.parse(build("store")), {
				version: WIRE_VERSION, kind: "activity_page", store: "store", session: "session",
				end: null, position: "0", ordinal: null, direction: "backward", kinds: [...FEED_KINDS], limit: "1",
			});
			return Buffer.from(JSON.stringify({ work: { turn: null, operation: null, state: { kind: "idle" } } }));
		},
	};
	await new Session(link, "session").interrupt();
});


test("creation sends explicit settings without Host client defaults", async () => {
	const spec: SessionSpec = { model: "custom-model", effort: null, compactAt: 1234, tools: [] as readonly string[], permissionMode: "ask" };
	const link: Link = {
		async exchange(_path, build) {
			const request = JSON.parse(build("store"));
			assert.equal(request.session, "");
			assert.deepEqual(request.configuration.model, { state: "value", value: "custom-model" });
			assert.deepEqual(request.configuration.compaction_trigger, { state: "value", value: "1234" });
			assert.deepEqual(request.configuration.reasoning_effort, { state: "null" });
			assert.deepEqual(request.configuration.tools, { state: "value", value: [] });
			assert.deepEqual(request.configuration.permission_mode, { state: "value", value: "ask" });
			assert.deepEqual(request.configuration.provider, { state: "omitted" });
			assert.deepEqual(request.configuration.workspace, { state: "omitted" });
			return Buffer.from(JSON.stringify({ answer: { status: "accepted", session: "abc123" } }));
		},
	};
	assert.equal((await new Sessions(link).create(spec, { idempotencyKey: "create" })).id, "abc123");
});


// Compile-time API contract checks; these declarations never send requests.
function sessionTypeContract(spec: SessionSpec): void {
	const { effort: _effort, ...withoutEffort } = spec;
	// @ts-expect-error creation must specify reasoning, even when explicitly null
	const missingEffort: SessionSpec = withoutEffort;
	// @ts-expect-error compaction is never nullable
	const nullCompaction: SessionUpdate = { compactAt: null };
	// @ts-expect-error model is immutable
	const immutable: SessionUpdate = { model: "other" };
	const sparse: SessionUpdate = {};
	void [missingEffort, nullCompaction, immutable, sparse];
}
void sessionTypeContract;

test("creation can name a preset without inventing missing fields", async () => {
	const link: Link = {
		async exchange(_path, build) {
			const request = JSON.parse(build("store"));
			assert.equal(request.preset, "review");
			assert.deepEqual(request.configuration.model, { state: "omitted" });
			assert.deepEqual(request.configuration.tools, { state: "omitted" });
			assert.deepEqual(request.configuration.reasoning_effort, { state: "null" });
			assert.deepEqual(request.configuration.output_schema, { state: "null" });
			return Buffer.from(JSON.stringify({ answer: { status: "accepted", session: "abc123" } }));
		},
	};
	await new Sessions(link).create({ preset: "review", effort: null, outputSchema: null }, { idempotencyKey: "preset" });
});

function presetTypeContract(sessions: Sessions): void {
	void sessions.create({ preset: "review" }, { idempotencyKey: "preset" });
	// @ts-expect-error neither a full spec nor a preset
	void sessions.create({}, { idempotencyKey: "empty" });
	// @ts-expect-error a partial spec needs a preset
	void sessions.create({ instructions: "Do this" }, { idempotencyKey: "partial" });
	// @ts-expect-error a preset name is never null
	void sessions.create({ preset: null }, { idempotencyKey: "null" });
	// @ts-expect-error presets only seed creation
	const update: SessionUpdate = { preset: "review" };
	void update;
}
void presetTypeContract;
