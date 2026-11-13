//! Loading saved tools is one call-keyed command, revision and resolution.
const std = @import("std");
const command_input = @import("../../command_input.zig");
const content_string = @import("../../content_string.zig");
const tool_name = @import("../../tool_name.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const core = @import("../../find_tools_words.zig");
const tools = @import("../../tool_record.zig");
const word_search = @import("../../word_search.zig");
const rsql = @import("../rsql.zig");
const action = @import("action.zig");
const command = @import("command.zig");
const content = @import("content.zig");
const tool_set = @import("tool_set.zig");
const configuration = @import("configuration.zig");
const tool_offer = @import("tool_offer.zig");
const store_core = @import("../Store.zig");
const transition = @import("../transition.zig");

const settings = rsql.Read(.{
    .sql = "SELECT revision,tool_set_id,loaded_tool_set_id FROM session WHERE session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct { revision: rsql.Positive, tool_set_id: rsql.Positive, loaded_tool_set_id: ?rsql.Positive },
    .cardinality = .one,
});

/// The shared current projection supplies available identities; only unloaded
/// records enter matching. Description text is streamed below, never copied.
const Candidate = struct { name: Bounded(tools.max_name_bytes), content_id: rsql.Positive, byte_length: u64, digest: [32]u8 };

const Candidates = struct {
    rows: [tool_name.max_tools]Candidate = undefined,
    count: usize = 0,
    invalid: bool = false,

    pub fn visit(self: *Candidates, row: *const tool_offer.OfferedRecord) bool {
        if (row.loaded) return true;
        if (self.count == self.rows.len) {
            self.invalid = true;
            return false;
        }
        self.rows[self.count] = .{ .name = row.name, .content_id = row.content_id, .byte_length = row.byte_length, .digest = row.description };
        self.count += 1;
        return true;
    }
};

const loaded_names = rsql.Read(.{
    .sql = "SELECT tool.name FROM tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id WHERE member.tool_set_id=?1 ORDER BY tool.name",
    .Args = struct { set: u64 },
    .Row = struct { name: Bounded(tools.max_name_bytes) },
    .cardinality = .each,
});

const LoadedNames = struct {
    names: command_input.ToolsField = .{ .state = .value },
    invalid: bool = false,

    pub fn visit(self: *LoadedNames, row: *const loaded_names.Row) bool {
        self.names.append(row.name.slice()) catch {
            self.invalid = true;
            return false;
        };
        return true;
    }
};

const Matches = struct {
    names: command_input.ToolsField = .{ .state = .value },
    rows: [8]Candidate = undefined,
    count: usize = 0,
    remaining: usize = 0,
};

/// Per-call, fixed-size heap scratch, never a description-sized allocation or
/// a Host stack window. Matcher's n-1 byte carry spans successive reads.
const SearchScratch = struct {
    window: [content.ContentReader.content_window_bytes]u8 = undefined,
    matchers: [8]word_search.Matcher = undefined,
};

const update_loaded = rsql.Write(.{
    .sql = "UPDATE session SET loaded_tool_set_id=?2,revision=?3 WHERE session_ref=@session(?1)",
    .Args = struct { session: rsql.SessionHead, loaded: ?u64, revision: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

const FirstLine = struct {
    writer: *std.Io.Writer,
    ended: bool = false,

    pub fn write(self: *FirstLine, bytes: []const u8) !void {
        if (self.ended) return;
        const end = std.mem.indexOfAny(u8, bytes, "\r\n") orelse bytes.len;
        try self.writer.writeAll(bytes[0..end]);
        self.ended = end != bytes.len;
    }
};

/// Loads the saved tools that match `words` into the call's Session and
/// resolves the call, in one transaction: one call-keyed command, revision
/// and resolution. A call whose key is saved, or whose Turn a stop
/// selected, ends with false.
///
/// Round `.facts` reads the call's Action and its key's saved answer, and
/// `.settings` the Session's tool sets. Unless the call was refused,
/// `.offer` reads the tools offered but not loaded, and each one whose
/// name no word matches is searched one `.search` window of its
/// description at a time. With matches, `.loaded` reads the names already
/// loaded, and the result lists each match with its description's first
/// line, read one `.describe` window at a time. `.outcome` looks the
/// result's row up; with matches, `.selection` reads the configured set's
/// records and `.selected` the loaded set they make. The commit round
/// saves the command, the revision and the call's resolution.
pub const FindTools = struct {
    pub const rounds = transition.rounds(.{
        .facts = .{.always},
        .settings = .{.always},
        .offer = .{.branch},
        .search = .{.raw},
        .loaded = .{.branch},
        .describe = .{.raw},
        .outcome = .{.always},
        .selection = .{.branch},
        .selected = .{.branch},
    });
    pub const round_budget = 4;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .facts;
    /// The caller's, which outlive the transition. `arena` holds the
    /// call's scratch, which keeps tool-name buffers off Host stacks, and
    /// its result text.
    pub const Input = struct {
        binding: action.ActionAttemptBinding,
        arena: std.mem.Allocator,
        words: *const core.FindTools,
        refusal: ?[]const u8,
    };
    pub const Result = bool;
    pub const Ordinary = store_core.Ordinary.action_attempt;
    pub const Guards = store_core.Ordinary.action_attempt;
    pub const Declined = error{};

    input: Input,
    /// The command key, in `arena`; the writes read it in place.
    key: []const u8 = &.{},
    facts: action.core_facts.Result = undefined,
    current: settings.Result = undefined,
    matches: *Matches = undefined,
    pending: *Candidates = undefined,
    scratch: *SearchScratch = undefined,
    loaded: *LoadedNames = undefined,
    /// The candidate searched, or the match described.
    index: usize = 0,
    /// What each round keeps, as one path runs them: the key's saved
    /// answer, then the description a `.search` or `.describe` round
    /// reads and the first line it writes.
    early: union {
        saved: command.saved_command.Result,
        reading: struct { windows: content.Windows, first: FirstLine },
    } = undefined,
    output: std.Io.Writer.Allocating = undefined,
    outcome: content.Import = undefined,
    /// What the rounds after `.outcome` keep, which the commit's writes
    /// read in place.
    answer: command.StoredAnswer = undefined,
    digest: [32]u8 = undefined,
    later: union {
        saved: tool_set.SavedSelection,
        selected: tool_set.Selection,
        /// Once the loaded set's writes are queued, which copied what
        /// they bind of `selected`.
        applied: configuration.Applied,
    } = undefined,
    outcome_id: u64 = 0,

    pub fn step(t: *FindTools, r: *transition.Round(FindTools), ran: ?rounds.At) !transition.Next(FindTools) {
        const at = ran orelse return t.start(r);
        switch (at) {
            .facts => return t.decide(r),
            .settings => return t.offer(r),
            .offer => return t.searchFirst(r),
            .search => return t.searchWindow(r),
            .loaded => return t.includeLoaded(r),
            .describe => return t.describeWindow(r),
            .outcome => return t.settle(r),
            .selection => return t.select(r),
            .selected => return t.load(r),
        }
    }

    // The steps that run a round's work are noinline, so none sits under
    // another on its thread's chain.
    noinline fn start(t: *FindTools, r: *transition.Round(FindTools)) !transition.Next(FindTools) {
        const binding = t.input.binding;
        t.key = try std.fmt.allocPrint(t.input.arena, "rui.core/find_tools/{d}", .{binding.action_id});
        t.early = .{ .saved = undefined };
        command.lookupCommand(r, t.key, &t.early.saved);
        const names: action.CoreNames = .of();
        r.read(action.core_facts, names.args(.{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id, .turn_id = binding.turn_id }), &t.facts);
        return .{ .round = .facts };
    }

    /// After `.facts`: a saved or stopped call ends.
    noinline fn decide(t: *FindTools, r: *transition.Round(FindTools)) !transition.Next(FindTools) {
        if (t.early.saved != null) return .{ .done = false };
        const found = if (t.facts) |*row| row else return error.StaleActionAttemptBinding;
        if (found.stopped) return .{ .done = false };
        r.read(settings, .{ .session = &found.session.ref }, &t.current);
        return .{ .round = .settings };
    }

    fn configured(t: *const FindTools) u64 {
        return t.current.tool_set_id.get();
    }

    fn loadedIntent(t: *const FindTools) ?u64 {
        return if (t.current.loaded_tool_set_id) |id| id.get() else null;
    }

    /// After `.settings`: a refused call writes its result; any other
    /// reads the tools it may load.
    noinline fn offer(t: *FindTools, r: *transition.Round(FindTools)) !transition.Next(FindTools) {
        const arena = t.input.arena;
        t.matches = try arena.create(Matches);
        t.matches.* = .{};
        if (t.input.refusal != null) return t.writeResult(r);
        t.pending = try arena.create(Candidates);
        t.pending.* = .{};
        tool_offer.project(r, t.configured(), t.loadedIntent(), t.pending);
        return .{ .round = .offer };
    }

    /// After `.offer`: searches the first candidate.
    noinline fn searchFirst(t: *FindTools, r: *transition.Round(FindTools)) !transition.Next(FindTools) {
        const pending = t.pending;
        if (pending.invalid) return error.CorruptStore;
        t.matches.remaining = pending.count;
        if (pending.count == 0) return t.includeLoadedFirst(r);
        t.scratch = try t.input.arena.create(SearchScratch);
        t.index = 0;
        return t.search(r);
    }

    /// Searches candidates from `index` on: one whose name a word matches
    /// matches at once; any other reads its description, a `.search`
    /// round a window, until a word matches or the description ends.
    fn search(t: *FindTools, r: *transition.Round(FindTools)) !transition.Next(FindTools) {
        const words = t.input.words;
        const scratch = t.scratch;
        while (t.index < t.pending.count) : (t.index += 1) {
            const row = &t.pending.rows[t.index];
            const named = for (words.words[0..words.count], 0..) |word, index| {
                const matcher = &scratch.matchers[index];
                matcher.init(word);
                matcher.feed(row.name.slice());
                if (matcher.count != 0) break true;
            } else false;
            if (named) {
                if (t.match()) break;
                continue;
            }
            // A word must match one field, never the end of a name plus the start of
            // its description. init also owns query folding, just as in feed search.
            for (words.words[0..words.count], 0..) |word, index| scratch.matchers[index].init(word);
            t.early = .{ .reading = .{ .windows = .{ .content_id = row.content_id.get(), .reference = .{ .length = row.byte_length, .digest = row.digest }, .buffer = &scratch.window }, .first = undefined } };
            if (try t.early.reading.windows.next(r)) return .{ .round = .search };
        }
        return t.includeLoadedFirst(r);
    }

    /// After a `.search` round: its window, fed to each word's matcher.
    noinline fn searchWindow(t: *FindTools, r: *transition.Round(FindTools)) !transition.Next(FindTools) {
        const windows = &t.early.reading.windows;
        const bytes = try windows.window();
        for (t.scratch.matchers[0..t.input.words.count]) |*matcher| {
            matcher.feed(bytes);
            if (matcher.count != 0) {
                if (t.match()) return t.includeLoadedFirst(r);
                t.index += 1;
                return t.search(r);
            }
        }
        if (try windows.next(r)) return .{ .round = .search };
        t.index += 1;
        return t.search(r);
    }

    /// Records candidate `index` as a match; true when no more fit.
    fn match(t: *FindTools) bool {
        const matches = t.matches;
        matches.rows[matches.count] = t.pending.rows[t.index];
        matches.count += 1;
        matches.remaining -= 1;
        return matches.count == matches.rows.len;
    }

    /// With matches, reads the names already loaded.
    fn includeLoadedFirst(t: *FindTools, r: *transition.Round(FindTools)) !transition.Next(FindTools) {
        if (t.matches.count == 0) return t.writeResult(r);
        t.loaded = try t.input.arena.create(LoadedNames);
        t.loaded.* = .{};
        r.readEach(loaded_names, .{ .set = t.loadedIntent() orelse t.configured() }, tool_name.max_tools + 1, t.loaded);
        return .{ .round = .loaded };
    }

    /// After `.loaded`: merges disjoint, ordered loaded intent and new
    /// available hits. Unavailable intended names stay, even when the hits
    /// cover all available tools.
    noinline fn includeLoaded(t: *FindTools, r: *transition.Round(FindTools)) !transition.Next(FindTools) {
        const loaded = t.loaded;
        const matches = t.matches;
        if (loaded.invalid) return error.CorruptStore;
        var names = loaded.names.iterator();
        var saved = names.next();
        var index: usize = 0;
        while (saved != null or index < matches.count) {
            if (index < matches.count and (saved == null or std.mem.lessThan(u8, matches.rows[index].name.slice(), saved.?))) {
                matches.names.append(matches.rows[index].name.slice()) catch return error.CorruptStore;
                index += 1;
            } else {
                matches.names.append(saved.?) catch return error.CorruptStore;
                saved = names.next();
            }
        }
        return t.writeResult(r);
    }

    /// Writes the call's result: a refusal, no match, or each match with
    /// its description's first line.
    fn writeResult(t: *FindTools, r: *transition.Round(FindTools)) !transition.Next(FindTools) {
        t.output = .init(t.input.arena);
        const out = &t.output.writer;
        const matches = t.matches;
        if (t.input.refusal) |reason| {
            try out.print("Rui could not find tools: {s}. Nothing was loaded.", .{reason});
        } else if (matches.count == 0) {
            try out.print("No tools matched. {d} tools are still not loaded.", .{matches.remaining});
        } else {
            try out.writeAll("Loaded these tools; they are available on your next request:\n");
            t.index = 0;
            return t.describe(r);
        }
        return t.lookupOutcome(r);
    }

    /// Describes matches from `index` on, each description read a
    /// `.describe` round a window.
    fn describe(t: *FindTools, r: *transition.Round(FindTools)) !transition.Next(FindTools) {
        const out = &t.output.writer;
        while (t.index < t.matches.count) : (t.index += 1) {
            const row = &t.matches.rows[t.index];
            try out.print("- {s}: ", .{row.name.slice()});
            t.early = .{ .reading = .{
                .windows = .{ .content_id = row.content_id.get(), .reference = .{ .length = row.byte_length, .digest = row.digest }, .buffer = t.scratch.window[0..content.verified_window_bytes] },
                .first = .{ .writer = out },
            } };
            if (try t.early.reading.windows.next(r)) return .{ .round = .describe };
            try out.writeAll("\n");
        }
        return t.lookupOutcome(r);
    }

    /// After a `.describe` round: its window's part of the first line.
    noinline fn describeWindow(t: *FindTools, r: *transition.Round(FindTools)) !transition.Next(FindTools) {
        const reading = &t.early.reading;
        try reading.first.write(try reading.windows.window());
        if (try reading.windows.next(r)) return .{ .round = .describe };
        try t.output.writer.writeAll("\n");
        t.index += 1;
        return t.describe(r);
    }

    fn lookupOutcome(t: *FindTools, r: *transition.Round(FindTools)) transition.Next(FindTools) {
        t.outcome = .ofBytes(t.output.written(), false);
        content.lookup(r, &t.outcome);
        return .{ .round = .outcome };
    }

    /// After `.outcome`: saves the result; with matches, reads the
    /// configured set's records the loaded set selects.
    noinline fn settle(t: *FindTools, r: *transition.Round(FindTools)) !transition.Next(FindTools) {
        if (r.faults().content_import) return error.InjectedContentImportFailure;
        const refused = t.input.refusal != null;
        const outcome_id = try content.importBytes(r, &t.outcome, t.output.written());
        const revision = t.current.revision.get() + @as(u64, if (t.matches.count > 0) 1 else 0);
        t.answer = .{ .accepted = !refused, .revision = revision };
        if (refused) try t.answer.code.set("invalid_arguments");
        // The call's binding uniquely identifies its saved arguments, even on retry.
        t.digest = content_string.digest(t.key);
        const found = &t.facts.?;
        if (t.matches.count > 0) {
            t.later = .{ .saved = .{ .names = &t.matches.names } };
            t.later.saved.queue(r, t.configured());
            t.outcome_id = outcome_id;
            return .{ .round = .selection };
        }
        try command.queueCommand(r, t.key, .configure, &found.session.ref, &t.digest, null, null, &t.answer);
        return t.resolve(r, outcome_id);
    }

    /// After `.selection`: looks up the loaded set by its digest.
    noinline fn select(t: *FindTools, r: *transition.Round(FindTools)) !transition.Next(FindTools) {
        const selected = try t.later.saved.selection();
        t.later = .{ .selected = selected };
        tool_set.lookupSelection(r, &t.later.selected);
        return .{ .round = .selected };
    }

    /// After `.selected`: saves the loaded set, if new, and the revision
    /// that loads it.
    noinline fn load(t: *FindTools, r: *transition.Round(FindTools)) !transition.Next(FindTools) {
        const found = &t.facts.?;
        const configured_set = t.configured();
        const revision = t.answer.revision;
        const selected_set = try tool_set.finishSelection(r, &t.later.selected, configured_set);
        // Sets are saved once per membership: loading every configured name
        // is the configured set itself, which the Session saves as NULL.
        r.write(update_loaded, .{ .session = found.session, .loaded = if (selected_set == configured_set) null else selected_set, .revision = revision });
        t.later = .{ .applied = .{
            .session = .{},
            .head = found.session,
            .revision = revision,
            .instructions_id = null,
            .output_schema_id = null,
            .instructions_updated = false,
            .changes = .initOne(.loaded_tools),
        } };
        const applied = &t.later.applied;
        try applied.session.set(&found.session.ref);
        try configuration.queueConfiguredCommand(r, applied, t.key, .configure, &t.digest, null, null, &t.answer);
        return t.resolve(r, t.outcome_id);
    }

    fn resolve(t: *FindTools, r: *transition.Round(FindTools), outcome_id: u64) !transition.Next(FindTools) {
        try action.queueResolution(r, t.input.binding, t.facts.?.session, if (t.input.refusal == null) .succeeded else .failed, outcome_id);
        if (r.faults().before_commit) return error.InjectedCommitFailure;
        return .commit;
    }

    pub fn committed(_: *const FindTools) Result {
        return true;
    }
};
