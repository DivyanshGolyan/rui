import assert from "node:assert/strict";
import test from "node:test";

import { Session, Sessions, type SessionSpec, type SessionUpdate, type Link } from "../src/sessions.ts";
import type { components } from "../src/wire.ts";
import { WIRE_VERSION } from "../src/transport.ts";
import { RuiRequestError } from "../src/errors.ts";

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
	await session.update({ compactAt: 2000, effort: "none", label: null });
	await session.update({});
	const [first, second, third] = requests;
	assert.ok(first && second && third);
	assert.equal(first.version, WIRE_VERSION);
	assert.deepEqual(first.configuration, {
        tools: ["bash", "write"], compactAt: 0, effort: null, label: 'a"\nlabel',
    });
    assert.equal(second.configuration.compactAt, 2000);
    assert.equal(second.configuration.effort, "none");
    assert.equal(second.configuration.label, null);
    assert.deepEqual(third.configuration, {});
});

type CurrentReport = Extract<components["schemas"]["InspectSessionReply"], { profile: "current"; work: unknown }>;

function report(work: CurrentReport["work"], parent: string | null = null): CurrentReport {
	return {
		version: WIRE_VERSION, type: "session_report", delta: "full", since: null, profile: "current", archive_state: "active",
		session: {
			reference: "abc123", parent, workspace: "/work", provider: "openai", model: "model-a", revision: "1",
			tools: ["bash"], loaded_tools: ["bash"], permission_mode: "ask", label: "Review", created_at: "1",
			instructions: { bytes: "0", sha256: "0".repeat(64) }, output_schema: null,
			compaction_trigger: "100000", context_estimate: null, output_reservation: "0",
			compaction_trigger_override: null, output_reservation_override: null,
			reasoning_effort: "high", reasoning_effort_override: null,
		},
		pending_messages: "9007199254740993", work,
		peers: { from_person_at: null }, first_message: null, selected_message: null,
		recent_messages: [], actions: { count: "0", unresolved: [], resolved: [] },
		rejected_calls: { count: "0", items: [] }, actionable_permissions: [],
		execution: { status: "partial", dispatch_fenced: false, custody_occupied: "0", scratch_used_bytes: "0", unavailable: ["structured_output"] },
	};
}

const idleWork: CurrentReport["work"] = {
	state: { kind: "idle", since: "9007199254740993" }, turn: null, operation: null, first_action: null, latest_outcome: null,
};

test("status requests the Current profile and maps reported facts and parent losslessly", async () => {
	const latestOutcome = { code: "failed_saved", content: { bytes: "7", sha256: "a".repeat(64) } };
	for (const archiveState of ["active", "archiving", "archived"] as const) for (const parent of [null, "p4rent"]) {
		const link: Link = {
			async exchange(path, build) {
				assert.equal(path, "/v1/inspect-session");
				assert.deepEqual(JSON.parse(build('store"\n')), {
					version: WIRE_VERSION, kind: "inspect_session", store: 'store"\n', session: 'session"\n',
				});
				return Buffer.from(JSON.stringify({ ...report({ ...idleWork, latest_outcome: latestOutcome }, parent), archive_state: archiveState }));
			},
		};
		assert.deepEqual(await new Session(link, 'session"\n').status(), {
			archiveState, state: "idle", since: "9007199254740993", turn: null, operation: null, pendingMessages: "9007199254740993",
			parent, label: "Review", model: "model-a", effort: "high", tools: ["bash"], permissionMode: "ask", latestOutcome,
		});
	}
});

test("status reports a missing Session as a request error", async () => {
	const link: Link = { exchange: async () => Buffer.from(JSON.stringify({ session: null })) };
	await assert.rejects(new Session(link, "absent").status(), (error: unknown) => error instanceof RuiRequestError && error.code === "session_not_found");
});

test("interrupt selects its exact target from status and ignores non-model work", async () => {
	for (const state of ["idle", "approval", "bash", "working", "retrying", "pending"] as const) {
		const paths: string[] = [];
		const link: Link = {
			async exchange(path, build) {
				paths.push(path);
				if (path === "/v1/inspect-session") return Buffer.from(JSON.stringify(report({
					...idleWork, state: { kind: state, since: "1" }, turn: "7", operation: "19",
				})));
				assert.equal(path, "/v1/control/model-interruption");
				const body = JSON.parse(build("store"));
				assert.deepEqual(body.target, { session: "session", turn: "7", operation: "19" });
				assert.equal(body.kind, "model_interruption");
				assert.equal(typeof body.key, "string");
				return Buffer.from(JSON.stringify({ answer: { status: "accepted" } }));
			},
		};
		await new Session(link, "session").interrupt();
		assert.deepEqual(paths, ["working", "retrying", "pending"].includes(state)
			? ["/v1/inspect-session", "/v1/control/model-interruption"] : ["/v1/inspect-session"]);
	}
	let calls = 0;
	const link: Link = { exchange: async () => { calls++; return Buffer.from(JSON.stringify(report(idleWork))); } };
	await new Session(link, "session").interrupt();
	assert.equal(calls, 1);
});


