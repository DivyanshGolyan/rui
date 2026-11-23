import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";

import { PLATFORM_PACKAGES, resolveBinary } from "../src/binary.ts";
import { RuiUnavailableError } from "../src/errors.ts";
// @ts-expect-error: a plain JavaScript release script with no type declarations.
import { PLATFORMS } from "../scripts/pack.mjs";

const binary = process.env.RUI_BINARY;
const platform = PLATFORM_PACKAGES[process.platform]?.[process.arch];
const releasePlatform = { "ruicode-linux-x64": "linux-x86_64", "ruicode-linux-arm64": "linux-arm64", "ruicode-darwin-arm64": "darwin-arm64" }[platform ?? ""];
const skip = !binary
	? "set RUI_BINARY to a built rui"
	: releasePlatform === undefined
		? "no platform package for this machine"
		: !existsSync("node_modules/.bin/tsc")
			? "run npm ci first: packing compiles the client"
			: false;

test("TS-10 binary resolution refuses without a platform package", () => {
	assert.equal(resolveBinary("/opt/rui"), "/opt/rui");
	assert.equal(resolveBinary("/opt/rui", { platform: "win32", arch: "x64" }), "/opt/rui");
	for (const [platform, arch] of [["darwin", "x64"], ["win32", "x64"], ["linux", "ia32"]] as const) {
		assert.throws(() => resolveBinary(undefined, { platform, arch }), (error: unknown) =>
			error instanceof RuiUnavailableError && error.message.startsWith(`Rui has no build for ${platform} on ${arch}. Rui runs on glibc Linux on x64 or arm64, and darwin on arm64.`));
	}
	const published = Object.values(PLATFORMS as Record<string, { name: string; os: string; cpu: string }>).map(({ name, os, cpu }) => `${os}/${cpu}=${name}`).sort();
	const resolved = Object.entries(PLATFORM_PACKAGES).flatMap(([os, arches]) => Object.entries(arches).map(([cpu, name]) => `${os}/${cpu}=${name}`)).sort();
	assert.deepEqual(resolved, published, "the client resolves exactly the platform packages pack.mjs publishes");
	const empty = mkdtempSync(join(tmpdir(), "rui-ts-nopkg-"));
	try {
		assert.throws(() => resolveBinary(undefined, { platform: "linux", arch: "x64", from: join(empty, "x.js") }), (error: unknown) =>
			error instanceof RuiUnavailableError && /ruicode-linux-x64 package.*not installed.*musl Linux\. Rui runs on glibc Linux on x64 or arm64, and darwin on arm64\./.test(error.message));
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
		execFileSync("npm", ["install", "--offline", "--no-audit", "--no-fund", "--ignore-scripts", join(packs, "rui-0.0.1.tgz"), join(packs, `rui${(platform as string).slice("ruicode".length)}-0.0.1.tgz`)], { cwd: app, stdio: "inherit" });
		const installed = JSON.parse(readFileSync(join(app, "node_modules", "ruicode", "package.json"), "utf8"));
		assert.deepEqual(Object.keys(installed.optionalDependencies).sort(), ["ruicode-darwin-arm64", "ruicode-linux-arm64", "ruicode-linux-x64"]);
		assert.deepEqual(installed.os, ["linux", "darwin"]);
		writeFileSync(
			join(app, "run.mjs"),
			`import { readlinkSync } from "node:fs";
import { Rui } from "ruicode";
const rui = await Rui.connect({ store: { sqlite: { dir: ${JSON.stringify(join(work, "store"))} } }, providers: { openai: { endpoint: "https://api.openai.com/v1/responses", key: "sk-test" } } });
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
