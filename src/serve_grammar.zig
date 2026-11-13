//! Foreground Host serve options and conflicts.
const std = @import("std");
const grammar = @import("cli_grammar.zig");
const product_defaults = @import("product_defaults.zig");
const provider_name = @import("provider_name.zig");
const retention_capacity = @import("retention_capacity.zig");
const Option = grammar.Option;
const Conflict = grammar.Conflict;
const value = grammar.value;
const repeatedChoice = grammar.repeatedChoice;
const hiddenValue = grammar.hiddenValue;
const hiddenNumber = grammar.hiddenNumber;
const hiddenFlag = grammar.hiddenFlag;
pub const destination = &[_]Option{ value("store", "PATH"), grammar.hex("store-hex", "store", 492) };

const endpoint_conflicts = &[_]Conflict{
    .{ .code = .provider_excludes_endpoint, .a = "provider", .b = "provider-endpoint" },
    .{ .code = .provider_excludes_ca_file, .a = "provider", .b = "provider-ca-file" },
    .{ .code = .provider_excludes_codex_fixture, .a = "provider", .b = "test-codex-fixture-endpoint" },
    .{ .code = .codex_fixture_excludes_endpoint, .a = "test-codex-fixture-endpoint", .b = "provider-endpoint" },
    .{ .code = .openai_fixture_excludes_endpoint, .a = "test-openai-fixture-endpoint", .b = "provider-endpoint" },
};
/// Host fault injection and observation, consumed only by host serve.
const serve_test = &[_]Option{
    .{ .name = "fault", .argument = "VALUE", .hidden = true, .repeated = true },
    hiddenValue("test-models-dev-url"),
    hiddenValue("test-codex-fixture-endpoint"),
    hiddenValue("test-openai-fixture-endpoint"),
    hiddenValue("test-chatgpt-fixture-endpoint"),
    hiddenNumber("test-bash-scratch-limit-bytes", 0, std.math.maxInt(u64)),
    hiddenNumber("test-retention-entry-capacity", 2, retention_capacity.entries),
    hiddenFlag("test-retention-removal-failure"),
    hiddenNumber("test-provider-inactivity-seconds", 1, std.math.maxInt(i64) / 1_000_000_000),
    hiddenValue("test-retry-waits-ms"),
    hiddenNumber("test-before-launch-delay-ms", 0, 10_000),
    hiddenNumber("test-before-result-delay-ms", 0, 10_000),
    hiddenValue("test-model-result-gate-path"),
    hiddenValue("test-retry-recovery-gate-path"),
    hiddenValue("test-inspection-reply-gate-path"),
    hiddenNumber("test-inspection-reply-delay-ms", 0, 60_000),
    hiddenNumber("test-client-send-buffer-bytes", 1, std.math.maxInt(c_int)),
    hiddenFlag("test-phase-trace"),
    hiddenNumber("test-observation-fd", 0, std.math.maxInt(c_int)),
    hiddenNumber("test-observation-state-fd", 0, std.math.maxInt(c_int)),
    hiddenValue("test-observation-plan"),
    hiddenValue("test-transition"),
    hiddenValue("test-transition-gate-path"),
    hiddenValue("test-bash-observed-exit-gate-path"),
    hiddenValue("test-shutdown-signalled-gate-path"),
    hiddenValue("test-bash-cleanup-gate-path"),
    hiddenValue("test-control-gate-keys"),
    hiddenValue("test-control-gate-path"),
    hiddenFlag("test-suppress-first-control-hint"),
    hiddenFlag("test-sqlite-diagnostics"),
    hiddenFlag("test-sqlite-cache-spill-off"),
    hiddenNumber("test-sqlite-cache-kib", 1, 4096),
    hiddenNumber("test-request-scratch-limit", 0, std.math.maxInt(u64)),
    hiddenNumber("test-request-preparation-byte-allowance", 1, std.math.maxInt(usize)),
    hiddenNumber("test-request-preparation-item-allowance", 1, std.math.maxInt(usize)),
    hiddenNumber("test-request-preparation-advance-delay-ms", 0, std.math.maxInt(i64)),
};

pub const definition: grammar.Definition = .{ .resource = .host, .name = "serve", .description = std.fmt.comptimePrint("Run a foreground Host. Provider credentials belong to this Host, not its peer callers. Each --provider LABEL serves that provider at its own endpoint with its own credential. Without --settings, --provider or a development endpoint it makes no model requests. --active-capacity defaults to {d}. --settings FILE reads a private settings document; --settings - reads one length-prefixed document on stdin. Serve flags override the document. interface.lifetime selects whether closing stdin stops the Host. A MySQL TCP Store URL accepts only ssl-ca=<absolute PEM path> (percent escapes allowed) for exclusive CA trust; sockets refuse it and verification cannot be disabled.", .{product_defaults.active_capacity}), .options = destination ++ &[_]Option{ value("active-capacity", "N"), repeatedChoice("provider", provider_name.Provider), value("provider-endpoint", "URL"), value("provider-ca-file", "PATH"), value("bash-path", "PATH"), value("bash-timeout-ms", "MILLISECONDS"), value("settings", "FILE|-") } ++ serve_test, .conflicts = endpoint_conflicts };
