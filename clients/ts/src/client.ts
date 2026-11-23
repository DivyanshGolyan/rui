import { spawn, type ChildProcess } from "node:child_process";
import { EventEmitter } from "node:events";
import { mkdtemp, rm, stat, symlink } from "node:fs/promises";
import type { Socket } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { StringDecoder } from "node:string_decoder";
import { setTimeout as sleep } from "node:timers/promises";

import { prepareSettings, type HostSettings, type PreparedSettings } from "./settings.ts";
import { SessionNotifications } from "./notifications.ts";
import { resolveBinary } from "./binary.ts";
import { TRANSPORT_ENVIRONMENT } from "./host-environment.ts";
import { RuiRequestError, RuiStartError, RuiStoreFailedError, RuiUnavailableError } from "./errors.ts";
import { models, reloadTools, Session, Sessions, setPaused, type AgentSpec, type ModelSummary, type ToolReloadOutcome } from "./sessions.ts";
import { ConnectionError, post, WIRE_VERSION, type ReplyLimits } from "./transport.ts";
import type { components } from "./wire.ts";

type Schemas = components["schemas"];

export type { HostSettings } from "./settings.ts";

/** Options belonging to the client, not the Host settings document. */
export interface ClientOptions {
	/** How long connect retries another Host's Store lock. Default 120 000 ms. */
	lockWaitMs?: number;
	/** Default: the installed platform package's executable; `connect` refuses when there is none. */
	binary?: string;
}

/** Fires on every child exit, including one the client restarts from (D129). */
export interface ExitEvent {
	code: number | null;
	signal: NodeJS.Signals | null;
	restarting: boolean;
}

type HostInfo = components["schemas"]["HostInfoReply"];

const SOCKET_NAME = "rui.sock";
const DEFAULT_LOCK_WAIT_MS = 120_000;
const LOCK_RETRY_MS = 500;
const FIRST_RESTART_MS = 500;
const MAX_RESTART_MS = 30_000;
const CLOSE_GRACE_MS = 15_000;
const READY_POLL_MS = 25;
const READINESS_RECEIPT_BYTES = Buffer.byteLength("ready instance=") + 32 + 1;
const OUTPUT_GRACE_MS = 1_000;
const MAX_LINE_CHARS = 64 * 1024;
const RETRYABLE_START_CODES = new Set<RuiStartError["code"]>(["store_locked", "mysql_unreachable"]);

interface Exit {
	code: number | null;
	signal: NodeJS.Signals | null;
}

interface Host {
	child: ChildProcess;
	instance: string;
	info: HostInfo;
	exited: Promise<Exit>;
	/** Settles once the child's stdout has closed, so every line it wrote has been read. */
	output: Promise<void>;
	/** Settles with the `store_fenced` refusal the child writes on stdout before it exits. */
	fenced: Promise<RuiStartError>;
}

interface Waiter {
	resolve: (host: Host) => void;
	reject: (error: Error) => void;
}

interface Launch {
	binary: string;
	document: Buffer;
	interfaceDir: PreparedSettings["interfaceDir"];
	aliasReady?: Promise<void>;
	detached: boolean;
	socketPath: string;
	env: NodeJS.ProcessEnv;
}

class AttemptFailed extends Error {
	readonly error: Error;
	readonly exit: Exit | undefined;

	constructor(error: Error, exit: Exit | undefined) {
		super(error.message);
		this.error = error;
		this.exit = exit;
	}
}

export class Rui extends EventEmitter<{ exit: [ExitEvent] }> {
	readonly #launch: Launch;
	readonly #runtimeDir: string;
	#host: Host | undefined;
	#child: ChildProcess | undefined;
	#waiters: Waiter[] = [];
	#backoff = FIRST_RESTART_MS;
	#restart: NodeJS.Timeout | undefined;
	#closing: Promise<void> | undefined;
	#dead: Error | undefined;
	#storeFailed: RuiStoreFailedError | undefined;
	readonly activity = new SessionNotifications();
	/** Create and list Sessions. */
	readonly sessions: Sessions = new Sessions(this);

	private constructor(launch: Launch, runtimeDir: string, host: Host) {
		super();
		this.#launch = launch;
		this.#runtimeDir = runtimeDir;
		this.#adopt(host);
	}

