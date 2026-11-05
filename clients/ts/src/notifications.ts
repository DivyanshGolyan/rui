// Owned by one Rui instance. Only active followers occupy the per-Session map.
export class SessionNotifications {
	readonly #sessions = new Map<string, Set<WriteWatch>>();

	watch(session: string): WriteWatch {
		let watches = this.#sessions.get(session);
		if (!watches) this.#sessions.set(session, (watches = new Set()));
		const watch = new WriteWatch(() => {
			if (watches.delete(watch) && watches.size === 0) this.#sessions.delete(session);
		});
		watches.add(watch);
		return watch;
	}

	/** Rejects and releases every active follower, including one still reading its page. */
	fail(error: Error): void {
		for (const watches of this.#sessions.values()) {
			for (const watch of watches) watch.fail(error);
		}
	}

	notify(session: string): void {
		for (const watch of this.#sessions.get(session) ?? []) watch.notify();
	}
}

class WriteWatch {
	revision = 0;
	readonly #release: () => void;
	#wake: ((error?: Error) => void) | undefined;
	#error: Error | undefined;

	constructor(release: () => void) {
		this.#release = release;
	}

	notify(): void {
		this.revision++;
		this.#wake?.();
	}

	wait(revision: number, signal: AbortSignal | undefined): Promise<void> {
		return new Promise((resolve, reject) => {
			if (signal?.aborted) return resolve();
			if (this.#error) return reject(this.#error);
			if (this.revision !== revision) return resolve();
			const done = (error?: Error) => {
				signal?.removeEventListener("abort", abort);
				this.#wake = undefined;
				if (error) reject(error);
				else resolve();
			};
			const abort = () => done();
			this.#wake = done;
			signal?.addEventListener("abort", abort, { once: true });
		});
	}

	fail(error: Error): void {
		this.#error = error;
		this.#wake?.(error);
		this.close();
	}

	close(): void {
		this.#wake?.();
		this.#release();
	}
}
