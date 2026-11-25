import assert from "node:assert/strict";
import { test } from "node:test";

import { Session } from "../src/sessions.ts";
import { scriptedLink, settle } from "./scripted-line.ts";

// A Session's watch crosses its attached tree: the Host nudges the root when a child's commit reaches the root's feed.
// Each nudge below plays one such commit, so each read sees the page the Host would serve then.

test("follow crosses attached tree work after the root Turn ended and yields a forwarded approval", { timeout: 5000 }, async () => {
	let pages = 0;
	const controller = new AbortController();
	const line = scriptedLink(async (path) => {
		assert.equal(path, "/v1/activity-page");
		pages++;
		return Buffer.from(JSON.stringify({
			delta: "full", since: String(pages), end: String(pages), more: false,
			queued: { count: "0" },
			work: { actions: { stop: false, interrupt: null, decide: null }, state: { kind: "working", since: "1" }, turn: "1", operation: "1", first_action: null },
			items: pages === 1 ? [{ position: "1", ordinal: "0", at: "1", value: { turn_ended: { session: "r00t00", turn: "1", ending: "done", content: null } } }]
				: pages === 2 ? []
				: [{ position: "2", ordinal: "0", at: "2", value: { approval_requested: { session: "ch1ld1", action: "2", operation: "2", call_ordinal: "0", description: "Fetch page", tool: "fetch_page", server: "docs" } } }],
		}));
	});
	const watch = new Session(line.link, "r00t00").watch({ signal: controller.signal });
	try {
		assert.equal((await watch.next()).value?.kind, "turn_ended");
		const approval = watch.next();
		await settle();
		line.changed("r00t00");
		await settle();
		assert.equal(pages, 2, "an empty commit page is read and yields nothing");
		line.changed("r00t00");
		const value = (await approval).value;
		assert.equal(value?.kind, "approval_requested");
		if (value?.kind === "approval_requested") assert.equal(value.sessionId, "ch1ld1");
		assert.equal(pages, 3);
	} finally {
		controller.abort();
		await watch.return(undefined);
	}
});

test("follow crosses an ending-publication gap and the owed Message's next Turn", { timeout: 5000 }, async () => {
	let pages = 0;
	const controller = new AbortController();
	const line = scriptedLink(async (path) => {
		assert.equal(path, "/v1/activity-page");
		pages++;
		const session = pages === 3 ? "ch1ld1" : "r00t00";
		const turn = pages < 3 ? "1" : pages === 3 ? "2" : "3";
		return Buffer.from(JSON.stringify({
			delta: "full", since: String(pages), end: String(pages), more: false,
			queued: { count: "0" },
			work: { actions: { stop: false, interrupt: null, decide: null }, state: { kind: pages < 5 ? "working" : "finished", since: "1" }, turn: pages < 4 ? "1" : "3", operation: null, first_action: null },
			items: pages === 2 || pages === 4 ? [] : [{ position: String(pages), ordinal: "0", at: "1", value: { turn_ended: { session, turn, ending: "done", content: null } } }],
		}));
	});
	const watch = new Session(line.link, "r00t00").watch({ signal: controller.signal });
	try {
		const first = (await watch.next()).value;
		assert.equal(first?.kind, "turn_ended");
		if (first?.kind === "turn_ended") assert.equal(first.turn, "1");
		const ending = watch.next();
		await settle();
		line.changed("r00t00");
		await settle();
		line.changed("r00t00");
		const endingValue = (await ending).value;
		assert.equal(endingValue?.kind, "turn_ended");
		if (endingValue?.kind === "turn_ended") assert.equal(endingValue.sessionId, "ch1ld1");
		const next = watch.next();
		await settle();
		line.changed("r00t00");
		await settle();
		line.changed("r00t00");
		const nextValue = (await next).value;
		assert.equal(nextValue?.kind, "turn_ended");
		if (nextValue?.kind === "turn_ended") assert.equal(nextValue.turn, "3");
		assert.equal(pages, 5, "each commit is one read; an idle tree between them makes none");
	} finally {
		controller.abort();
		await watch.return(undefined);
	}
});
