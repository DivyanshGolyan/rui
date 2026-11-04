// Sessions: create, list, send, update, stop, interrupt and decide, plus the
// model list and Host pause (D7, D8, D14 to D17, D121, D123, D128, D167,
// D171). Every call is one request to a Host route that exists today. The
// Host reads request fields in the order it lists them, so each body below is
// written out in that order (openapi.json says so).
import { randomUUID } from "node:crypto";

import { RuiRequestError } from "./errors.ts";
import type { components } from "./wire.ts";

/** What a Session handle needs from the client. */
export interface Link {
	exchange(path: string, build: (store: string) => string, environment?: Buffer): Promise<Buffer>;
}

type Schemas = components["schemas"];

/** The Session settings the Host takes today. */
export interface SessionSpec {
	/** The working directory for Bash. Required with `bash`, fixed for the Session's life. */
	workspace?: string;
	/** `openai` or `codex`. Fixed for the Session's life. */
	provider?: string;
	/** Fixed for the Session's life. */
	model?: string;
	instructions?: string;
	tools?: ("bash" | "web_search")[];
	permissionMode?: "ask" | "bypass";
	/** Reasoning effort. `null` returns to the model's default. */
	effort?: string | null;
	/** Compact the conversation at this many tokens. `null` returns to the default. */
	compactAt?: number | null;
	/** A name shown in lists. `null` clears it. */
	label?: string | null;
}

/** The settings `update` may change: everything but the ones fixed at creation. */
export type SessionUpdate = Omit<SessionSpec, "workspace" | "provider" | "model">;

export interface WriteOptions {
	/** Required on `create` and `send`, built as `kind:driftId`. Other writes get a fresh UUIDv4 when it is left out (D123). */
	idempotencyKey?: string;
}

export interface SendOptions {
	idempotencyKey: string;
	/** The environment Bash runs in. Defaults to empty: the caller's own never reaches Bash (D121). */
	env?: Record<string, string>;
}

export interface SessionSummary {
	id: string;
	label: string | null;
	/** The Session's work state, such as `idle`, `working` or `approval`. */
	state: string;
	/** Always `null` until Sessions have parents. */
	parent: string | null;
}

export interface ModelSummary {
	provider: string;
	id: string;
	known: boolean;
}

const TOOLS = ["bash", "web_search"] as const;

/** Every row kind: the Host refuses an empty set. */
const ALL_KINDS = JSON.stringify(["admission", "user", "assistant", "call", "tool_result", "hosted_call", "turn_ended", "stop", "sent", "send_failed", "received"]);

type Omitted = '{"state":"omitted"}';
const OMITTED: Omitted = '{"state":"omitted"}';
const NULL = '{"state":"null"}';

function value(text: string): string {
	return `{"state":"value","value":${text}}`;
}

function optional<T>(field: T | undefined, encode: (field: T) => string): string {
	return field === undefined ? OMITTED : value(encode(field));
}

function clearable<T>(field: T | null | undefined, encode: (field: T) => string): string {
	if (field === undefined) return OMITTED;
	return field === null ? NULL : value(encode(field));
}

/** The configuration object, its fields in the Host's order. */
function configuration(spec: SessionSpec): string {
	const text = (field: string) => JSON.stringify(field);
	const fields = [
		optional(spec.workspace, text),
		optional(spec.provider, text),
		optional(spec.model, text),
		optional(spec.instructions, text),
		// The Host takes the catalog order, each tool once.
		optional(spec.tools, (tools) => JSON.stringify(TOOLS.filter((tool) => tools.includes(tool)))),
		optional(spec.permissionMode, text),
		OMITTED, // output_schema
		clearable(spec.compactAt, (tokens) => JSON.stringify(String(tokens))),
		OMITTED, // output_reservation
		clearable(spec.effort, text),
		clearable(spec.label, text),
	];
	return `{"workspace":${fields[0]},"provider":${fields[1]},"model":${fields[2]},"instructions":${fields[3]},"tools":${fields[4]},"permission_mode":${fields[5]},"output_schema":${fields[6]},"compaction_trigger":${fields[7]},"output_reservation":${fields[8]},"reasoning_effort":${fields[9]},"label":${fields[10]}}`;
}

