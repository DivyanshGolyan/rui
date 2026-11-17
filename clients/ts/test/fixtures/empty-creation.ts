import assert from "node:assert/strict";
import { Rui, type AgentSpec, type HostSettings } from "../../src/index.ts";
import { WIRE_VERSION } from "../../src/transport.ts";

// The Python fixture supplies either real Store engine and compares this report
// with creation through the CLI and the actual terminal frontend.
let input = "";
for await (const chunk of process.stdin) input += chunk.toString();
const { binary, settings, binding } = JSON.parse(input) as {
	binary: string; settings: HostSettings; binding: AgentSpec & { workspace: string };
};
const rui = await Rui.connect(settings, { binary });
try {
	const requests: unknown[] = [];
	const call = rui.call.bind(rui);
	rui.call = async (path, body, ...rest) => {
		if (path === "/v1/configure") requests.push(JSON.parse(body));
		return call(path, body, ...rest);
	};
	const { model: _model, ...omittedModel } = binding;
	const results: { request: unknown; report: unknown }[] = [];
	for (const [index, spec] of [binding, omittedModel, { workspace: binding.workspace }].entries()) {
		const session = await rui.sessions.create(spec, { idempotencyKey: `empty-creation:typescript:${index}` });
		assert.equal(requests.length, index + 1);
		const request = requests[index];
		assert.deepEqual((request as { configuration: unknown }).configuration, spec);
		const report = JSON.parse((await rui.call("/v1/inspect-session", JSON.stringify({
			version: WIRE_VERSION, kind: "inspect_session", store: rui.hostInfo!.store, session: session.id,
		}))).toString("utf8"));
		results.push({ request, report });
	}
	process.stdout.write(JSON.stringify(results) + "\n");
} finally {
	await rui.close();
}
