// Generated from src/turn_ending.zig by `zig build openapi`. Do not edit.
/** What each Turn ending means to a person: it finished, it was stopped, or it failed. */
export const ENDING_SIGN = {
	"done": "finished",
	"context_full": "failed",
	"provider_refused": "failed",
	"out_of_quota": "failed",
	"provider_unavailable": "failed",
	"stopped": "stopped",
	"interrupted": "stopped",
	"failed": "failed",
} as const;
