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

test("the shared write key takes precedence over idempotencyKey", async () => {
	const session = new Session({ async exchange(_path, build) {
		assert.equal(JSON.parse(build("store")).key, "preferred");
		return Buffer.from(JSON.stringify({ answer: { status: "accepted" } }));
	} }, "session");
	await session.update({}, { key: "preferred", idempotencyKey: "older" });
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
	state: { kind: "idle", since: "9007199254740993" }, turn: null, operation: null, first_action: null, attention: null, group: "done", actions: { stop: false, interrupt: null, decide: null }, latest_outcome: null,
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
			archiveState, state: "idle", since: "9007199254740993", turn: null, operation: null, attention: null, group: "done", canStop: false, decide: null, interruptTarget: null, pendingMessages: "9007199254740993",
			parent, label: "Review", model: "model-a", effort: "high", tools: ["bash"], loadedTools: ["bash"], permissionMode: "ask", latestOutcome,
		});
	}
});

test("status and list expose exactly the Host served facts", async () => {
	const facts = { attention: { kind: "approval", turn: "7", step: "9" }, group: "needs_you", actions: { stop: true, interrupt: { turn: "7", operation: "8" }, decide: null } } as const;
	const link: Link = { async exchange(path) {
		return Buffer.from(JSON.stringify(path === "/v1/inspect-session"
			? report({ ...idleWork, ...facts })
			: { sessions: [{ reference: "abc123", label: null, state: "idle", archive_state: "active", parent: null, creator: null, work: { ...idleWork, ...facts } }], next: null }));
	} };
	const expected = { attention: facts.attention, group: facts.group, canStop: true, decide: null, interruptTarget: facts.actions.interrupt };
	const status = await new Session(link, "abc123").status();
	const [row] = await new Sessions(link).list();
	for (const result of [status, row]) {
		assert.ok(result);
		for (const [key, value] of Object.entries(expected)) assert.deepEqual(result[key as keyof typeof expected], value);
	}
});

test("status and list reject missing served facts", async () => {
	for (const missing of ["attention", "group", "actions"] as const) {
		const work: Record<string, unknown> = { ...idleWork };
		delete work[missing];
		const link: Link = { async exchange(path) { return Buffer.from(JSON.stringify(path === "/v1/inspect-session"
			? { ...report(idleWork), work }
			: { sessions: [{ reference: "abc123", work }], next: null })); } };
		await assert.rejects(new Session(link, "abc123").status(), /missing served facts/);
		await assert.rejects(new Sessions(link).list(), /missing served facts/);
	}
});

test("status preserves configured and loaded tool intent from each Current report", async () => {
	const configurations = [
		{ tools: ["bash", "find_tools", "lookup", "none"], loaded_tools: ["find_tools", "none"] },
		{ tools: ["bash", "find_tools", "lookup", "none"], loaded_tools: ["find_tools", "lookup", "none"] },
		{ tools: ["bash", "find_tools"], loaded_tools: ["find_tools"] },
		{ tools: ["bash"], loaded_tools: ["bash"] },
		{ tools: [], loaded_tools: [] },
	];
	let reads = 0;
	const session = new Session({
		async exchange(path) {
			assert.equal(path, "/v1/inspect-session");
			const configuration = configurations[reads++];
			assert.ok(configuration);
			const current = report(idleWork);
			Object.assign(current.session, configuration);
			return Buffer.from(JSON.stringify(current));
		},
	}, "abc123");
	for (const configuration of configurations) {
		const status = await session.status();
		const loadedTools: string[] = status.loadedTools;
		assert.deepEqual(loadedTools, configuration.loaded_tools);
		assert.deepEqual(status.tools, configuration.tools);
	}
	assert.equal(reads, configurations.length);
});

test("status reports a missing Session as a request error", async () => {
	const link: Link = { exchange: async () => Buffer.from(JSON.stringify({ session: null })) };
	await assert.rejects(new Session(link, "absent").status(), (error: unknown) => error instanceof RuiRequestError && error.code === "session_not_found");
});

