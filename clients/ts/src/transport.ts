import { request } from "node:http";

import { RuiRequestError, type RequestAnswer } from "./errors.ts";
import type { components } from "./wire.ts";

export const WIRE_VERSION = "22";

const MAX_REPLY_BYTES = 64 * 1024 * 1024;

const TRANSFER_IDLE_MS = 60_000;

export interface Post {
	socketPath: string;
	path: string;
	body: string;
	instance?: string;
	environment?: Buffer;
	limits?: ReplyLimits;
}

export interface ReplyLimits {
	prefix?: number;
	max?: number;
	idleMs?: number;
}

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
		const idle = call.limits?.idleMs ?? TRANSFER_IDLE_MS;
		outgoing.setTimeout(idle);
		outgoing.on("timeout", () => outgoing.destroy(new Error("the Host made no progress in time")));
		outgoing.on("error", (error) => reject(new ConnectionError(error.message, { cause: error })));
		outgoing.on("response", (incoming) => {
			outgoing.setTimeout(idle);
			const chunks: Buffer[] = [];
			let length = 0;
			incoming.on("data", (chunk: Buffer) => {
				if (call.limits?.prefix !== undefined && incoming.statusCode === 200) {
					chunks.push(chunk);
					length += chunk.length;
					if (length >= (call.limits?.prefix ?? Infinity)) {
						incoming.destroy();
						resolve(Buffer.concat(chunks).subarray(0, call.limits?.prefix));
					}
					return;
				}
				length += chunk.length;
				const max = call.limits?.max ?? MAX_REPLY_BYTES;
				if (length > max) {
					incoming.destroy(new Error(`the reply exceeds ${max} bytes`));
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
	let parsed: (components["schemas"]["ErrorReply"] & { answer?: Partial<Extract<RequestAnswer, { code: string }>> }) | undefined;
	try {
		parsed = JSON.parse(reply.toString("utf8"));
	} catch {
	}
	if (parsed && typeof parsed.code === "string" && typeof parsed.type === "string") {
		return new RuiRequestError(parsed.type, parsed.code);
	}
	if (parsed?.answer && typeof parsed.answer.code === "string" && typeof parsed.answer.status === "string") {
		return new RuiRequestError(parsed.answer.status, parsed.answer.code);
	}
	return new RuiRequestError("invocation_error", `http_${status ?? "unknown"}`);
}
