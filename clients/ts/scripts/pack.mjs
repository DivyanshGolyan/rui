// Builds the npm tarballs for one release: the `rui` package (compiled to
// plain JavaScript, since Node does not strip types under node_modules) and
// one package per platform holding that platform's `rui` executable (D125,
// D127, D186). Nothing here publishes anything.
//
//   node scripts/pack.mjs <version> <outdir> <platform>=<executable> ...
//
// <platform> is a release platform: linux-x86_64, linux-arm64 or darwin-arm64.
import { execFileSync } from "node:child_process";
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

/** Release platform -> npm package, operating system and CPU. */
export const PLATFORMS = {
	"linux-x86_64": { name: "rui-linux-x64", os: "linux", cpu: "x64" },
	"linux-arm64": { name: "rui-linux-arm64", os: "linux", cpu: "arm64" },
	"darwin-arm64": { name: "rui-darwin-arm64", os: "darwin", cpu: "arm64" },
};

function writeJson(path, value) {
	writeFileSync(path, `${JSON.stringify(value, null, "\t")}\n`);
}

function pack(directory, outdir) {
	execFileSync("npm", ["pack", "--silent", "--pack-destination", outdir], { cwd: directory, stdio: ["ignore", "ignore", "inherit"] });
}

/** Writes the directory of one platform package. */
export function platformPackage(directory, version, platform, executable) {
	const target = PLATFORMS[platform];
	if (target === undefined) throw new Error(`unknown platform ${platform}`);
	mkdirSync(join(directory, "bin"), { recursive: true });
	copyFileSync(executable, join(directory, "bin", "rui"));
	chmodSync(join(directory, "bin", "rui"), 0o755);
	writeJson(join(directory, "package.json"), {
		name: target.name,
		version,
		description: `The rui executable for ${target.os} on ${target.cpu}.`,
		os: [target.os],
		cpu: [target.cpu],
		files: ["bin"],
	});
}

/** Writes the directory of the main package, compiled, with every platform package as an optional dependency. */
export function mainPackage(directory, version) {
	const source = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
	execFileSync("npx", ["tsc", "-p", "tsconfig.build.json", "--outDir", join(directory, "dist")], { cwd: root, stdio: "inherit" });
	copyFileSync(join(root, "README.md"), join(directory, "README.md"));
	writeJson(join(directory, "package.json"), {
		name: source.name,
		version,
		description: source.description,
		type: "module",
		engines: source.engines,
		exports: { ".": { types: "./dist/index.d.ts", default: "./dist/index.js" } },
		files: ["dist", "README.md"],
		optionalDependencies: Object.fromEntries(Object.values(PLATFORMS).map(({ name }) => [name, version])),
	});
}

function main(args) {
	const [version, outdir, ...executables] = args;
	if (!version || !outdir || executables.length === 0) {
		console.error("usage: node scripts/pack.mjs <version> <outdir> <platform>=<executable> ...");
		process.exit(2);
	}
	mkdirSync(resolve(outdir), { recursive: true });
	const work = mkdtempSync(join(tmpdir(), "rui-pack-"));
	try {
		mkdirSync(join(work, "rui"));
		mainPackage(join(work, "rui"), version);
		pack(join(work, "rui"), resolve(outdir));
		for (const entry of executables) {
			const [platform, executable] = entry.split("=");
			const directory = join(work, platform);
			mkdirSync(directory);
			platformPackage(directory, version, platform, resolve(executable));
			pack(directory, resolve(outdir));
		}
	} finally {
		rmSync(work, { recursive: true, force: true });
	}
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main(process.argv.slice(2));
