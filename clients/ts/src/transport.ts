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

/** After the request is sent, the longest the Host may stay silent before its first reply byte. */
const RESPONSE_WAIT_MS = 5_000;
/** The longest a transfer, in either direction, may make no byte of progress. */
const TRANSFER_IDLE_MS = 60_000;

export interface Post {
	socketPath: string;
	path: string;
	/** The request JSON, already serialized in the field order the Host requires. */
	body: string;
	/** The Host instance from host-info; a different instance refuses the call. */
	instance?: string;
	/** Client environment bytes sent ahead of the JSON (`/v1/message`). */
	environment?: Buffer;
	/** Progress deadlines, which tests shorten. A call that expires has an unconfirmed outcome: the Host may still have acted. */
	timeouts?: { responseMs?: number; idleMs?: number };
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
		const idle = call.timeouts?.idleMs ?? TRANSFER_IDLE_MS;
		outgoing.setTimeout(idle);
		outgoing.on("timeout", () => outgoing.destroy(new Error("the Host made no progress in time")));
		// Silence after the whole request went out gets the short budget; any byte of progress renews the long one.
		outgoing.on("finish", () => outgoing.setTimeout(call.timeouts?.responseMs ?? RESPONSE_WAIT_MS));
		outgoing.on("error", (error) => reject(new ConnectionError(error.message, { cause: error })));
		outgoing.on("response", (incoming) => {
			outgoing.setTimeout(idle);
			const chunks: Buffer[] = [];
			let length = 0;
			incoming.on("data", (chunk: Buffer) => {
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
	let parsed: components["schemas"]["ErrorReply"] | undefined;
	try {
		parsed = JSON.parse(reply.toString("utf8"));
	} catch {
		// Fall through: a reply that is not an ErrorReply is reported by status.
	}
	if (parsed && typeof parsed.code === "string" && typeof parsed.type === "string") {
		return new RuiRequestError(parsed.type, parsed.code);
	}
	return new RuiRequestError("invocation_error", `http_${status ?? "unknown"}`);
}
