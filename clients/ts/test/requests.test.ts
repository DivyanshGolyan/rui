import assert from "node:assert/strict";
import test from "node:test";

import { FEED_KINDS } from "../src/feed.ts";
import { Session, type Link } from "../src/sessions.ts";
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
	await session.update({ compactAt: null, effort: "", label: null });
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
	assert.deepEqual(second.configuration.compaction_trigger, { state: "null" });
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
