// The hosted action a provider reports on a web search call. This is its one definition:
// codec_abi and output_format name it through this file, so the decoder, the output record and
// the settled call share one type and need no conversion between them.
pub const HostedAction = enum(u8) { none = 0, search = 1, open_page = 2, find_in_page = 3 };

/// The most targets one hosted call keeps as public facts. A provider that names more keeps the rest only in the
/// private item bag, which replay reads, so a long list can neither fail a settlement nor outgrow a content batch.
/// Every layer that bounds `targets_total` names this one.
pub const max_targets = 64;
