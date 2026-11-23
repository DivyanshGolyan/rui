import { createRequire } from "node:module";
import { dirname, join } from "node:path";

import { RuiUnavailableError } from "./errors.ts";

/** The one table of platforms Rui builds for: Node's platform, then architecture, to the npm package holding rui. */
export const PLATFORM_PACKAGES: Record<string, Record<string, string>> = {
	linux: { x64: "ruicode-linux-x64", arm64: "ruicode-linux-arm64" },
	darwin: { arm64: "ruicode-darwin-arm64" },
};

// pack.mjs PLATFORMS publishes these packages, with glibc required on Linux; TS-10 checks the two tables agree.
const SUPPORTED = `Rui runs on ${Object.entries(PLATFORM_PACKAGES)
	.map(([platform, arches]) => `${platform === "linux" ? "glibc Linux" : platform} on ${Object.keys(arches).join(" or ")}`)
	.join(", and ")}.`;

export interface BinaryLookup {
	platform?: string;
	arch?: string;
	from?: string;
}

/** The rui to start: `binary` when given, else the platform package's. Never a guess from PATH. */
export function resolveBinary(binary: string | undefined, lookup: BinaryLookup = {}): string {
	if (binary !== undefined) return binary;
	const platform = lookup.platform ?? process.platform;
	const arch = lookup.arch ?? process.arch;
	const name = PLATFORM_PACKAGES[platform]?.[arch];
	if (name === undefined) {
		throw new RuiUnavailableError(`Rui has no build for ${platform} on ${arch}. ${SUPPORTED} Pass \`binary\` to Rui.connect to use a rui you built.`);
	}
	try {
		return join(dirname(createRequire(lookup.from ?? import.meta.url).resolve(`${name}/package.json`)), "bin", "rui");
	} catch (error) {
		throw new RuiUnavailableError(`The ${name} package, which holds the rui executable, is not installed. npm skips it when optional dependencies are omitted or this system does not match it, such as musl Linux. ${SUPPORTED} Reinstall ruicode with optional dependencies, or pass \`binary\` to Rui.connect.`, { cause: error });
	}
}