	/** Starts Rui as a child of this process and resolves once it is ready. */
	static async connect(settings: HostSettings, options: ClientOptions = {}): Promise<Rui> {
		const runtimeDir = await mkdtemp(join(tmpdir(), "rui-"));
		let launch: Launch | undefined;
		try {
			launch = launchFor(settings, runtimeDir, options);
			const deadline = Date.now() + (options.lockWaitMs ?? DEFAULT_LOCK_WAIT_MS);
			for (;;) {
				try {
					return new Rui(launch, runtimeDir, await start(launch, () => {}));
				} catch (failure) {
					const error = failure instanceof AttemptFailed ? failure.error : (failure as Error);
					const remaining = deadline - Date.now();
					if (!(error instanceof RuiStartError && error.code === "store_locked") || remaining <= 0) throw error;
					await sleep(Math.min(LOCK_RETRY_MS, remaining));
				}
			}
		} catch (error) {
			if (launch) disposeLaunch(launch);
			await rm(runtimeDir, { recursive: true, force: true });
			throw error;
		}
	}

	/** A handle on an existing Session. Does no I/O: an unknown id fails on the first call (D16). */
	getSession(id: string): Session {
		return new Session(this, id);
	}

	/** The models each provider offers. */
	models(): Promise<ModelSummary[]> {
		return models(this);
	}

	/** Holds every new Turn until `resume`. Running work continues. */
	pause(): Promise<void> {
		return setPaused(this, true);
	}

	resume(): Promise<void> {
		return setPaused(this, false);
	}

	/**
	 * Lists one MCP server, or every configured server when `server` is omitted, again, and resolves once each list has
	 * landed. Rejects with RuiWaitTimeoutError after 60 s.
	 */
	reloadTools(server?: string): Promise<ToolReloadOutcome[]> {
		return reloadTools(this, server);
	}

	/**
	 * Closes the child's stdin and resolves once it has exited, bounded by the
	 * Host's 10 s shutdown (D129). Later calls fail with RuiUnavailableError.
	 */
	close(): Promise<void> {
		this.#closing ??= this.#close();
		return this.#closing;
	}

