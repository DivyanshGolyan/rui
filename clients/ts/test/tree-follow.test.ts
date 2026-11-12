import assert from "node:assert/strict";
import { test } from "node:test";
import { listActivity } from "../src/feed.ts";
import type { Link } from "../src/sessions.ts";
import { SessionNotifications } from "../src/notifications.ts";

test("follow polls attached tree work after the root Turn ended and yields a forwarded approval", { timeout: 5000 }, async () => {
    let pages = 0;
    const controller = new AbortController();
    const link: Link = {
        activity: new SessionNotifications(),
        exchange: async (path) => {
            assert.equal(path, "/v1/activity-page");
            pages++;
            return Buffer.from(JSON.stringify({
                delta: "full", since: String(pages), end: String(pages), more: false,
                queued: { count: "0" },
                work: { state: { kind: "working", since: "1" }, turn: "1", operation: "1", first_action: null },
                items: pages === 1 ? [{ position: "1", ordinal: "0", at: "1", value: { turn_ended: { session: "r00t00", turn: "1", ending: "done", content: null } } }]
                    : pages === 2 ? []
                    : [{ position: "2", ordinal: "0", at: "2", value: { approval_requested: { session: "ch1ld1", action: "2", operation: "2", call_ordinal: "0" } } }],
            }));
        },
    };
    const feed = listActivity(link, "r00t00", { follow: true, signal: controller.signal });
    try {
        assert.equal((await feed.next()).value?.kind, "turn_ended");
        const approval = (await feed.next()).value;
        assert.equal(approval?.kind, "approval_requested");
        if (approval?.kind === "approval_requested") assert.equal(approval.sessionId, "ch1ld1");
        assert.equal(pages, 3, "no client write or notification is needed for a child approval");
    } finally {
        controller.abort();
        await feed.return();
    }
});
