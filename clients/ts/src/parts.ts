import type { Link } from "./sessions.ts";
import { WIRE_VERSION } from "./transport.ts";
import type { components } from "./wire.ts";

type Schemas = components["schemas"];
export type ContentValue = Schemas["ContentValue"];
export type PartOwner = Schemas["PartOwner"];
export type Part =
	| { ordinal: number; type: "text"; bytes: string; sha256: string; text?: string; truncated?: boolean }
	| { ordinal: number; type: "image"; mime: string; width: number; height: number; name: string | null; bytes: string; sha256: string };

export async function listParts(link: Link, session: string, owner: PartOwner): Promise<Part[]> {
	const reply: Schemas["PublicPartsReply"] = JSON.parse((await link.exchange("/v1/public-parts", (store) => JSON.stringify({
		version: WIRE_VERSION, kind: "public_parts", store, session, owner,
	} satisfies Schemas["PublicPartsRequest"]))).toString("utf8"));
	return reply.parts.map((part): Part => {
		const ordinal = Number(part.ordinal);
		if (part.type === "text") return { ordinal, type: "text", bytes: part.bytes, sha256: part.sha256 };
		return { ordinal, type: "image", mime: part.mime, width: Number(part.width), height: Number(part.height), name: part.name, bytes: part.bytes, sha256: part.sha256 };
	});
}

export async function readPartBytes(link: Link, session: string, owner: PartOwner, ordinal: number, options?: { prefix?: number }): Promise<Buffer> {
	if (!Number.isSafeInteger(ordinal) || ordinal < 0) throw new RangeError("part ordinal must be a non-negative safe integer");
	return link.exchange("/v1/public-part-content", (store) => JSON.stringify({
		version: WIRE_VERSION, kind: "public_part_content", store, session, owner, part: String(ordinal), start: "0", stream: true,
	} satisfies Schemas["PublicPartContentRequest"]), undefined, options?.prefix === undefined ? { max: 1024 * 1024 * 1024 } : { prefix: options.prefix });
}
