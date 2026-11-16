import assert from "node:assert/strict";
import { test } from "node:test";

import { RuiRequestError } from "../src/errors.ts";
import { SessionNotifications } from "../src/notifications.ts";
import { Session, type SessionGroupAction } from "../src/sessions.ts";
import { WIRE_VERSION } from "../src/transport.ts";

test("group operations preserve the exact desired action and notify only accepted edits", async () => {
	const actions: SessionGroupAction[] = [
		{ group_action: "assign", group_name: 'Work "雪"' },
		{ group_action: "leave" },
		{ group_action: "automatic" },
		{ group_action: "rename", group_id: "9007199254740993", group_name: "Release" },
		{ group_action: "collapse", group_id: "7", collapsed: true },
		{ group_action: "collapse", group_id: "7", collapsed: false },
	];
	const activity = new SessionNotifications();
	const watch = activity.watch("k7m2qx");
	const requests: unknown[] = [];
	const session = new Session({ activity, exchange: async (path, build) => {
		assert.equal(path, "/v1/control/session-group");
		requests.push(JSON.parse(build('store"\n')));
		return Buffer.from(JSON.stringify({ answer: { status: "accepted", replayed: false, session: "k7m2qx" } }));
	} }, "k7m2qx");
	try {
		for (const [index, action] of actions.entries()) {
			assert.equal(await session.group(action, { idempotencyKey: `group:${index}` }), undefined);
		}
		assert.equal(watch.revision, actions.length);
		assert.deepEqual(requests, actions.map((action, index) => ({ ...action,
			version: WIRE_VERSION, kind: "session_group", store: 'store"\n', key: `group:${index}`, session: "k7m2qx",
		})));
	} finally {
		watch.close();
	}
});

test("lost group replies preserve keys and saved refusals do not retry or notify", async () => {
	for (const code of ["unknown_session", "invalid_group_name", "unknown_group", "group_name_exists", "invalid_group_id", "idempotency_key_conflict"]) {
		const activity = new SessionNotifications();
		const watch = activity.watch("k7m2qx");
		const requests: unknown[] = [];
		const session = new Session({ activity, exchange: async (_, build) => {
			requests.push(JSON.parse(build("store")));
			if (requests.length === 1) throw new Error("lost reply");
			return Buffer.from(JSON.stringify({ answer: { status: code === "idempotency_key_conflict" ? "conflict" : "rejected", code } }));
		} }, "k7m2qx");
		try {
			await assert.rejects(session.group({ group_action: "leave" }, { idempotencyKey: "original" }), /lost reply/);
			await assert.rejects(session.group({ group_action: "leave" }, { idempotencyKey: "original" }),
				(error: unknown) => error instanceof RuiRequestError && error.code === code);
			assert.equal(requests.length, 2);
			assert.deepEqual(requests[0], requests[1]);
			assert.equal(watch.revision, 0);
		} finally {
			watch.close();
		}
	}
});