function configureBody(store: string, key: string, session: string, spec: SessionSpec): string {
	return `{"version":"8","kind":"configure","store":${JSON.stringify(store)},"key":${JSON.stringify(key)},"session":${JSON.stringify(session)},"configuration":${configuration(spec)}}`;
}

function key(options: WriteOptions | undefined): string {
	return options?.idempotencyKey ?? randomUUID();
}

function parse<T>(reply: Buffer): T {
	return JSON.parse(reply.toString("utf8")) as T;
}

/** Throws the Host's rejection or conflict; returns the accepted answer. */
function accepted<A extends { status: string; code?: string }>(answer: A): Extract<A, { status: "accepted" }> {
	if (answer.status !== "accepted") throw new RuiRequestError(answer.status, answer.code ?? "rejected");
	return answer as Extract<A, { status: "accepted" }>;
}

/** `NAME=VALUE\0` for each entry, ahead of the message record (D121). */
function environmentBytes(env: Record<string, string> | undefined): Buffer {
	const entries = Object.entries(env ?? {});
	return Buffer.from(entries.map(([name, entry]) => `${name}=${entry}\0`).join(""), "utf8");
}

export class Session {
	readonly #link: Link;
	readonly id: string;

	constructor(link: Link, id: string) {
		this.#link = link;
		this.id = id;
	}

