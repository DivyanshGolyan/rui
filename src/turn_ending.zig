//! How a Turn ended.

/// How a Turn ended, as its `turn_ended` Activity row names it.
pub const TurnEnding = enum {
    /// The Turn's answer is its `final` assistant row.
    done,
    /// The conversation no longer fits the model's context, even after compaction.
    context_full,
    /// The provider answered with a refusal that resending will meet again.
    provider_refused,
    /// The provider could not be reached, or retries ran out.
    provider_unavailable,
    /// A Session stop ended it.
    stopped,
    /// A Model Interruption ended it.
    interrupted,
    /// Any other failure, which the row's `code` names.
    failed,
};