	async #close(): Promise<void> {
		clearTimeout(this.#restart);
		this.#fail(new RuiUnavailableError("the Rui client is closed"));
		const child = this.#child;
		this.#host = undefined;
		try {
			if (child && child.exitCode === null && child.signalCode === null) {
				const exited = exitOf(child);
				child.stdin?.end();
				if (this.#launch.detached) child.kill("SIGTERM");
				const timer = setTimeout(() => child.kill("SIGKILL"), CLOSE_GRACE_MS);
				const exit = await exited;
				clearTimeout(timer);
				this.emit("exit", { ...exit, restarting: false });
			}
		} finally {
			disposeLaunch(this.#launch);
			await rm(this.#runtimeDir, { recursive: true, force: true });
		}
	}

	async call(path: string, body: string, environment?: Buffer, limits?: ReplyLimits): Promise<Buffer> {
		let retried = false;
		for (;;) {
			const host = await this.#ready();
			try {
				return await post({
					socketPath: this.#launch.socketPath,
					path,
					body,
					instance: host.instance,
					...(environment ? { environment } : {}),
					...(limits ? { limits } : {}),
				});
			} catch (error) {
				if (this.#storeFailed) throw this.#storeFailed;
				if (error instanceof RuiRequestError && isCanonicalFailure(error)) throw this.#latchStoreFailed(error);
				// dispatch_fenced also comes from stop and cleanup phases, so it is classified only once the Host has exited.
				if (error instanceof RuiRequestError && isDispatchFenced(error)) {
					await settle(host);
					throw this.#storeFailed ?? error;
				}
				if (!(error instanceof ConnectionError)) throw error;
				const gone = await settle(host);
				if (this.#storeFailed) throw this.#storeFailed;
				if (!gone || retried) throw new RuiUnavailableError("the Rui Host did not answer", { cause: error });
				retried = true;
			}
		}
	}

	async exchange(path: string, build: (store: string) => string, environment?: Buffer, limits?: ReplyLimits): Promise<Buffer> {
		const host = await this.#ready();
		return this.call(path, build(host.info.store), environment, limits);
	}

	get pid(): number | undefined {
		return this.#host?.child.pid;
	}

	get hostInfo(): HostInfo | undefined {
		return this.#host?.info;
	}

	#ready(): Promise<Host> {
		if (this.#closing) return Promise.reject(new RuiUnavailableError("the Rui client is closed"));
		if (this.#storeFailed) return Promise.reject(this.#storeFailed);
		if (this.#host) return Promise.resolve(this.#host);
		const failed = this.#dead;
		if (failed) return Promise.reject(failed);
		this.#restart?.ref();
		return new Promise((resolve, reject) => this.#waiters.push({ resolve, reject }));
	}

	#adopt(host: Host): void {
		this.#host = host;
		this.#child = host.child;
		this.#backoff = FIRST_RESTART_MS;
		for (const waiter of this.#waiters.splice(0)) waiter.resolve(host);
		void host.fenced.then((cause) => this.#latchStoreFailed(cause));
		void host.exited.then(async (exit) => {
			await drained(host);
			if (this.#closing || this.#host !== host) return;
			this.#host = undefined;
			this.emit("exit", { ...exit, restarting: this.#storeFailed === undefined });
			this.#scheduleRestart();
		});
	}

	/**
	 * The one owner of the Store-failed latch. Every fence signal reaches it: a reply that `isStoreFence`, and the
	 * `store_fenced` line. The first latch wins, rejects the pending calls with the same error and stops restarts.
	 */
	#latchStoreFailed(cause: unknown): RuiStoreFailedError {
		if (this.#storeFailed) return this.#storeFailed;
		this.#storeFailed = new RuiStoreFailedError({ cause });
		clearTimeout(this.#restart);
		this.#fail(this.#storeFailed);
		return this.#storeFailed;
	}

	#fail(error: Error): void {
		this.activity.fail(error);
		for (const waiter of this.#waiters.splice(0)) waiter.reject(error);
	}

	#scheduleRestart(): void {
		if (this.#closing || this.#storeFailed) return;
		const delay = this.#backoff;
		this.#backoff = Math.min(this.#backoff * 2, MAX_RESTART_MS);
		this.#restart = setTimeout(() => void this.#restartNow(), delay);
		if (this.#waiters.length === 0) this.#restart.unref();
	}

	async #restartNow(): Promise<void> {
		if (this.#storeFailed) return;
		try {
			const host = await start(this.#launch, (child) => {
				this.#child = child;
			});
			if (this.#closing) {
				host.child.stdin?.end();
				return;
			}
			if (this.#storeFailed) {
				host.child.stdin?.end();
				if (this.#launch.detached) host.child.kill("SIGTERM");
				return;
			}
			this.#adopt(host);
		} catch (failure) {
			if (this.#closing) return;
			const error = failure instanceof AttemptFailed ? failure.error : (failure as Error);
			const exit = failure instanceof AttemptFailed ? failure.exit : undefined;
			const retryable =
				error instanceof RuiUnavailableError || (error instanceof RuiStartError && RETRYABLE_START_CODES.has(error.code));
			if (exit) this.emit("exit", { ...exit, restarting: retryable });
			this.#fail(new RuiUnavailableError(`the Rui Host could not restart: ${error.message}`, { cause: error }));
			if (retryable) return this.#scheduleRestart();
			this.#dead = new RuiUnavailableError(`the Rui Host cannot restart: ${error.message}`, { cause: error });
			disposeLaunch(this.#launch);
		}
	}
}

/**
 * The application's environment a child Host inherits: process basics, and the proxy and trust variables its transport
 * reads, so a Host behind a proxy or a private CA reaches its provider and models.dev. Secrets reach it only through
 * `{ env }` sources in the settings.
 */
export const INHERITED_ENVIRONMENT = ["PATH", "HOME", "TMPDIR", ...TRANSPORT_ENVIRONMENT] as const;

export function launchFor(settings: HostSettings, runtimeDir: string, options: ClientOptions = {}): Launch {
	const env: NodeJS.ProcessEnv = Object.create(null);
	for (const name of INHERITED_ENVIRONMENT) {
		const value = process.env[name];
		if (value !== undefined) env[name] = value;
	}
	const { document, interfaceDir, detached } = prepareSettings(settings, runtimeDir, env);
	return {
		binary: resolveBinary(options.binary), document: encodeSettings(document), interfaceDir,
		socketPath: join(runtimeDir, "interface", SOCKET_NAME), env, detached,
	};
}

function disposeLaunch(launch: Launch): void {
	launch.document.fill(0);
	for (const name of Object.keys(launch.env)) delete launch.env[name];
}

async function start(launch: Launch, spawned: (child: ChildProcess) => void): Promise<Host> {
	let child: ChildProcess;
	try {
		child = spawn(launch.binary, ["host", "serve", "--settings", "-"], {
			env: launch.env,
			stdio: ["pipe", "pipe", "inherit"],
		});
	} catch (error) {
		throw new AttemptFailed(new RuiUnavailableError(`could not start ${launch.binary}`, { cause: error }), undefined);
	}
	spawned(child);
	const stdout: Buffer[] = [];
	const receipt = Buffer.alloc(READINESS_RECEIPT_BYTES);
	let receiptBytes = 0;
	let readyInstance: string | undefined;
	let outputBytes = 0;
	const capture = (chunk: Buffer) => {
		if (receiptBytes < receipt.length) {
			receiptBytes += chunk.copy(receipt, receiptBytes, 0, receipt.length - receiptBytes);
			if (receiptBytes === receipt.length) readyInstance = readinessInstance(receipt);
		}
		if (outputBytes + chunk.length <= 64 * 1024) {
			stdout.push(chunk);
			outputBytes += chunk.length;
		} else chunk.fill(0);
	};
	child.stdout?.on("data", capture);
	const decoder = new StringDecoder("utf8");
	let pending = "";
	const fenceIn = (line: string) => {
		const refusal = line.includes("store_fenced") ? startError(line) : undefined;
		if (refusal?.code === "store_fenced") fence(refusal);
	};
	const watch = (chunk: Buffer) => {
		const lines = (pending + decoder.write(chunk)).split("\n");
		chunk.fill(0);
		pending = lines.pop() ?? "";
		if (pending.length > MAX_LINE_CHARS) pending = "";
		for (const line of lines) fenceIn(line);
	};
	const outputEnded = new Promise<void>((done) => child.stdout?.once("close", done));
	const launchError = new Promise<Error>((done) => child.once("error", done));
	let fence!: (cause: RuiStartError) => void;
	const fenced = new Promise<RuiStartError>((done) => (fence = done));
	let ready = false;
	const exited = exitOf(child);
	child.unref();
	(child.stdout as Socket | null)?.unref();
	(child.stdin as unknown as Socket | null)?.unref();
	child.stdin?.on("error", () => {});
	const bytes = Buffer.from(launch.document);
	const wipeWrite = () => bytes.fill(0);
	child.stdin?.once("close", wipeWrite);
	child.stdin?.write(bytes, () => {
		bytes.fill(0);
		child.stdin?.off("close", wipeWrite);
	});

	try {
		let ended: Exit | Error | undefined;
		void exited.then((exit) => (ended ??= exit));
		void launchError.then((error) => (ended ??= error));
		while (ended === undefined) {
			const info = readyInstance === undefined ? undefined : await probe(launch, readyInstance).catch(async (error: unknown) => {
				if (error instanceof ConnectionError) return undefined;
				child.kill("SIGKILL");
				throw new AttemptFailed(error as Error, await exited);
			});
			if (info) {
				child.stdout?.off("data", capture);
				child.stdout?.on("data", watch);
				void outputEnded.then(() => fenceIn(pending));
				ready = true;
				return { child, instance: info.instance, info, exited, output: outputEnded, fenced };
			}
			await sleep(READY_POLL_MS);
		}
		if (ended instanceof Error) {
			throw new AttemptFailed(new RuiUnavailableError(`could not start ${launch.binary}: ${ended.message}`, { cause: ended }), undefined);
		}
		await Promise.race([outputEnded, sleep(1_000)]);
		const output = Buffer.concat(stdout);
		let refusal: RuiStartError | undefined;
		try {
			refusal = startError(output.toString("utf8"));
		} finally {
			output.fill(0);
		}
		throw new AttemptFailed(
			refusal ?? new RuiUnavailableError(`rui exited before it was ready (code ${ended.code}, signal ${ended.signal})`),
			ended,
		);
	} finally {
		if (!ready) {
			child.stdout?.off("data", capture);
			child.stdout?.on("data", (chunk: Buffer) => chunk.fill(0));
		}
		receipt.fill(0);
		for (const chunk of stdout) chunk.fill(0);
		stdout.length = 0;
	}
}

/** The Host's 500 reply for a fenced Store, the stable signal the Store fence latches on. */
function isCanonicalFailure(error: RuiRequestError): boolean {
	return error.type === "invocation_error" && error.code === "canonical_store_failure";
}

/** The Host's 503 reply while it is not in its open phase: a stop, a cleanup fence or a Store fence. Not a signal alone. */
function isDispatchFenced(error: RuiRequestError): boolean {
	return error.type === "host_unavailable" && error.code === "dispatch_fenced";
}

/** Resolves with `done`, or with `fallback` once `ms` passes. The timer is cleared as soon as the wait settles. */
async function bounded<T>(done: Promise<T>, ms: number, fallback: T): Promise<T> {
	const cancel = new AbortController();
	try {
		return await Promise.race([done, sleep(ms, fallback, { signal: cancel.signal })]);
	} catch {
		return fallback;
	} finally {
		cancel.abort();
	}
}

/**
 * Waits for a lost or fenced child to exit, bounded by the shutdown grace (D129), then for its stdout to drain so a final
 * `store_fenced` line has been read. Resolves whether the child exited in time.
 */
async function settle(host: Host): Promise<boolean> {
	const gone = await bounded(host.exited.then(() => true), CLOSE_GRACE_MS, false);
	if (gone) await drained(host);
	return gone;
}

/** Lets a stopped child's stdout deliver its final lines, bounded so a grandchild holding the pipe cannot stall us. */
async function drained(host: Host): Promise<void> {
	await bounded(host.output, OUTPUT_GRACE_MS, undefined);
}

async function createInterfaceAlias(launch: Launch): Promise<void> {
	const dir = launch.interfaceDir;
	const target = typeof dir === "string" ? dir : Buffer.from(dir.hex, "hex");
	// An ASCII alias lets Node's string-only socket API reach OS-byte directories.
	await symlink(target, dirname(launch.socketPath));
}

async function probe(launch: Launch, instance: string): Promise<HostInfo | undefined> {
	await (launch.aliasReady ??= createInterfaceAlias(launch));
	try {
		await stat(launch.socketPath);
	} catch {
		return undefined;
	}
	const body = JSON.stringify({
		version: WIRE_VERSION,
		kind: "host_info",
		store: "",
	} satisfies Schemas["HostInfoRequest"]);
	const reply = await post({ socketPath: launch.socketPath, path: "/v1/host-info", body, instance });
	const info = JSON.parse(reply.toString("utf8")) as HostInfo;
	if (info.instance !== instance) throw new RuiUnavailableError("the Host socket did not match the started child's readiness instance");
	return info;
}

export function encodeSettings(document: Schemas["HostSettings"]): Buffer {
	const json = Buffer.from(JSON.stringify(document));
	try {
		const out = Buffer.alloc(4 + json.length);
		out.writeUInt32BE(json.length, 0);
		json.copy(out, 4);
		return out;
	} finally {
		json.fill(0);
	}
}

export function readinessInstance(prefix: Buffer): string | undefined {
	if (prefix.length !== READINESS_RECEIPT_BYTES) return undefined;
	return /^ready instance=([0-9a-f]{32}) $/.exec(prefix.toString("latin1"))?.[1];
}

export function startError(output: string): RuiStartError | undefined {
	for (const line of output.split("\n").reverse()) {
		if (!line.trim()) continue;
		try {
			const parsed: Partial<Schemas["StartError"]> | null = JSON.parse(line);
			const refusal = parsed?.rui_start_error;
			if (refusal && typeof refusal.code === "string") {
				return new RuiStartError(refusal.code, typeof refusal.message === "string" ? refusal.message : refusal.code);
			}
		} catch {
		}
	}
	return undefined;
}

function exitOf(child: ChildProcess): Promise<Exit> {
	if (child.exitCode !== null || child.signalCode !== null) {
		return Promise.resolve({ code: child.exitCode, signal: child.signalCode });
	}
	return new Promise((done) => child.once("exit", (code, signal) => done({ code, signal })));
}
