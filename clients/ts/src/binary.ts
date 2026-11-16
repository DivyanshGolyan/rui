import { createRequire } from "node:module";
import { dirname, join } from "node:path";

export const PLATFORM_PACKAGES: Record<string, Record<string, string>> = {
	linux: { x64: "ruicode-linux-x64", arm64: "ruicode-linux-arm64" },
	darwin: { arm64: "ruicode-darwin-arm64" },
};

export interface BinaryLookup {
	platform?: string;
	arch?: string;
	from?: string;
}

export function resolveBinary(binary: string | undefined, lookup: BinaryLookup = {}): string {
	if (binary !== undefined) return binary;
	const name = PLATFORM_PACKAGES[lookup.platform ?? process.platform]?.[lookup.arch ?? process.arch];
	if (name === undefined) return "rui";
	try {
		return join(dirname(createRequire(lookup.from ?? import.meta.url).resolve(`${name}/package.json`)), "bin", "rui");
	} catch {
		return "rui";
	}
}
