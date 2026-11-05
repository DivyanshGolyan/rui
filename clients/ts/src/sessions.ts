// Sessions: create, list, send, update, stop, interrupt and decide, plus the
// model list and Host pause (D7, D8, D14 to D17, D121, D123, D128, D167,
// D171). Every call is one request to a Host route that exists today.
import { randomUUID } from "node:crypto";

import type { SessionNotifications } from "./notifications.ts";
import { RuiRequestError } from "./errors.ts";
import { FEED_KINDS, listActivity, searchActivity, type ActivitySearchEntry, type SearchActivityOptions, readContent, readContentBytes, type FeedEntry, type ListActivityOptions } from "./feed.ts";
import { WIRE_VERSION, type ReplyLimits } from "./transport.ts";
import type { components } from "./wire.ts";

/** What a Session handle needs from the client. */
export interface Link {
	readonly activity?: SessionNotifications;
	exchange(path: string, build: (store: string) => string, environment?: Buffer, limits?: ReplyLimits): Promise<Buffer>;
}

type Schemas = components["schemas"];

/** The Session settings the Host takes today. */
export interface SessionSpec {
	/** The working directory for Bash. Required with `bash`, fixed for the Session's life. */
	workspace?: string;
	/** `openai` or `codex`. Fixed for the Session's life. */
	provider?: string;
	/** Fixed for the Session's life. */
	model: string;
	instructions?: string;
	/** JSON output schema as JSON text; `null` clears it. */
	outputSchema?: string | null;
	/** Tool names the Host offers, such as `bash` and `web_search`. */
	tools: readonly string[];
	permissionMode: "ask" | "bypass";
	/** Reasoning effort. `null` sends none, so the provider uses its own; only for a model Rui does not list (D111). */
	effort: string | null;
	/** Compact the conversation at this many tokens. */
	compactAt: number;
	/** A name shown in lists. `null` clears it. */
	label?: string | null;
}

/** The settings `update` may change: everything but the ones fixed at creation. */
export type SessionUpdate = Partial<Pick<SessionSpec, "instructions" | "outputSchema" | "tools" | "permissionMode" | "effort" | "compactAt" | "label">>;

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
	parent: string | null;
}

export interface ModelSummary {
	provider: string;
	id: string;
	known: boolean;
}

type Omitted = { state: "omitted" };
const OMITTED: Omitted = { state: "omitted" };
const NULL = { state: "null" } as const;

function optional<T>(field: T | undefined): Omitted | { state: "value"; value: T } {
	return field === undefined ? OMITTED : { state: "value", value: field };
}

function clearable<T>(field: T | null | undefined): Omitted | typeof NULL | { state: "value"; value: T } {
	if (field === undefined) return OMITTED;
	return field === null ? NULL : { state: "value", value: field };
}

function configuration(spec: Partial<SessionSpec>): Schemas["Configuration"] {
	return {
		workspace: optional(spec.workspace),
		provider: optional(spec.provider),
		model: optional(spec.model),
		instructions: optional(spec.instructions),
		// The Host takes the names sorted by bytes, each once. Tool names are
		// ASCII, so code-unit order is byte order.
		tools: optional(spec.tools === undefined ? undefined : [...new Set(spec.tools)].sort()),
		permission_mode: optional(spec.permissionMode),
		output_schema: clearable(spec.outputSchema),
		compaction_trigger: optional(spec.compactAt === undefined ? undefined : String(spec.compactAt)),
		output_reservation: OMITTED,
		reasoning_effort: clearable(spec.effort),
		label: clearable(spec.label),
	};
}

