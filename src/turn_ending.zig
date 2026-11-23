pub const TurnEnding = enum {
    done,
    context_full,
    provider_refused,
    out_of_quota,
    provider_unavailable,
    stopped,
    interrupted,
    failed,
};
