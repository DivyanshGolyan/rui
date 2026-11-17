import assert from "node:assert/strict";
import { Rui, RuiRequestError, type HostSettings } from "../../src/index.ts";
import { WIRE_VERSION } from "../../src/transport.ts";

let input = "";
for await (const chunk of process.stdin) input += chunk.toString();
const { binary, settings, workspace } = JSON.parse(input) as {
	binary: string; settings: HostSettings; workspace: string;
};
const rui = await Rui.connect(settings, { binary });
try {
	const requests: { configuration: { preferences?: unknown } }[] = [];
	const call = rui.call.bind(rui);
	rui.call = async (path, body, ...rest) => {
		if (path === "/v1/configure") requests.push(JSON.parse(body));
		return call(path, body, ...rest);
	};
	const preferences = { reasoningEffort: "max", permissionMode: "bypass" } as const;
	const cases = [
		{ workspace, provider: "openai", model: "gpt-5.5", preferences },
		{ workspace, provider: "openai", model: "gpt-6.1-sol", preferences },
		{ workspace, provider: "openai", model: "gpt-5.5", preferences, effort: "high", permissionMode: "ask" },
	] as const;
	const reports: unknown[] = [];
	for (const [index, spec] of cases.entries()) {
		const idempotencyKey = `preferences:typescript:${index}`;
		const session = await rui.sessions.create(spec, { idempotencyKey });
		assert.deepEqual(requests.at(-1)!.configuration.preferences, { reasoning_effort: "max", permission_mode: "bypass" });
		const replay = await rui.sessions.create(spec, { idempotencyKey });
		assert.equal(replay.id, session.id);
		const report = JSON.parse((await rui.call("/v1/inspect-session", JSON.stringify({
			version: WIRE_VERSION, kind: "inspect_session", store: rui.hostInfo!.store, session: session.id,
		}))).toString("utf8"));
		reports.push(report);
		if (index === 0) {
			for (const [suffix, value] of [["empty", {}], ["populated", { reasoning_effort: "max" }]] as const) {
				const rejected = JSON.parse((await rui.call("/v1/configure", JSON.stringify({
					version: WIRE_VERSION, kind: "configure", store: rui.hostInfo!.store,
					key: `preferences:update:${suffix}`, session: session.id, configuration: { preferences: value },
				}))).toString("utf8"));
				assert.equal(rejected.answer.code, "preferences_on_update");
			}
			await session.update({ effort: "high", permissionMode: "ask" });
			const afterUpdate = JSON.parse((await rui.call("/v1/inspect-session", JSON.stringify({
				version: WIRE_VERSION, kind: "inspect_session", store: rui.hostInfo!.store, session: session.id,
			}))).toString("utf8"));
			assert.equal(afterUpdate.session.reasoning_effort, "high");
			assert.equal(afterUpdate.session.permission_mode, "ask");
			const afterReplay = await rui.sessions.create(spec, { idempotencyKey });
			assert.equal(afterReplay.id, session.id);
			const retained = JSON.parse((await rui.call("/v1/inspect-session", JSON.stringify({
				version: WIRE_VERSION, kind: "inspect_session", store: rui.hostInfo!.store, session: session.id,
			}))).toString("utf8"));
			assert.equal(retained.session.reasoning_effort, "high");
			assert.equal(retained.session.permission_mode, "ask");
		}
	}
	// Child authority is checked after Host defaults and preferences are resolved.
	// The parent has the Host-supported max model; an omitted child model uses
	// the recommended low-only model while its provider and Workspace inherit.
	const parent = await rui.sessions.create({ workspace, provider: "openai", model: "gpt-5.5", permissionMode: "ask" },
		{ idempotencyKey: "preferences:parent" });
	for (const [suffix, childPreferences] of [["omitted", undefined], ["bypass", preferences]] as const) {
		await assert.rejects(
			rui.sessions.create({ parent: parent.id, ...(childPreferences === undefined ? {} : { preferences: childPreferences }) },
				{ idempotencyKey: `preferences:child:${suffix}` }),
			(error: unknown) => error instanceof RuiRequestError && error.code === "permission_mode_wider_than_parent",
		);
	}
	for (const [suffix, childSpec, model, effort] of [
		["saved-ask", { parent: parent.id, preferences: { reasoningEffort: "max", permissionMode: "ask" } }, "gpt-6.1-sol", "low"],
		["explicit-ask", { parent: parent.id, model: "gpt-5.5", preferences, permissionMode: "ask" }, "gpt-5.5", "max"],
	] as const) {
		const child = await rui.sessions.create(childSpec, { idempotencyKey: `preferences:child:${suffix}` });
		const report = JSON.parse((await rui.call("/v1/inspect-session", JSON.stringify({
			version: WIRE_VERSION, kind: "inspect_session", store: rui.hostInfo!.store, session: child.id,
		}))).toString("utf8"));
		assert.equal(report.session.parent, parent.id);
		assert.equal(report.session.provider, "openai");
		assert.equal(report.session.workspace, workspace);
		assert.equal(report.session.model, model);
		assert.equal(report.session.reasoning_effort, effort);
		assert.equal(report.session.permission_mode, "ask");
	}
	await assert.rejects(
		rui.sessions.create({ workspace, provider: "openai", model: "gpt-6.1-sol", preferences, effort: "max" },
			{ idempotencyKey: "preferences:unsupported-explicit" }),
		(error: unknown) => error instanceof RuiRequestError && error.code === "unsupported_reasoning_effort",
	);
	process.stdout.write(JSON.stringify(reports) + "\n");
} finally {
	await rui.close();
}