function configureBody(store: string, key: string, session: string, spec: Partial<SessionSpec>): string {
	return JSON.stringify({
		version: WIRE_VERSION,
		kind: "configure",
		store,
		key,
		session,
		configuration: configuration(spec),
	} satisfies Schemas["ConfigureRequest"]);
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

/** `NAME=VALUE\0` for each entry the Host would keep (D121): a name that is not empty, holds no `=` or NUL and does not start with `RUI_`, and a value without NUL. The rest are left out, because after encoding the Host could not tell where an entry ended. */
export function environmentBytes(env: Record<string, string> | undefined): Buffer {
	const forwarded = Object.entries(env ?? {}).filter(
		([name, entry]) => name !== "" && !name.startsWith("RUI_") && !/[=\0]/.test(name) && !entry.includes("\0"),
	);
	return Buffer.from(forwarded.map(([name, entry]) => `${name}=${entry}\0`).join(""), "utf8");
}

export class Session {
	readonly #link: Link;
	readonly id: string;

	constructor(link: Link, id: string) {
		this.#link = link;
		this.id = id;
	}

	/**
	 * The Session's feed, in order, as an async iterator (D9). Without `follow`
	 * it ends at the current end. With it, busy Sessions poll with backoff; idle Sessions
	 * wait for a local write on this Rui instance (not writes from another process).
	 * See `ListActivityOptions.follow`; `signal` abort also ends an idle wait.
	 */
	listActivity(options?: ListActivityOptions): AsyncGenerator<FeedEntry, void, undefined> {
		return listActivity(this.#link, this.id, options);
	}

	/** Search public feed text newest first, with bounded snippets. */
	searchActivity(query: string, options?: SearchActivityOptions): AsyncGenerator<ActivitySearchEntry, void, undefined> {
		return searchActivity(this.#link, this.id, query, options);
	}

	/** The whole text of an entry (D134). Past about 512 MiB a string cannot hold it and this throws: use `readContentBytes`. */
	readContent(entry: Pick<FeedEntry, "position" | "ordinal">): Promise<string> {
		return readContent(this.#link, this.id, entry);
	}

	/** The whole text of an entry as UTF-8 bytes, up to the Host's limit of about 1 GiB. */
	readContentBytes(entry: Pick<FeedEntry, "position" | "ordinal">): Promise<Buffer> {
		return readContentBytes(this.#link, this.id, entry);
	}

	/** Sends a Message. The receipt is its admission number; the answer arrives in the feed (D8). */
	async send(text: string, options: SendOptions): Promise<{ messageId: string }> {
		const body = (store: string) =>
			JSON.stringify({
				version: WIRE_VERSION,
				kind: "message",
				store,
				key: options.idempotencyKey,
				session: this.id,
				sender: null,
				sender_handle: null,
				text: { state: "value", value: text },
			} satisfies Schemas["MessageRequest"]);
		const reply = parse<Schemas["MessageReply"]>(await this.#link.exchange("/v1/message", body, environmentBytes(options.env)));
		const messageId = accepted(reply.answer).admission;
		this.#link.activity?.notify(this.id);
		return { messageId };
	}

	/** Changes settings. Omitted fields stay as they are. Resolves once the Host accepted the change (D7). */
	async update(fields: SessionUpdate, options?: WriteOptions): Promise<void> {
		const idempotencyKey = key(options);
		const reply = parse<Schemas["ConfigureReply"]>(
			await this.#link.exchange("/v1/configure", (store) => configureBody(store, idempotencyKey, this.id, fields)),
		);
		accepted(reply.answer);
		this.#link.activity?.notify(this.id);
	}

	/** Stops the current and queued work. The Session stays usable (D14). */
	async stop(options?: WriteOptions): Promise<void> {
		const idempotencyKey = key(options);
		const body = (store: string) =>
			JSON.stringify({
				version: WIRE_VERSION,
				kind: "session_stop",
				store,
				key: idempotencyKey,
				session: this.id,
			} satisfies Schemas["SessionStopRequest"]);
		accepted(parse<Schemas["SessionStopReply"]>(await this.#link.exchange("/v1/control/session-stop", body)).answer);
		this.#link.activity?.notify(this.id);
	}

	/**
	 * Cuts off the model call that is current now while the Session keeps going.
	 * It takes no key: each call names the work it sees at that moment, so a
	 * repeat is a new cut, not a replay. Resolves without effect when no model
	 * call is current, or when the call ended before the cut arrived (D167, D171).
	 */
	async interrupt(): Promise<void> {
		const page = parse<Schemas["ActivityPageReply"]>(
			await this.#link.exchange(
				"/v1/activity-page",
				(store) =>
					JSON.stringify({
						version: WIRE_VERSION,
						kind: "activity_page",
						store,
						session: this.id,
						end: null,
						position: "0",
						ordinal: null,
						direction: "backward",
						kinds: [...FEED_KINDS],
						limit: "1",
					} satisfies Schemas["ActivityPageRequest"]),
			),
		);
		const { turn, operation } = page.work;
		if (turn === null || operation === null || !modelCallCurrent(page.work.state.kind)) {
			this.#link.activity?.notify(this.id);
			return;
		}
		const idempotencyKey = randomUUID();
		const body = (store: string) =>
			JSON.stringify({
				version: WIRE_VERSION,
				kind: "model_interruption",
				store,
				key: idempotencyKey,
				target: { session: this.id, turn, operation },
			} satisfies Schemas["ModelInterruptionRequest"]);
		try {
			accepted(parse<Schemas["ModelInterruptionReply"]>(await this.#link.exchange("/v1/control/model-interruption", body)).answer);
		} catch (error) {
			// The call ended before the cut reached it: nothing is left to cut.
			const gone = error instanceof RuiRequestError && (error.code === "operation_resolved" || error.code === "target_mismatch");
			if (!gone) throw error;
		}
		this.#link.activity?.notify(this.id);
	}

	/** Answers an approval. `requestId` is the Action id of the `approval_requested` entry (D15). */
	async decide(requestId: string, decision: "allow" | "deny", options?: WriteOptions): Promise<void> {
		const idempotencyKey = key(options);
		const wire = decision === "allow" ? "allow_once" : "deny";
		const body = (store: string) =>
			JSON.stringify({
				version: WIRE_VERSION,
				kind: "permission_decision",
				store,
				key: idempotencyKey,
				session: this.id,
				action: requestId,
				decision: wire,
			} satisfies Schemas["PermissionDecisionRequest"]);
		accepted(parse<Schemas["PermissionDecisionReply"]>(await this.#link.exchange("/v1/control/permission-decision", body)).answer);
		this.#link.activity?.notify(this.id);
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
					(store) => JSON.stringify({
						version: WIRE_VERSION,
						kind: "list_sessions",
						store,
						workspace: null,
						after: wireAfter,
						ceiling: wireCeiling,
					} satisfies Schemas["ListSessionsRequest"]),
				),
			);
			for (const row of page.sessions) {
				summaries.push({ id: row.reference, label: row.label, state: row.work.state.kind, parent: row.parent });
			}
			if (page.next === null || !("after" in page.next)) return summaries.reverse();
			after = page.next.after;
			ceiling = page.next.ceiling;
		}
	}
}

/** The models each provider offers (D128). */
export async function models(link: Link): Promise<ModelSummary[]> {
	const reply = parse<Schemas["ModelListReply"]>(
		await link.exchange("/v1/model-list", (store) => JSON.stringify({
			version: WIRE_VERSION,
			kind: "model_list",
			store,
		} satisfies Schemas["ModelListRequest"]), undefined, {
			// A live provider list can take longer than the default response wait.
			responseMs: 30_000,
		}),
	);
	return reply.providers.flatMap((entry) => entry.models.map((model) => ({ provider: entry.provider, id: model.id, known: model.known })));
}

/** Holds every new Turn while paused; running work continues (D199). */
export async function setPaused(link: Link, paused: boolean): Promise<void> {
	await link.exchange("/v1/control/host-pause", (store) => JSON.stringify({
		version: WIRE_VERSION,
		kind: "host_pause",
		store,
		paused,
	} satisfies Schemas["HostPauseRequest"]));
}
