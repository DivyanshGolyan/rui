// Where the `rui` executable comes from when the caller names none: the
// platform package installed beside this one (D125, D127), else PATH.
import { createRequire } from "node:module";
import { dirname, join } from "node:path";

/** The platform packages, by `process.platform` and `process.arch` (D127, D186). */
export const PLATFORM_PACKAGES: Record<string, Record<string, string>> = {
	linux: { x64: "rui-linux-x64", arm64: "rui-linux-arm64" },
	darwin: { arm64: "rui-darwin-arm64" },
};

export interface BinaryLookup {
	platform?: string;
	arch?: string;
	/** A file URL or path that module resolution starts from. Default: this module. */
	from?: string;
}

/** The executable to start: `binary` if given, else the installed platform package's, else `rui` on PATH. */
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