	/** Sends a Message. The receipt is its admission number; the answer arrives in the feed (D8). */
	async send(text: string, options: SendOptions): Promise<{ messageId: string }> {
		const body = (store: string) =>
			`{"version":"8","kind":"message","store":${JSON.stringify(store)},"key":${JSON.stringify(options.idempotencyKey)},"session":${JSON.stringify(this.id)},"sender":null,"sender_handle":null,"text":{"state":"value","value":${JSON.stringify(text)}}}`;
		const reply = parse<Schemas["MessageReply"]>(await this.#link.exchange("/v1/message", body, environmentBytes(options.env)));
		return { messageId: accepted(reply.answer).admission };
	}

	/** Changes settings. Omitted fields stay as they are. Resolves once the Host accepted the change (D7). */
	async update(fields: SessionUpdate, options?: WriteOptions): Promise<void> {
		const idempotencyKey = key(options);
		const reply = parse<Schemas["ConfigureReply"]>(
			await this.#link.exchange("/v1/configure", (store) => configureBody(store, idempotencyKey, this.id, fields)),
		);
		accepted(reply.answer);
	}

	/** Stops the current and queued work. The Session stays usable (D14). */
	async stop(options?: WriteOptions): Promise<void> {
		const idempotencyKey = key(options);
		const body = (store: string) =>
			`{"version":"8","kind":"session_stop","store":${JSON.stringify(store)},"key":${JSON.stringify(idempotencyKey)},"session":${JSON.stringify(this.id)}}`;
		accepted(parse<Schemas["SessionStopReply"]>(await this.#link.exchange("/v1/control/session-stop", body)).answer);
	}

	/**
	 * Cuts off the current model call while the Session keeps going. Resolves
	 * without sending anything when no model call is current (D167, D171).
	 */
	async interrupt(options?: WriteOptions): Promise<void> {
		const page = parse<Schemas["ActivityPageReply"]>(
			await this.#link.exchange(
				"/v1/activity-page",
				(store) =>
					`{"version":"8","kind":"activity_page","store":${JSON.stringify(store)},"session":${JSON.stringify(this.id)},"end":null,"position":"0","ordinal":null,"direction":"backward","kinds":${ALL_KINDS},"limit":"1"}`,
			),
		);
		const { turn, operation } = page.work;
		if (turn === null || operation === null || !modelCallCurrent(page.work.state.kind)) return;
		const idempotencyKey = key(options);
		const body = (store: string) =>
			`{"version":"8","kind":"model_interruption","store":${JSON.stringify(store)},"key":${JSON.stringify(idempotencyKey)},"target":{"session":${JSON.stringify(this.id)},"turn":${JSON.stringify(turn)},"operation":${JSON.stringify(operation)}}}`;
		try {
			accepted(parse<Schemas["ModelInterruptionReply"]>(await this.#link.exchange("/v1/control/model-interruption", body)).answer);
		} catch (error) {
			// The call ended before the cut reached it, or this key already cut an earlier call: nothing is left to do.
			const gone = error instanceof RuiRequestError && (error.code === "operation_resolved" || error.code === "target_mismatch" || error.code === "idempotency_key_conflict");
			if (!gone) throw error;
		}
	}

	/** Answers an approval. `requestId` is the Action id of the `approval_requested` entry (D15). */
	async decide(requestId: string, decision: "allow" | "deny", options?: WriteOptions): Promise<void> {
		const idempotencyKey = key(options);
		const wire = decision === "allow" ? "allow_once" : "deny";
		const body = (store: string) =>
			`{"version":"8","kind":"permission_decision","store":${JSON.stringify(store)},"key":${JSON.stringify(idempotencyKey)},"session":${JSON.stringify(this.id)},"action":${JSON.stringify(requestId)},"decision":"${wire}"}`;
		accepted(parse<Schemas["PermissionDecisionReply"]>(await this.#link.exchange("/v1/control/permission-decision", body)).answer);
	}
}

/** Work states in which a model call is the current thing. */
function modelCallCurrent(kind: string): boolean {
	return kind === "working" || kind === "retrying" || kind === "pending";
}

export class Sessions {
	readonly #link: Link;

	constructor(link: Link) {
		this.#link = link;
	}

	/** Creates a Session. The key is required: a repeat returns the same Session (D7, D17). */
	async create(spec: SessionSpec, options: { idempotencyKey: string }): Promise<Session> {
		const reply = parse<Schemas["ConfigureReply"]>(
			await this.#link.exchange("/v1/configure", (store) => configureBody(store, options.idempotencyKey, "", spec)),
		);
		return new Session(this.#link, accepted(reply.answer).session);
	}

	/** Every configured Session, newest first (D128). */
	async list(): Promise<SessionSummary[]> {
		const summaries: SessionSummary[] = [];
		let after = "0";
		let ceiling = "0";
		for (;;) {
			const wireAfter = after;
			const wireCeiling = ceiling;
			const page = parse<Schemas["ListSessionsReply"]>(
				await this.#link.exchange(
					"/v1/list-sessions",
					(store) => `{"version":"8","kind":"list_sessions","store":${JSON.stringify(store)},"workspace":null,"after":"${wireAfter}","ceiling":"${wireCeiling}"}`,
				),
			);
			for (const row of page.sessions) {
				summaries.push({ id: row.reference, label: row.label, state: row.work.state.kind, parent: null });
			}
			if (page.next === null || !("after" in page.next)) return summaries;
			after = page.next.after;
			ceiling = page.next.ceiling;
		}
	}
}

/** The models each provider offers (D128). */
export async function models(link: Link): Promise<ModelSummary[]> {
	const reply = parse<Schemas["ModelListReply"]>(
		await link.exchange("/v1/model-list", (store) => `{"version":"8","kind":"model_list","store":${JSON.stringify(store)}}`),
	);
	return reply.providers.flatMap((entry) => entry.models.map((model) => ({ provider: entry.provider, id: model.id, known: model.known })));
}

/** Holds every new Turn while paused; running work continues (D199). */
export async function setPaused(link: Link, paused: boolean): Promise<void> {
	await link.exchange("/v1/control/host-pause", (store) => `{"version":"8","kind":"host_pause","store":${JSON.stringify(store)},"paused":${paused}}`);
}
