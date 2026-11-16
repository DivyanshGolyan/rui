pub const TurnEnding = enum {
    done,
    context_full,
    provider_refused,
    provider_unavailable,
    stopped,
    interrupted,
    failed,
};
