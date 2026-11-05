// Presets against the real Host, with Turns paused so no provider is called.
import assert from "node:assert/strict";
import { mkdtempSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { Rui, RuiRequestError, RuiStartError, type AgentSpec } from "../src/index.ts";
import { WIRE_VERSION } from "../src/transport.ts";

const binary = process.env.RUI_BINARY;
const skip = binary ? false : "set RUI_BINARY to a built rui";

async function inspect(rui: Rui, id: string) {
	const body = JSON.stringify({ version: WIRE_VERSION, kind: "inspect_session", store: rui.hostInfo?.store, session: id });
	return JSON.parse((await rui.call("/v1/inspect-session", body)).toString("utf8")).session;
}

test("connect presets seed creation, overrides win and edited presets replay by resolved spec", { skip }, async () => {
	const root = realpathSync(mkdtempSync(join(tmpdir(), "rui-ts-")));
	const spec: AgentSpec = {
		model: "gpt-6.1-sol", effort: "low", compactAt: 100000, tools: ["start_agent"], permissionMode: "ask",
		provider: "openai", workspace: root, instructions: "Preset instructions", label: "Review",
		outputSchema: { type: "object" },
	};
	const options = {
		database: join(root, "store"),
		provider: { baseUrl: "https://api.openai.com/v1", key: "sk-ts-presets" },
		binary: binary ?? "rui", paused: true, presets: { review: spec },
	};
	let rui = await Rui.connect(options);
	const overrides = {
		preset: "review", model: "override-model", effort: null, compactAt: 2000, tools: [],
		permissionMode: "bypass" as const, instructions: "Override", label: null, outputSchema: null,
	};
	try {
		const base = await rui.sessions.create({ preset: "review" }, { idempotencyKey: "preset:base" });
		const saved = await inspect(rui, base.id);
		assert.equal(saved.model, spec.model);
		assert.equal(saved.reasoning_effort, "low");
		assert.equal(saved.compaction_trigger_override, "100000");
		assert.deepEqual(saved.tools, ["start_agent"]);
		assert.equal(saved.permission_mode, "ask");
		assert.equal(saved.label, "Review");
		assert.equal(saved.instructions.bytes, String(spec.instructions!.length));
		assert.ok(saved.output_schema);
		const child = await rui.sessions.create(overrides, { idempotencyKey: "preset:override" });
		const changed = await inspect(rui, child.id);
		assert.equal(changed.model, "override-model");
		assert.equal(changed.provider, "openai");
		assert.equal(changed.workspace, root);
		assert.equal(changed.reasoning_effort, null);
		assert.equal(changed.compaction_trigger_override, "2000");
		assert.deepEqual(changed.tools, []);
		assert.equal(changed.permission_mode, "bypass");
		assert.equal(changed.instructions.bytes, "8");
		assert.equal(changed.label, null);
		assert.equal(changed.output_schema, null);
		assert.equal((await rui.sessions.create(overrides, { idempotencyKey: "preset:override" })).id, child.id);
		await assert.rejects(rui.sessions.create({ preset: "missing" }, { idempotencyKey: "preset:missing" }),
			(error: unknown) => error instanceof RuiRequestError && error.code === "unknown_preset");
		await assert.rejects(base.update({ preset: "review" } as never),
			(error: unknown) => error instanceof RuiRequestError && error.code === "preset_on_update");
		await rui.close();
		rui = await Rui.connect({ ...options, presets: { review: { ...spec, model: "gpt-6-sol" } } });
		assert.equal((await rui.sessions.create(overrides, { idempotencyKey: "preset:override" })).id, child.id);
		await assert.rejects(rui.sessions.create({ preset: "review" }, { idempotencyKey: "preset:base" }),
			(error: unknown) => error instanceof RuiRequestError && error.code === "idempotency_key_conflict");
		assert.equal((await inspect(rui, base.id)).model, spec.model);
	} finally {
		await rui.close();
	}
});

test("an invalid connect preset is a RuiStartError naming the preset and field", { skip }, async () => {
	const root = realpathSync(mkdtempSync(join(tmpdir(), "rui-ts-")));
	await assert.rejects(Rui.connect({
		database: join(root, "store"), binary: binary ?? "rui",
		provider: { baseUrl: "https://api.openai.com/v1", key: "sk-ts-presets" },
		presets: { review: { model: "m" } as AgentSpec },
	}), (error: unknown) => error instanceof RuiStartError && error.code === "invalid_preset" && /review.*effort/.test(error.message));
});