test("interrupt sends one keyed request naming the explicit target", async () => {
	const requests: unknown[] = [];
	const session = new Session({ async exchange(path, build) {
		requests.push({ path, body: JSON.parse(build("store")) });
		return Buffer.from(JSON.stringify({ answer: { status: "accepted" } }));
	} }, "session");
	await session.interrupt({ turn: "7", operation: "19" }, { key: "saved" });
	assert.deepEqual(requests, [{ path: "/v1/control/model-interruption", body: {
		version: WIRE_VERSION, kind: "model_interruption", store: "store", key: "saved",
		target: { session: "session", turn: "7", operation: "19" },
	} }]);
});

test("interrupt snapshots its explicit target before transport readiness", async () => {
	let release!: () => void;
	const ready = new Promise<void>((resolve) => { release = resolve; });
	let request: components["schemas"]["ModelInterruptionRequest"] | undefined;
	const session = new Session({ async exchange(_path, build) {
		await ready;
		request = JSON.parse(build("store"));
		return Buffer.from(JSON.stringify({ answer: { status: "accepted" } }));
	} }, "session");
	const target = { turn: "1", operation: "2" };
	const pending = session.interrupt(target, { key: "saved" });
	target.operation = "3";
	release();
	await pending;
	assert.deepEqual(request?.target, { session: "session", turn: "1", operation: "2" });
});

test("interrupt also uses the established idempotencyKey option", async () => {
	const keys: string[] = [];
	const session = new Session({ async exchange(_path, build) {
		keys.push(JSON.parse(build("store")).key);
		return Buffer.from(JSON.stringify({ answer: { status: "accepted" } }));
	} }, "session");
	const target = { turn: "1", operation: "2" };
	await session.interrupt(target, { idempotencyKey: "same" });
	await session.interrupt(target, { idempotencyKey: "same" });
	assert.deepEqual(keys, ["same", "same"]);
});

test("interrupt uses the last status observation without another read", async () => {
	const paths: string[] = [];
	let target: { turn: string; operation: string } | null = { turn: "7", operation: "19" };
	const session = new Session({ async exchange(path, build) {
		paths.push(path);
		if (path === "/v1/inspect-session") return Buffer.from(JSON.stringify(report({ ...idleWork, actions: { ...idleWork.actions, interrupt: target } })));
		const body = JSON.parse(build("store"));
		assert.deepEqual(body.target, { session: "session", turn: "7", operation: "19" });
		assert.equal(body.key, "repeat");
		return Buffer.from(JSON.stringify({ answer: { status: "accepted" } }));
	} }, "session");
	await session.interrupt();
	assert.deepEqual(paths, []);
	const observed = (await session.status()).interruptTarget;
	assert.deepEqual(observed, target);
	assert.ok(observed);
	observed.operation = "changed by caller";
	await session.interrupt({ key: "repeat" });
	assert.deepEqual(paths, ["/v1/inspect-session", "/v1/control/model-interruption"]);
	target = null;
	await session.status();
	await session.interrupt();
	assert.deepEqual(paths, ["/v1/inspect-session", "/v1/control/model-interruption", "/v1/inspect-session"]);
});

