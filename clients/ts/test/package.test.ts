// Packs the release tarballs, installs them into a fresh project and starts a
// real Rui from the installed platform package. RUI_BINARY names the
// executable to pack; the test needs `npm` and the TypeScript compiler.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";

import { PLATFORM_PACKAGES, resolveBinary } from "../src/binary.ts";

const binary = process.env.RUI_BINARY;
const platform = PLATFORM_PACKAGES[process.platform]?.[process.arch];
const releasePlatform = { "rui-linux-x64": "linux-x86_64", "rui-linux-arm64": "linux-arm64", "rui-darwin-arm64": "darwin-arm64" }[platform ?? ""];
const skip = !binary
	? "set RUI_BINARY to a built rui"
	: releasePlatform === undefined
		? "no platform package for this machine"
		: !existsSync("node_modules/.bin/tsc")
			? "run npm ci first: packing compiles the client"
			: false;

test("an explicit binary wins, and without a platform package the answer is rui on PATH", () => {
	assert.equal(resolveBinary("/opt/rui"), "/opt/rui");
	assert.equal(resolveBinary(undefined, { platform: "plan9", arch: "mips" }), "rui");
	const empty = mkdtempSync(join(tmpdir(), "rui-ts-nopkg-"));
	try {
		assert.equal(resolveBinary(undefined, { platform: "linux", arch: "x64", from: join(empty, "x.js") }), "rui");
	} finally {
		rmSync(empty, { recursive: true, force: true });
	}
});

test("the packed tarballs install and start a Host from the platform package", { skip, timeout: 120_000 }, () => {
	const work = realpathSync(mkdtempSync(join(tmpdir(), "rui-ts-pkg-")));
	try {
		const packs = join(work, "packs");
		execFileSync("node", ["scripts/pack.mjs", "0.0.1", packs, `${releasePlatform}=${resolve(binary as string)}`], { stdio: "inherit" });
		const app = join(work, "app");
		mkdirSync(app);
		writeFileSync(join(app, "package.json"), '{"name":"app","private":true,"type":"module"}');
		execFileSync("npm", ["install", "--offline", "--no-audit", "--no-fund", "--ignore-scripts", join(packs, "rui-0.0.1.tgz"), join(packs, `${platform}-0.0.1.tgz`)], { cwd: app, stdio: "inherit" });
		const installed = JSON.parse(readFileSync(join(app, "node_modules", "rui", "package.json"), "utf8"));
		assert.deepEqual(Object.keys(installed.optionalDependencies).sort(), ["rui-darwin-arm64", "rui-linux-arm64", "rui-linux-x64"]);
		// Plain node, no type stripping, a PATH with no rui on it: the executable can only come from the platform package.
		writeFileSync(
			join(app, "run.mjs"),
			`import { readlinkSync } from "node:fs";
import { Rui } from "rui";
const rui = await Rui.connect({ database: ${JSON.stringify(join(work, "store"))}, provider: { baseUrl: "https://api.openai.com/v1", key: "sk-test" } });
const executable = process.platform === "linux" ? readlinkSync(\`/proc/\${rui.pid}/exe\`) : null;
console.log(JSON.stringify({ executable }));
await rui.close();
`,
		);
		const printed = execFileSync(process.execPath, ["run.mjs"], { cwd: app, env: { PATH: "/usr/bin:/bin", HOME: work, TMPDIR: tmpdir() }, encoding: "utf8" });
		const { executable } = JSON.parse(printed);
		if (process.platform === "linux") assert.ok(String(executable).endsWith(`/node_modules/${platform}/bin/rui`), printed);
	} finally {
		rmSync(work, { recursive: true, force: true });
	}
});
