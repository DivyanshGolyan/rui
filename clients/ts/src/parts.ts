import type { Link } from "./sessions.ts";
import { WIRE_VERSION } from "./transport.ts";
import type { components } from "./wire.ts";

type Schemas = components["schemas"];
export type ContentValue = Schemas["ContentValue"];
export type PartOwner = Schemas["PartOwner"];
export type Part =
	| { ordinal: number; type: "text"; bytes: string; sha256: string; text?: string; truncated?: boolean }
	| { ordinal: number; type: "image"; mime: "image/png" | "image/jpeg"; width: number; height: number; name: string | null; bytes: string; sha256: string };

export async function listParts(link: Link, session: string, owner: PartOwner): Promise<Part[]> {
	const reply: Schemas["PublicPartsReply"] = JSON.parse((await link.exchange("/v1/public-parts", (store) => JSON.stringify({
		version: WIRE_VERSION, kind: "public_parts", store, session, owner,
	} satisfies Schemas["PublicPartsRequest"]))).toString("utf8"));
	return reply.parts.map((part): Part => {
		if (part.type === "text") return { ...part, ordinal: Number(part.ordinal) };
		if (part.mime !== "image/png" && part.mime !== "image/jpeg") throw new Error(`Unsupported image MIME type: ${part.mime}`);
		return { ...part, ordinal: Number(part.ordinal), width: Number(part.width), height: Number(part.height), mime: part.mime };
	});
}

export function readPartBytes(link: Link, session: string, owner: PartOwner, ordinal: number, options?: { prefix?: number }): Promise<Buffer> {
	if (!Number.isSafeInteger(ordinal) || ordinal < 0) throw new RangeError("part ordinal must be a non-negative safe integer");
	return link.exchange("/v1/public-part-content", (store) => JSON.stringify({
		version: WIRE_VERSION, kind: "public_part_content", store, session, owner, part: String(ordinal), start: "0", stream: true,
	} satisfies Schemas["PublicPartContentRequest"]), undefined, options?.prefix === undefined ? { max: 1024 * 1024 * 1024 } : { prefix: options.prefix });
}