test("interrupt treats only resolved or mismatched targets as no effect", async () => {
	for (const code of ["operation_resolved", "target_mismatch", "unknown_operation"]) {
		const session = new Session({ async exchange() { return Buffer.from(JSON.stringify({ answer: { status: "rejected", code } })); } }, "session");
		const result = session.interrupt({ turn: "1", operation: "2" });
		if (code === "unknown_operation") await assert.rejects(result, (error: unknown) => error instanceof RuiRequestError && error.code === code);
		else await result;
	}
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
		const detail = code === "mcp_server_unavailable" ? message : "spec.tools: lookup is not a known tool";
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


test("Action reads preserve identity and byte cursor without mutation", async () => {
	const requests: { path: string; body: unknown }[] = [];
	const action = "9007199254740993";
	const link: Link = {
		async exchange(path, build) {
			requests.push({ path, body: JSON.parse(build("store")) });
			return Buffer.from(JSON.stringify({ version: WIRE_VERSION, type: "action_read", session: "session", action, state: "queued", final: null }));
		},
	};
	const session = new Session(link, "session");
	await session.readAction(action, "16383");
	assert.deepEqual(requests, [{ path: "/v1/read-action", body: { version: WIRE_VERSION, kind: "read_action", store: "store", session: "session", action, offset: "16383" } }]);
});


test("Action promotion preserves the key and lossless saved selection", async () => {
	for (const kind of ["background", "final"] as const) {
		const action = "9007199254740993";
		const selection = { kind, position: "9007199254740995" };
		const link: Link = {
			async exchange(path, build) {
				assert.equal(path, "/v1/control/action-background");
				assert.deepEqual(JSON.parse(build('store"\n')), {
					version: WIRE_VERSION, kind: "action_background", store: 'store"\n',
					key: "promote", session: "session", action,
				});
				return Buffer.from(JSON.stringify({ answer: { status: "accepted", replayed: true, session: "session", action, action_selection: selection } }));
			},
		};
		assert.deepEqual(await new Session(link, "session").backgroundAction(action, { idempotencyKey: "promote" }), selection);
	}
});

test("Action promotion reports capacity refusal and changed-key conflicts", async () => {
	for (const [status, code] of [["rejected", "background_unavailable"], ["conflict", "idempotency_key_conflict"]]) {
		const link: Link = { exchange: async () => Buffer.from(JSON.stringify({ answer: { status, code } })) };
		await assert.rejects(new Session(link, "session").backgroundAction("1"), (error: unknown) =>
			error instanceof RuiRequestError && error.type === status && error.code === code);
	}
});

test("stop Action sends the selected Session, Action and recoverable request key", async () => {
	const link: Link = {
		async exchange(path, build) {
			assert.equal(path, "/v1/control/action-stop");
			assert.deepEqual(JSON.parse(build("store")), {
				version: WIRE_VERSION, kind: "action_stop", store: "store",
				key: "stop-request", session: "session", action: "42",
			});
			return Buffer.from(JSON.stringify({ answer: { status: "accepted", action: "42", resolution_position: null } }));
		},
	};
	assert.equal(await new Session(link, "session").stopAction("42", { idempotencyKey: "stop-request" }), null);
});

test("stop Action reports refusal and request key conflicts", async () => {
	for (const [status, code] of [["rejected", "unknown_action"], ["rejected", "target_mismatch"], ["conflict", "idempotency_key_conflict"]]) {
		const link: Link = { exchange: async () => Buffer.from(JSON.stringify({ answer: { status, code } })) };
		await assert.rejects(new Session(link, "session").stopAction("1", { idempotencyKey: "stop-request" }), (error: unknown) =>
			error instanceof RuiRequestError && error.type === status && error.code === code);
	}
});

test("stop Action preserves the existing Resolution position", async () => {
    const link: Link = { exchange: async () => Buffer.from(JSON.stringify({ answer: { status: "accepted", action: "42", resolution_position: "9007199254740993" } })) };
    assert.equal(await new Session(link, "session").stopAction("42"), "9007199254740993");
});

test("feed rejects full replies missing served work facts", async () => {
	for (const missing of ["attention", "group", "actions"] as const) {
		const work: Record<string, unknown> = { ...idleWork };
		delete work[missing];
		const session = new Session({ async exchange() {
			return Buffer.from(JSON.stringify({ delta: "full", since: null, items: [], more: false, end: "0", work }));
		} }, "abc123");
		await assert.rejects(session.listActivity().next(), /missing served facts/);
	}
});
