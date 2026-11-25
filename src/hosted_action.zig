// The hosted action a provider reports on a web search call. This is its one definition:
// codec_abi and output_format name it through this file, so the decoder, the output record and
// the settled call share one type and need no conversion between them.
pub const HostedAction = enum(u8) { none = 0, search = 1, open_page = 2, find_in_page = 3 };
