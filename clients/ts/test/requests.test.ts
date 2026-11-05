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
	assert.deepEqual(second.configuration.reasoning_effort, { state: "value", value: "none" });
	assert.deepEqual(second.configuration.label, { state: "null" });
	for (const field of Object.values(third.configuration)) assert.deepEqual(field, { state: "omitted" });
});

type CurrentReport = Extract<components["schemas"]["InspectSessionReply"], { profile: "current"; work: unknown }>;

function report(work: CurrentReport["work"], parent: string | null = null): CurrentReport {
	return {
		version: WIRE_VERSION, type: "session_report", profile: "current",
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
	for (const parent of [null, "p4rent"]) {
		const link: Link = {
			async exchange(path, build) {
				assert.equal(path, "/v1/inspect-session");
				assert.deepEqual(JSON.parse(build('store"\n')), {
					version: WIRE_VERSION, kind: "inspect_session", store: 'store"\n', session: 'session"\n',
				});
				return Buffer.from(JSON.stringify(report({ ...idleWork, latest_outcome: latestOutcome }, parent)));
			},
		};
		assert.deepEqual(await new Session(link, 'session"\n').status(), {
			state: "idle", since: "9007199254740993", turn: null, operation: null, pendingMessages: "9007199254740993",
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
