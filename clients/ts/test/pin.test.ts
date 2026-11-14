import assert from "node:assert/strict";
import { test } from "node:test";

import { RuiRequestError } from "../src/errors.ts";
import { SessionNotifications } from "../src/notifications.ts";
import { Session, type Link } from "../src/sessions.ts";
import { WIRE_VERSION } from "../src/transport.ts";

test("pin and unpin capture desired state and preserve keys across transport recovery", async () => {
	const activity = new SessionNotifications();
	const watch = activity.watch('session"\n');
	const bodies: unknown[] = [];
	let failReply = true;
	const link: Link = {
		activity,
		exchange: async (path, build) => {
			assert.equal(path, "/v1/control/session-pin");
			const body = JSON.parse(build('store"\n'));
			bodies.push(body);
			if (failReply) {
				failReply = false;
				throw new Error("lost reply");
			}
			return Buffer.from(JSON.stringify({ answer: {
				status: "accepted", replayed: bodies.length === 2, session: 'session"\n', pinned: body.pinned,
			} }));
		},
	};
	try {
		const session = new Session(link, 'session"\n');
		await assert.rejects(session.pin({ idempotencyKey: "pin:1" }), /lost reply/);
		assert.equal(watch.revision, 0);
		assert.deepEqual(await session.pin({ idempotencyKey: "pin:1" }), { pinned: true });
		assert.deepEqual(await session.unpin({ idempotencyKey: "unpin:1" }), { pinned: false });
		assert.equal(watch.revision, 2);
		assert.deepEqual(bodies, [true, true, false].map((pinned) => ({
			version: WIRE_VERSION, kind: "session_pin", store: 'store"\n', session: 'session"\n',
			key: pinned ? "pin:1" : "unpin:1", pinned,
		})));
	} finally {
		watch.close();
	}
});

test("pin refusals preserve server errors without activity or automatic retry", async () => {
	for (const code of ["invalid_session_reference", "unknown_session", "session_archiving", "session_archived", "idempotency_key_conflict"]) {
		const activity = new SessionNotifications();
		const watch = activity.watch("k7m2qx");
		let requests = 0;
		const session = new Session({ activity, exchange: async (path) => {
			requests++;
			assert.equal(path, "/v1/control/session-pin");
			return Buffer.from(JSON.stringify({ answer: {
				status: code === "idempotency_key_conflict" ? "conflict" : "rejected", code,
			} }));
		} }, "k7m2qx");
		try {
			await assert.rejects(session.pin(), (error: unknown) => error instanceof RuiRequestError && error.code === code);
			assert.equal(requests, 1);
			assert.equal(watch.revision, 0);
		} finally {
			watch.close();
		}
	}
});