test("creation sends explicit settings without Host client defaults", async () => {
	const spec: SessionSpec = { model: "custom-model", effort: null, compactAt: 1234, tools: [] as readonly string[], permissionMode: "ask" };
	const link: Link = {
		async exchange(_path, build) {
			const request = JSON.parse(build("store"));
			assert.equal(request.session, "");
			assert.deepEqual(request.configuration.model, "custom-model");
			assert.deepEqual(request.configuration.compactAt, 1234);
			assert.deepEqual(request.configuration.effort, null);
			assert.deepEqual(request.configuration.tools, []);
			assert.deepEqual(request.configuration.permissionMode, "ask");
			assert.deepEqual(request.configuration.provider, undefined);
			assert.deepEqual(request.configuration.workspace, undefined);
			return Buffer.from(JSON.stringify({ answer: { status: "accepted", session: "abc123" } }));
		},
	};
	assert.equal((await new Sessions(link).create(spec, { idempotencyKey: "create" })).id, "abc123");
});


test("model updates serialize without changing omitted settings", async () => {
	let calls = 0;
	const update: SessionUpdate = { model: "other-model" };
	const link: Link = {
		async exchange(path, build) {
			calls++;
			assert.equal(path, "/v1/configure");
			const request = JSON.parse(build("store"));
			assert.equal(request.session, "existing-session");
			assert.equal(request.key, "change-model");
			assert.deepEqual(request.configuration, { model: "other-model" });
			return Buffer.from(JSON.stringify({ answer: { status: "accepted" } }));
		},
	};
	await new Session(link, "existing-session").update(update, { idempotencyKey: "change-model" });
	assert.equal(calls, 1);
});

// Compile-time API contract checks; these declarations never send requests.
function sessionTypeContract(spec: SessionSpec): void {
	const { effort: _effort, ...withoutEffort } = spec;
	// @ts-expect-error creation must specify reasoning, even when explicitly null
	const missingEffort: SessionSpec = withoutEffort;
	// @ts-expect-error compaction is never nullable
	const nullCompaction: SessionUpdate = { compactAt: null };
	const sparse: SessionUpdate = {};
	void [missingEffort, nullCompaction, sparse];
}
void sessionTypeContract;

test("creation can name a preset without inventing missing fields", async () => {
	const link: Link = {
		async exchange(_path, build) {
			const request = JSON.parse(build("store"));
			assert.equal(request.preset, "review");
			assert.deepEqual(request.configuration.model, undefined);
			assert.deepEqual(request.configuration.tools, undefined);
			assert.deepEqual(request.configuration.effort, null);
			assert.deepEqual(request.configuration.outputSchema, null);
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

test("unknown tool refusals preserve MCP advisory detail through request errors", async () => {
	const message = "spec.tools: lookup is not a known tool; MCP server notes is unavailable and may provide it";
	for (const code of ["mcp_server_unavailable", "unknown_tool"] as const) {
		const detail = code === "mcp_server_unavailable" ? message : null;
		const link: Link = { exchange: async () => Buffer.from(JSON.stringify({ answer: { status: "rejected", code, message: detail } })) };
		const session = new Session(link, "abc123");
		const spec: SessionSpec = { model: "model-a", effort: null, compactAt: 1000, tools: ["lookup"], permissionMode: "ask" };
		for (const request of [
			() => new Sessions(link).create(spec, { idempotencyKey: "create" }),
			() => session.update({ tools: ["lookup"] }),
			() => session.send("task", { idempotencyKey: "send" }),
		]) {
			await assert.rejects(request(), (error: unknown) => error instanceof RuiRequestError && error.code === code && error.message === (detail ?? `Rui rejected the request: ${code}`));
		}
	}
});

test("create parent is a create-only relation in the shared wire spec", async () => {
    const requests: components["schemas"]["ConfigureRequest"][] = [];
    const link: Link = { async exchange(path, build) {
        assert.equal(path, "/v1/configure");
        requests.push(JSON.parse(build("store")));
        return Buffer.from(JSON.stringify({ context: { session: "child1" }, answer: { status: "accepted", session: "child1" } }));
    } };
    const sessions = new Sessions(link);
    await sessions.create({ parent: "p4rent", model: "model-a", tools: ["bash"], permissionMode: "ask", effort: null, compactAt: 1000 }, { idempotencyKey: "child" });
    assert.deepEqual(requests[0]?.configuration, { parent: "p4rent", model: "model-a", tools: ["bash"], permissionMode: "ask", effort: null, compactAt: 1000 });
    // @ts-expect-error parent cannot change on an existing Session
    const invalid: SessionUpdate = { parent: "p4rent" };
    void invalid;
});
