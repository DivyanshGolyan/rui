// One POST over the Host's Unix socket. The Host speaks HTTP/1.1, answers
// once and closes the connection. Nothing here is exported from the package
// (D19).
import { request } from "node:http";

import { RuiRequestError } from "./errors.ts";
import type { components } from "./wire.ts";

/** The wire version openapi.json describes. A test keeps the two equal. */
export const WIRE_VERSION = "8";

/** The largest reply body read. The Host's own replies stay far below it. */
const MAX_REPLY_BYTES = 64 * 1024 * 1024;

export interface Post {
	socketPath: string;
	path: string;
	/** The request JSON, already serialized in the field order the Host requires. */
	body: string;
	/** The Host instance from host-info; a different instance refuses the call. */
	instance?: string;
	/** Client environment bytes sent ahead of the JSON (`/v1/message`). */
	environment?: Buffer;
	/** Resolve with the first this-many bytes of a successful reply and drop the rest. */
	prefixBytes?: number;
}

/** A failure to reach the Host at all, as opposed to a refusal from it. */
export class ConnectionError extends Error {
	override readonly name = "ConnectionError";
}

export function post(call: Post): Promise<Buffer> {
	const json = Buffer.from(call.body);
	const payload = call.environment ? Buffer.concat([call.environment, json]) : json;
	const headers: Record<string, string> = {
		"Content-Type": "application/json",
		"Content-Length": String(payload.length),
		"X-Rui-Wire-Version": WIRE_VERSION,
	};
	if (call.instance !== undefined) headers["X-Rui-Host-Instance"] = call.instance;
	if (call.environment !== undefined) headers["X-Rui-Environment-Bytes"] = String(call.environment.length);
	return new Promise((resolve, reject) => {
		const outgoing = request({ socketPath: call.socketPath, path: call.path, method: "POST", headers, agent: false });
		outgoing.on("error", (error) => reject(new ConnectionError(error.message, { cause: error })));
		outgoing.on("response", (incoming) => {
			const chunks: Buffer[] = [];
			let length = 0;
			incoming.on("data", (chunk: Buffer) => {
				if (call.prefixBytes !== undefined && incoming.statusCode === 200) {
					chunks.push(chunk);
					length += chunk.length;
					if (length >= call.prefixBytes) {
						incoming.destroy();
						resolve(Buffer.concat(chunks).subarray(0, call.prefixBytes));
					}
					return;
				}
				length += chunk.length;
				if (length > MAX_REPLY_BYTES) {
					incoming.destroy(new Error(`the reply exceeds ${MAX_REPLY_BYTES} bytes`));
					return;
				}
				chunks.push(chunk);
			});
			incoming.on("error", (error) => reject(new ConnectionError(error.message, { cause: error })));
			incoming.on("end", () => {
				const reply = Buffer.concat(chunks);
				if (incoming.statusCode === 200) return resolve(reply);
				reject(refusal(incoming.statusCode, reply));
			});
		});
		outgoing.end(payload);
	});
}

function refusal(status: number | undefined, reply: Buffer): Error {
	let parsed: (components["schemas"]["ErrorReply"] & { answer?: { status?: unknown; code?: unknown } }) | undefined;
	try {
		parsed = JSON.parse(reply.toString("utf8"));
	} catch {
		// Fall through: a reply that is not an ErrorReply is reported by status.
	}
	if (parsed && typeof parsed.code === "string" && typeof parsed.type === "string") {
		return new RuiRequestError(parsed.type, parsed.code);
	}
	// A reused key with different input answers 409 with the command's own envelope.
	if (parsed?.answer && typeof parsed.answer.code === "string" && typeof parsed.answer.status === "string") {
		return new RuiRequestError(parsed.answer.status, parsed.answer.code);
	}
	return new RuiRequestError("invocation_error", `http_${status ?? "unknown"}`);
}
