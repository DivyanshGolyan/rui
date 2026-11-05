// Owned by one Rui instance. Only active followers occupy the per-Session map.
export class SessionNotifications {
	readonly #sessions = new Map<string, Set<WriteWatch>>();

	watch(session: string): WriteWatch {
		let watches = this.#sessions.get(session);
		if (!watches) this.#sessions.set(session, (watches = new Set()));
		const watch = new WriteWatch(() => {
			watches.delete(watch);
			if (watches.size === 0) this.#sessions.delete(session);
		});
		watches.add(watch);
		return watch;
	}

	notify(session: string): void {
		for (const watch of this.#sessions.get(session) ?? []) watch.notify();
	}
}

class WriteWatch {
	revision = 0;
	readonly #release: () => void;
	#wake: (() => void) | undefined;

	constructor(release: () => void) {
		this.#release = release;
	}

	notify(): void {
		this.revision++;
		this.#wake?.();
	}

	wait(revision: number, signal: AbortSignal | undefined): Promise<void> {
		return new Promise((resolve) => {
			if (this.revision !== revision || signal?.aborted) return resolve();
			const done = () => {
				signal?.removeEventListener("abort", done);
				this.#wake = undefined;
				resolve();
			};
			this.#wake = done;
			signal?.addEventListener("abort", done, { once: true });
		});
	}

	close(): void {
		this.#wake?.();
		this.#release();
	}
}
