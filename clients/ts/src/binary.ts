import { createRequire } from "node:module";
import { dirname, join } from "node:path";

import { RuiUnavailableError } from "./errors.ts";

export const PLATFORM_PACKAGES: Record<string, Record<string, string>> = {
	linux: { x64: "ruicode-linux-x64", arm64: "ruicode-linux-arm64" },
	darwin: { arm64: "ruicode-darwin-arm64" },
};

const SUPPORTED = "Linux on x86-64 or arm64 with glibc, and macOS on Apple Silicon";

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
		throw new RuiUnavailableError(`Rui has no build for ${platform} on ${arch}. It runs on ${SUPPORTED}. Pass \`binary\` to Rui.connect to use a rui you built.`);
	}
	try {
		return join(dirname(createRequire(lookup.from ?? import.meta.url).resolve(`${name}/package.json`)), "bin", "rui");
	} catch (error) {
		throw new RuiUnavailableError(`The ${name} package, which holds the rui executable, is not installed; npm skips it when optional dependencies are omitted or the system does not match it. Reinstall ruicode, or pass \`binary\` to Rui.connect.`, { cause: error });
	}
}
