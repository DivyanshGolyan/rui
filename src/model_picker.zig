//! The model picker's list: each model a served sign-in offers, once, with
//! the sign-ins that offer it. The models the Host knows come first, in Rui's
//! catalog's order, then the others by name; the picker shows the default
//! ahead of them all.
const std = @import("std");
const catalog = @import("model_catalog.zig");
const client_defaults = @import("client_defaults.zig");
const product_defaults = @import("product_defaults.zig");
const model_capability = @import("model_capability.zig");
const model_list = @import("model_list.zig");
const provider_name = @import("provider_name.zig");

pub const Provider = provider_name.Provider;
pub const Providers = std.enums.EnumSet(Provider);

pub const Entry = struct {
    id: []const u8,
    /// The Host knows its limits; otherwise it runs with default limits.
    known: bool,
    /// Local catalog membership only orders ties within the Host's groups.
    catalogued: bool,
    /// The served sign-ins whose list holds it; never empty.
    providers: Providers,

    fn lessThan(_: void, a: Entry, b: Entry) bool {
        if (a.known != b.known) return a.known;
        // The catalog is bytewise sorted. Its entries precede unlisted IDs.
        if (a.catalogued != b.catalogued) return a.catalogued;
        return std.mem.order(u8, a.id, b.id) == .lt;
    }

    fn idLessThan(_: void, a: Entry, b: Entry) bool {
        return std.mem.order(u8, a.id, b.id) == .lt;
    }
};

/// What the Host said of each sign-in's list; null for one it does not serve.
pub const Sources = std.enums.EnumArray(Provider, ?model_list.Source);

/// Owns its entries and their IDs; `deinit` frees both. `read` fixes the
/// order, and nothing changes it after.
pub const Menu = struct {
    entries: []const Entry = &.{},
    /// Every entry's ID, back to back.
    ids: []u8 = &.{},
    sources: Sources = .initFill(null),
    /// The first entry the Host does not know.
    others: usize = 0,
    /// The longest ID's bytes, which are its cells: IDs are printable ASCII.
    widest: usize = 0,

    pub fn deinit(self: *Menu, gpa: std.mem.Allocator) void {
        gpa.free(self.entries);
        gpa.free(self.ids);
        self.* = .{};
    }

    pub fn find(self: *const Menu, id: []const u8) ?usize {
        for (self.entries, 0..) |entry, at| if (std.mem.eql(u8, entry.id, id)) return at;
        return null;
    }

    /// Some served list is still being fetched: ask again later.
    pub fn loading(self: *const Menu) bool {
        for (self.sources.values) |source| if (source == .pending) return true;
        return false;
    }

    /// The menu as the picker shows it, with `default` first.
    pub fn shown(self: *const Menu, default: ?[]const u8) Shown {
        return .{ .menu = self, .lead = if (default) |id| self.find(id) else null };
    }
};

/// A menu's rows with its default's entry, `lead`, first and the rest in
/// the menu's order.
pub const Shown = struct {
    menu: *const Menu,
    lead: ?usize,

    pub fn entry(self: Shown, at_row: usize) Entry {
        const lead = self.lead orelse return self.menu.entries[at_row];
        if (at_row == 0) return self.menu.entries[lead];
        return self.menu.entries[if (at_row <= lead) at_row - 1 else at_row];
    }

    /// The row of the menu's entry `at`.
    pub fn row(self: Shown, at: usize) usize {
        const lead = self.lead orelse return at;
        return if (at == lead) 0 else if (at < lead) at + 1 else at;
    }

    /// The row "Other models" starts at.
    pub fn others(self: Shown) usize {
        const lead = self.lead orelse return self.menu.others;
        return self.menu.others + @intFromBool(lead >= self.menu.others);
    }
};

pub const ReasoningEffort = model_capability.ReasoningEffort;

/// What new Sessions use now: the model, and the sign-in and effort saved
/// for them; null where none is.
pub const Defaults = struct {
    model: ?[]const u8 = null,
    provider: ?Provider = null,
    effort: ?ReasoningEffort = null,
};

pub const Side = enum { lower, higher };

/// A row as the picker shows it: what Enter on it saves for new Sessions,
/// and the choices its model leaves. Moving to another row starts from
/// that row's own.
pub const Row = struct {
    /// Null for a model that takes no effort.
    effort: ?ReasoningEffort,
    provider: Provider,
    /// The efforts the model offers: its catalog row's, or every one Rui
    /// knows for a model the catalog does not list, as a start admits.
    efforts: catalog.Efforts,
    providers: Providers,
    /// New Sessions use this model now: the row's ✓.
    current: bool,

    /// The next effort on `side` the model offers; at the end, or with one
    /// effort or none, the same.
    pub fn stepEffort(self: Row, side: Side) Row {
        const now = self.effort orelse return self;
        const order = std.enums.values(ReasoningEffort);
        var at = std.mem.indexOfScalar(ReasoningEffort, order, now).?;
        while (true) {
            switch (side) {
                .lower => at = std.math.sub(usize, at, 1) catch return self,
                .higher => {
                    at += 1;
                    if (at == order.len) return self;
                },
            }
            if (self.efforts.contains(order[at])) {
                var next = self;
                next.effort = order[at];
                return next;
            }
        }
    }

    /// The next sign-in the row offers, round to the first; with one, the
    /// same.
    pub fn nextSignIn(self: Row) Row {
        const order = std.enums.values(Provider);
        var at = std.mem.indexOfScalar(Provider, order, self.provider).?;
        while (true) {
            at = (at + 1) % order.len;
            if (self.providers.contains(order[at])) {
                var next = self;
                next.provider = order[at];
                return next;
            }
        }
    }
};

/// The words typed after `/model`. Each word keeps the rows whose ID holds
/// it, or that offer an effort or sign-in its name begins with; a word that
/// names one whole sets it on each row that offers it, the last such word
/// winning. So `/model terra low api` leaves one row, set to save as typed.
/// Both ways into ChatGPT read "ChatGPT", so a word keeps a row that offers
/// either: `chatgpt` and `codex` keep a ChatGPT sign-in's rows.
pub const Query = struct {
    words: []const u8,
    effort: ?ReasoningEffort = null,
    provider: ?Provider = null,

    pub fn parse(words: []const u8) Query {
        var query: Query = .{ .words = words };
        var each = std.mem.tokenizeScalar(u8, words, ' ');
        while (each.next()) |word| {
            for (std.enums.values(ReasoningEffort)) |effort| {
                if (std.ascii.eqlIgnoreCase(@tagName(effort), word)) query.effort = effort;
            }
            for (std.enums.values(Provider)) |provider| {
                for (signInWords(provider)) |name| {
                    if (std.ascii.eqlIgnoreCase(name, word)) query.provider = provider;
                }
            }
        }
        return query;
    }

    /// The row of `entry`, or null for non-chat or non-matching models. Its effort
    /// and sign-in are the typed ones where the model offers them, else the
    /// saved ones where it offers those, else the model's own: the product's
    /// sign-in where it offers both, the effort a start applies.
    pub fn row(self: Query, entry: Entry, defaults: Defaults) ?Row {
        if (!catalog.canChat(entry.id)) return null;
        return self.match(entry, defaults);
    }

    /// An explicitly typed, unlisted choice bypasses list admission. Its ID
    /// and controls go to the provider rather than pretending it is listed.
    pub fn typed(self: Query, entry: Entry, defaults: Defaults) Row {
        return (Query{ .words = "", .effort = self.effort, .provider = self.provider }).match(entry, defaults).?;
    }

    fn match(self: Query, entry: Entry, defaults: Defaults) ?Row {
        var efforts: catalog.Efforts = .empty;
        for (std.enums.values(ReasoningEffort)) |effort| {
            if (model_capability.supportsReasoningEffort(catalog.shipped, entry.id, effort)) efforts.insert(effort);
        }
        var each = std.mem.tokenizeScalar(u8, self.words, ' ');
        while (each.next()) |word| {
            if (std.ascii.findIgnoreCase(entry.id, word) != null) continue;
            if (beginsOne(word, efforts, entry.providers)) continue;
            return null;
        }
        const product_provider = comptime std.meta.stringToEnum(Provider, product_defaults.provider).?;
        // An entry's providers are never empty.
        const provider = for ([_]?Provider{ self.provider, defaults.provider, product_provider }) |wanted| {
            if (wanted) |one| if (entry.providers.contains(one)) break one;
        } else for (std.enums.values(Provider)) |one| {
            if (entry.providers.contains(one)) break one;
        } else unreachable;
        return .{
            .effort = model_capability.startEffort(catalog.shipped, self.effort, entry.id) orelse client_defaults.startEffort(entry.id, defaults.effort),
            .provider = provider,
            .efforts = efforts,
            .providers = entry.providers,
            .current = if (defaults.model) |model| std.mem.eql(u8, model, entry.id) else false,
        };
    }

    /// `word` begins the name of one of `efforts`, of `providers`, or of
    /// the other way into a provider's account.
    fn beginsOne(word: []const u8, efforts: catalog.Efforts, providers: Providers) bool {
        var efforts_offered = efforts.iterator();
        while (efforts_offered.next()) |effort| if (std.ascii.startsWithIgnoreCase(@tagName(effort), word)) return true;
        var providers_offered = providers.iterator();
        while (providers_offered.next()) |provider| {
            for ([_]?Provider{ provider, provider.sameAccount() }) |one| {
                const named = one orelse continue;
                for (signInWords(named)) |name| if (std.ascii.startsWithIgnoreCase(name, word)) return true;
            }
        }
        return false;
    }
};

/// The words a sign-in is typed as: its label's first (`chatgpt`, `api`),
/// and, for a way into an account with two, its route name (`codex`,
/// `chatgpt`), as `--provider` takes it. `openai` stays a word of model IDs,
/// as live lists name models `openai/…`.
fn signInWords(provider: Provider) [2][]const u8 {
    const label = provider.signIn();
    const first = label[0 .. std.mem.indexOfScalar(u8, label, ' ') orelse label.len];
    return .{ first, if (provider.sameAccount() != null) @tagName(provider) else first };
}

/// The menu of a `model_list` reply's `providers` array, owned by `gpa`. A
/// reply Rui cannot read is error.InvalidModelList.
pub fn read(gpa: std.mem.Allocator, providers: []const u8) error{ OutOfMemory, InvalidModelList }!Menu {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const temporary = scratch.allocator();
    var scanner: std.json.Scanner = .initCompleteInput(temporary, providers);
    var menu: Menu = .{};
    // Every offered model, before merging. Each has an `"id":` member, and
    // an ID's own quotes are escaped, so this count bounds them.
    const offered = try temporary.alloc(Entry, std.mem.count(u8, providers, "\"id\":"));
    var count: usize = 0;
    if (try nextToken(&scanner, temporary) != .array_begin) return error.InvalidModelList;
    while (true) {
        switch (try nextToken(&scanner, temporary)) {
            .array_end => break,
            .object_begin => {},
            else => return error.InvalidModelList,
        }
        var provider: ?Provider = null;
        var source: ?model_list.Source = null;
        var models: ?[2]usize = null;
        while (try objectKey(&scanner, temporary)) |key| {
            if (std.mem.eql(u8, key, "provider")) {
                provider = std.meta.stringToEnum(Provider, try string(&scanner, temporary)) orelse return error.InvalidModelList;
            } else if (std.mem.eql(u8, key, "source")) {
                source = std.meta.stringToEnum(model_list.Source, try string(&scanner, temporary)) orelse return error.InvalidModelList;
            } else if (std.mem.eql(u8, key, "models")) {
                const start = count;
                if (try nextToken(&scanner, temporary) != .array_begin) return error.InvalidModelList;
                while (true) {
                    switch (try nextToken(&scanner, temporary)) {
                        .array_end => break,
                        .object_begin => {},
                        else => return error.InvalidModelList,
                    }
                    var id: ?[]const u8 = null;
                    var known: ?bool = null;
                    while (try objectKey(&scanner, temporary)) |member| {
                        if (std.mem.eql(u8, member, "id")) {
                            // Unescaped, it borrows `providers`; escaped, the scratch.
                            id = try string(&scanner, temporary);
                        } else if (std.mem.eql(u8, member, "known")) {
                            known = switch (try nextToken(&scanner, temporary)) {
                                .true => true,
                                .false => false,
                                else => return error.InvalidModelList,
                            };
                        } else return error.InvalidModelList;
                    }
                    const model = id orelse return error.InvalidModelList;
                    if (!model_capability.validModelSyntax(model)) return error.InvalidModelList;
                    if (count == offered.len) return error.InvalidModelList;
                    offered[count] = .{ .id = model, .known = known orelse return error.InvalidModelList, .catalogued = model_capability.supportsModel(catalog.shipped, model), .providers = .empty };
                    count += 1;
                }
                models = .{ start, count };
            } else return error.InvalidModelList;
        }
        const served = provider orelse return error.InvalidModelList;
        const span = models orelse return error.InvalidModelList;
        if (menu.sources.get(served) != null) return error.InvalidModelList;
        menu.sources.set(served, source orelse return error.InvalidModelList);
        for (offered[span[0]..span[1]]) |*entry| entry.providers = .initOne(served);
    }
    if (try nextToken(&scanner, temporary) != .end_of_document) return error.InvalidModelList;
    // One entry per ID, in place, known if any sign-in's list knows it.
    std.mem.sort(Entry, offered[0..count], {}, Entry.idLessThan);
    var len: usize = 0;
    var id_bytes: usize = 0;
    for (offered[0..count]) |entry| {
        if (len != 0 and std.mem.eql(u8, offered[len - 1].id, entry.id)) {
            offered[len - 1].providers.setUnion(entry.providers);
            offered[len - 1].known = offered[len - 1].known or entry.known;
            continue;
        }
        offered[len] = entry;
        id_bytes += entry.id.len;
        len += 1;
    }
    std.mem.sort(Entry, offered[0..len], {}, Entry.lessThan);
    const entries = try gpa.alloc(Entry, len);
    errdefer gpa.free(entries);
    menu.ids = try gpa.alloc(u8, id_bytes);
    var at: usize = 0;
    menu.others = len;
    for (offered[0..len], entries, 0..) |entry, *kept, place| {
        @memcpy(menu.ids[at..][0..entry.id.len], entry.id);
        kept.* = entry;
        kept.id = menu.ids[at..][0..entry.id.len];
        at += entry.id.len;
        menu.widest = @max(menu.widest, entry.id.len);
        if (!entry.known and menu.others == len) menu.others = place;
    }
    menu.entries = entries;
    return menu;
}

fn nextToken(scanner: *std.json.Scanner, scratch: std.mem.Allocator) error{ OutOfMemory, InvalidModelList }!std.json.Token {
    return scanner.nextAlloc(scratch, .alloc_if_needed) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidModelList,
    };
}

fn string(scanner: *std.json.Scanner, scratch: std.mem.Allocator) error{ OutOfMemory, InvalidModelList }![]const u8 {
    return switch (try nextToken(scanner, scratch)) {
        .string, .allocated_string => |text| text,
        else => error.InvalidModelList,
    };
}

/// The next member's key, or null at the object's end.
fn objectKey(scanner: *std.json.Scanner, scratch: std.mem.Allocator) error{ OutOfMemory, InvalidModelList }!?[]const u8 {
    return switch (try nextToken(scanner, scratch)) {
        .object_end => null,
        .string, .allocated_string => |key| key,
        else => error.InvalidModelList,
    };
}

/// The menu of `lists` as the Host writes them, owned by the testing
/// allocator.
pub fn testMenu(lists: []const model_list.Entry) !Menu {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try model_list.writeProviders(&bytes.writer, catalog.shipped, lists);
    return read(std.testing.allocator, bytes.written());
}

fn expectOrder(shown: Shown, ids: []const []const u8) !void {
    try std.testing.expectEqual(ids.len, shown.menu.entries.len);
    for (ids, 0..) |id, row| {
        try std.testing.expectEqualStrings(id, shown.entry(row).id);
        try std.testing.expectEqual(row, shown.row(shown.menu.find(id).?));
    }
}

test "the default leads, known models follow in catalog order, then the others by name, each once with every sign-in that offers it" {
    var menu = try testMenu(&.{
        .{ .provider = .codex, .list = .catalog },
        .{ .provider = .openai, .list = .{ .live = .{ .bytes = "zz-unlisted\ngpt-6-luna\naa-unlisted\ngpt-5.5\n" } } },
    });
    defer menu.deinit(std.testing.allocator);
    var expected: [catalog.openai_ids.len + 2][]const u8 = undefined;
    expected[0] = "gpt-6-sol";
    var at: usize = 1;
    for (catalog.openai_ids) |id| if (!std.mem.eql(u8, id, "gpt-6-sol")) {
        expected[at] = id;
        at += 1;
    };
    expected[at..][0..2].* = .{ "aa-unlisted", "zz-unlisted" };
    try expectOrder(menu.shown("gpt-6-sol"), &expected);
    for (menu.entries) |entry| {
        const both = std.mem.eql(u8, entry.id, "gpt-6-luna") or std.mem.eql(u8, entry.id, "gpt-5.5");
        const live_only = std.mem.eql(u8, entry.id, "aa-unlisted") or std.mem.eql(u8, entry.id, "zz-unlisted");
        try std.testing.expectEqual(!live_only, entry.providers.contains(.codex));
        try std.testing.expectEqual(both or live_only, entry.providers.contains(.openai));
        try std.testing.expectEqual(!live_only, entry.known);
    }
    try std.testing.expectEqual(catalog.openai_ids.len, menu.shown("gpt-6-sol").others());
    var widest: usize = "zz-unlisted".len;
    for (catalog.openai_ids) |id| widest = @max(widest, id.len);
    try std.testing.expectEqual(widest, menu.widest);
    try std.testing.expectEqual(@as(?model_list.Source, .live), menu.sources.get(.openai));
    try std.testing.expect(!menu.loading());
    // Another default leads, and the first one is back in its row.
    expected[0] = "gpt-5.5";
    at = 1;
    for (catalog.openai_ids) |id| if (!std.mem.eql(u8, id, "gpt-5.5")) {
        expected[at] = id;
        at += 1;
    };
    try expectOrder(menu.shown("gpt-5.5"), &expected);
    // An unlisted default leads, and "Other models" starts at the rest.
    const unlisted_first = menu.shown("zz-unlisted");
    try std.testing.expectEqualStrings("zz-unlisted", unlisted_first.entry(0).id);
    try std.testing.expectEqual(catalog.openai_ids.len + 1, unlisted_first.others());
    try std.testing.expectEqualStrings("aa-unlisted", unlisted_first.entry(unlisted_first.others()).id);
    for ([_]?[]const u8{ null, "o9" }) |absent| {
        const plain = menu.shown(absent);
        try std.testing.expectEqualStrings(catalog.openai_ids[0], plain.entry(0).id);
        try std.testing.expectEqualStrings("zz-unlisted", plain.entry(menu.entries.len - 1).id);
    }
}

test "the Host's word decides which models are known; Rui's catalog only orders them" {
    var menu = try read(std.testing.allocator, "[{\"provider\":\"openai\",\"source\":\"live\",\"models\":[" ++
        "{\"id\":\"o9\",\"known\":false},{\"id\":\"gpt-6-luna\",\"known\":false},{\"id\":\"zz-next\",\"known\":true},{\"id\":\"gpt-5.5\",\"known\":true}]}]");
    defer menu.deinit(std.testing.allocator);
    try expectOrder(menu.shown(null), &.{ "gpt-5.5", "zz-next", "gpt-6-luna", "o9" });
    try std.testing.expectEqual(@as(usize, 2), menu.others);
    try std.testing.expect(menu.entries[1].known and !menu.entries[2].known);
}

test "a sign-in the Host does not serve has no source, and a pending list asks again" {
    var menu = try testMenu(&.{.{ .provider = .openai, .list = .pending }});
    defer menu.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?model_list.Source, null), menu.sources.get(.codex));
    try std.testing.expect(menu.loading());
    try std.testing.expectEqualStrings(catalog.openai_ids[0], menu.entries[0].id);
    try std.testing.expect(menu.find("gpt-6.1-sol") != null);
    try std.testing.expectEqual(menu.entries.len, menu.others);
    var nothing = try testMenu(&.{});
    defer nothing.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), nothing.entries.len);
}

test "a reply Rui cannot read is refused whole" {
    for ([_][]const u8{
        "",
        "{}",
        "[{\"provider\":\"codex\",\"source\":\"table\",\"models\":[]}]",
        "[{\"provider\":\"openai\",\"source\":\"table_fallback\",\"models\":[]}]",
        "[{\"provider\":\"claude\",\"source\":\"catalog\",\"models\":[]}]",
        "[{\"provider\":\"openai\",\"source\":\"live\",\"models\":[{\"id\":\"a b\",\"known\":false}]}]",
        "[{\"provider\":\"openai\",\"source\":\"live\",\"models\":[{\"id\":\"gpt-6-luna\"}]}]",
        "[{\"provider\":\"openai\",\"source\":\"live\"}]",
        "[{\"provider\":\"openai\",\"source\":\"live\",\"models\":[]},{\"provider\":\"openai\",\"source\":\"catalog\",\"models\":[]}]",
        "[] []",
    }) |reply| try std.testing.expectError(error.InvalidModelList, read(std.testing.allocator, reply));
}

/// ChatGPT's catalog list, and an API key's list: two known models, a dated
/// and a fine-tuned one Rui does not list, and five Rui's catalog lists with
/// a gap in their efforts, one effort or none, two with an effort's name.
fn pickerMenu() !Menu {
    return testMenu(&.{
        .{ .provider = .codex, .list = .catalog },
        .{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-6.1-terra\ngpt-6.1-sol\ngpt-6.1-sol-2026-10-14\nft:custom\n" ++
            "@cf/deepseek-ai/deepseek-v4-flash-0731\nazure/gpt-5-pro\nopenai/gpt-4.1\nalibaba/qwen-max\nauto/mistralai/mistral-medium-3.5\n" } } },
    });
}

fn entryOf(menu: *const Menu, id: []const u8) Entry {
    return menu.entries[menu.find(id).?];
}

/// The row of `id` with nothing typed after `/model`.
fn plainRow(menu: *const Menu, id: []const u8, defaults: Defaults) Row {
    return Query.parse("").row(entryOf(menu, id), defaults).?;
}

test "a row would save the saved effort and sign-in where its model offers them, else the model's own" {
    var menu = try pickerMenu();
    defer menu.deinit(std.testing.allocator);
    const Case = struct { id: []const u8, effort: ?ReasoningEffort, provider: Provider };
    // Saved: the API key at effort none, which gpt-6.1-sol does not offer.
    const saved: Defaults = .{ .model = "gpt-6.1-sol", .provider = .openai, .effort = .none };
    for ([_]Case{
        .{ .id = "gpt-6.1-terra", .effort = .none, .provider = .openai },
        // The product's low, not the saved none, and not the model's lowest.
        .{ .id = "gpt-6.1-sol", .effort = .low, .provider = .openai },
        // Only ChatGPT offers it, so not the saved API key.
        .{ .id = "gpt-6-astra", .effort = .low, .provider = .codex },
        // It offers neither none nor low: its lowest.
        .{ .id = "gpt-5.5-pro", .effort = .medium, .provider = .codex },
        // Rui's catalog does not list it, so the provider decides.
        .{ .id = "ft:custom", .effort = .none, .provider = .openai },
        .{ .id = "azure/gpt-5-pro", .effort = .high, .provider = .openai },
        .{ .id = "openai/gpt-4.1", .effort = null, .provider = .openai },
    }) |case| {
        const row = plainRow(&menu, case.id, saved);
        try std.testing.expectEqual(case.effort, row.effort);
        try std.testing.expectEqual(case.provider, row.provider);
    }
    // Nothing saved: the product's sign-in where the row offers both, and
    // its effort where the model offers it.
    for ([_]Case{
        .{ .id = "gpt-6.1-sol", .effort = .low, .provider = .codex },
        .{ .id = "gpt-5.5-pro", .effort = .medium, .provider = .codex },
        .{ .id = "ft:custom", .effort = .low, .provider = .openai },
        .{ .id = "azure/gpt-5-pro", .effort = .high, .provider = .openai },
    }) |case| {
        const row = plainRow(&menu, case.id, .{});
        try std.testing.expectEqual(case.effort, row.effort);
        try std.testing.expectEqual(case.provider, row.provider);
    }
    // Saved effort high reaches every row that offers it.
    try std.testing.expectEqual(@as(?ReasoningEffort, .high), plainRow(&menu, "gpt-5.5-pro", .{ .effort = .high }).effort);
    try std.testing.expectEqual(@as(?ReasoningEffort, .high), plainRow(&menu, "gpt-6.1-sol", .{ .effort = .high }).effort);
}

test "the ✓ marks the row of the model new Sessions use, whatever its sign-in" {
    var menu = try pickerMenu();
    defer menu.deinit(std.testing.allocator);
    var marked: usize = 0;
    for (menu.entries) |entry| {
        const row = Query.parse("").row(entry, .{ .model = "gpt-6.1-sol", .provider = .codex }) orelse continue;
        try std.testing.expectEqual(std.mem.eql(u8, entry.id, "gpt-6.1-sol"), row.current);
        marked += @intFromBool(row.current);
        try std.testing.expect(!Query.parse("").row(entry, .{ .provider = .codex, .effort = .high }).?.current);
    }
    try std.testing.expectEqual(@as(usize, 1), marked);
}

test "left and right step the effort through those the model offers and stop at either end" {
    var menu = try pickerMenu();
    defer menu.deinit(std.testing.allocator);
    const Case = struct { id: []const u8, side: Side, steps: []const ?ReasoningEffort };
    const saved: Defaults = .{ .provider = .codex, .effort = .high };
    for ([_]Case{
        .{ .id = "gpt-6.1-sol", .side = .higher, .steps = &.{ .high, .xhigh, .max, .max } },
        // gpt-6.1-sol offers no none.
        .{ .id = "gpt-6.1-sol", .side = .lower, .steps = &.{ .high, .medium, .low, .low } },
        // This one offers none, low, high and max: medium is skipped.
        .{ .id = "@cf/deepseek-ai/deepseek-v4-flash-0731", .side = .lower, .steps = &.{ .high, .low, .none, .none } },
        .{ .id = "@cf/deepseek-ai/deepseek-v4-flash-0731", .side = .higher, .steps = &.{ .high, .max, .max } },
        // Unlisted: every effort Rui knows.
        .{ .id = "ft:custom", .side = .lower, .steps = &.{ .high, .medium, .low, .none, .none } },
        .{ .id = "ft:custom", .side = .higher, .steps = &.{ .high, .xhigh, .max, .max } },
        // One effort, or none: the keys do nothing.
        .{ .id = "azure/gpt-5-pro", .side = .lower, .steps = &.{ .high, .high } },
        .{ .id = "azure/gpt-5-pro", .side = .higher, .steps = &.{ .high, .high } },
        .{ .id = "openai/gpt-4.1", .side = .lower, .steps = &.{ null, null } },
        .{ .id = "openai/gpt-4.1", .side = .higher, .steps = &.{ null, null } },
    }) |case| {
        var row = plainRow(&menu, case.id, saved);
        for (case.steps) |expected| {
            try std.testing.expectEqual(expected, row.effort);
            row = row.stepEffort(case.side);
        }
        // Stepping never changes the sign-in.
        try std.testing.expectEqual(plainRow(&menu, case.id, saved).provider, row.provider);
    }
    try std.testing.expectEqual(@as(usize, 5), plainRow(&menu, "gpt-6.1-sol", saved).efforts.count());
    try std.testing.expectEqual(@as(usize, 6), plainRow(&menu, "ft:custom", saved).efforts.count());
    try std.testing.expectEqual(@as(usize, 1), plainRow(&menu, "azure/gpt-5-pro", saved).efforts.count());
    try std.testing.expectEqual(@as(usize, 0), plainRow(&menu, "openai/gpt-4.1", saved).efforts.count());
}

test "tab switches between the sign-ins the row offers, and does nothing with one" {
    var menu = try pickerMenu();
    defer menu.deinit(std.testing.allocator);
    const both = plainRow(&menu, "gpt-6.1-sol", .{ .provider = .codex, .effort = .high });
    try std.testing.expectEqual(Provider.codex, both.provider);
    try std.testing.expectEqual(Provider.openai, both.nextSignIn().provider);
    try std.testing.expectEqual(Provider.codex, both.nextSignIn().nextSignIn().provider);
    // Switching never changes the effort.
    try std.testing.expectEqual(@as(?ReasoningEffort, .high), both.nextSignIn().effort);
    for ([_][]const u8{ "gpt-6-astra", "ft:custom" }) |id| {
        const one = plainRow(&menu, id, .{ .provider = .openai });
        try std.testing.expectEqual(one.provider, one.nextSignIn().provider);
        try std.testing.expectEqual(@as(usize, 1), one.providers.count());
    }
}

/// The IDs of the rows `typed` leaves, in the menu's order.
fn expectRows(menu: *const Menu, typed: []const u8, ids: []const []const u8) !void {
    const query = Query.parse(typed);
    var at: usize = 0;
    for (menu.entries) |entry| if (query.row(entry, .{}) != null) {
        try std.testing.expect(at < ids.len);
        try std.testing.expectEqualStrings(ids[at], entry.id);
        at += 1;
    };
    try std.testing.expectEqual(ids.len, at);
}

test "/model terra low api leaves one row, set to low on the API key, whatever was saved" {
    var menu = try pickerMenu();
    defer menu.deinit(std.testing.allocator);
    const saved: Defaults = .{ .model = "gpt-6.1-sol", .provider = .codex, .effort = .high };
    // Word order and case do not matter, and extra spaces are no words.
    for ([_][]const u8{ "terra low api", "api low terra", "  TERRA  Low API ", "terra high low api codex api" }) |typed| {
        try expectRows(&menu, typed, &.{"gpt-6.1-terra"});
        const row = Query.parse(typed).row(entryOf(&menu, "gpt-6.1-terra"), saved).?;
        try std.testing.expectEqual(@as(?ReasoningEffort, .low), row.effort);
        try std.testing.expectEqual(Provider.openai, row.provider);
        try std.testing.expect(!row.current);
    }
    // Without the sign-in, ChatGPT's gpt-5.6-terra stays too.
    try expectRows(&menu, "terra low", &.{ "gpt-5.6-terra", "gpt-6.1-terra" });
    try expectRows(&menu, "terra codex", &.{ "gpt-5.6-terra", "gpt-6.1-terra" });
    const codex = Query.parse("terra codex").row(entryOf(&menu, "gpt-6.1-terra"), .{ .provider = .openai, .effort = .medium }).?;
    try std.testing.expectEqual(Provider.codex, codex.provider);
    try std.testing.expectEqual(@as(?ReasoningEffort, .medium), codex.effort);
}

test "a word narrows to the rows whose ID holds it or that offer the effort or sign-in it begins" {
    var menu = try pickerMenu();
    defer menu.deinit(std.testing.allocator);
    // Typing towards low or api keeps the row, which keeps its own effort
    // and sign-in until the word is whole.
    for ([_][]const u8{ "6.1-terra l", "6.1-terra lo", "6.1-terra ap", "6.1-terra AP" }) |typed| {
        try expectRows(&menu, typed, &.{"gpt-6.1-terra"});
        const row = Query.parse(typed).row(entryOf(&menu, "gpt-6.1-terra"), .{ .provider = .codex, .effort = .high }).?;
        try std.testing.expectEqual(@as(?ReasoningEffort, .high), row.effort);
        try std.testing.expectEqual(Provider.codex, row.provider);
    }
    // gpt-6.1-sol offers no none, but the dated one Rui does not list may;
    // gpt-6-astra offers no API key.
    try expectRows(&menu, "6.1-sol none", &.{"gpt-6.1-sol-2026-10-14"});
    try expectRows(&menu, "astra api", &.{});
    try expectRows(&menu, "6.1-terra q", &.{});
    // An ID that holds an effort's name stays though its model offers no
    // effort, and the row then saves none.
    try expectRows(&menu, "qwen max", &.{"alibaba/qwen-max"});
    try std.testing.expectEqual(@as(?ReasoningEffort, null), Query.parse("qwen max").row(entryOf(&menu, "alibaba/qwen-max"), .{ .effort = .low }).?.effort);
    // An effort its model lacks leaves the row at the saved one, where the
    // model offers that, else at the model's own.
    try expectRows(&menu, "mistral medium", &.{"auto/mistralai/mistral-medium-3.5"});
    const mistral = entryOf(&menu, "auto/mistralai/mistral-medium-3.5");
    try std.testing.expectEqual(@as(?ReasoningEffort, .high), Query.parse("mistral medium").row(mistral, .{ .effort = .high }).?.effort);
    try std.testing.expectEqual(@as(?ReasoningEffort, .none), Query.parse("mistral medium").row(mistral, .{ .effort = .xhigh }).?.effort);
    // Every chat row stays with nothing typed.
    var all: usize = 0;
    for (menu.entries) |entry| all += @intFromBool(Query.parse(" ").row(entry, .{}) != null);
    var chat_count: usize = 0;
    for (menu.entries) |entry| if (catalog.canChat(entry.id)) {
        chat_count += 1;
    };
    try std.testing.expectEqual(chat_count, all);
}

test "model picker domain admits chat and unknown live IDs but not catalog-proven non-chat families" {
    var menu = try testMenu(&.{.{ .provider = .openai, .list = .{ .live = .{
        .bytes = "gpt-6.1-sol\ngpt-4.1\nfuture-chat\ngpt-imagery-next\n" ++
            "gpt-image-2\ngpt-image-1-mini\ntext-embedding-3-large\ngpt-realtime-2.1\n" ++
            "openai/whisper-1\ngpt-image-next\ntext-embedding-next\ngpt-realtime-next\n",
    } } }});
    defer menu.deinit(std.testing.allocator);
    try expectRows(&menu, "", &.{ "gpt-4.1", "gpt-6.1-sol", "future-chat", "gpt-imagery-next" });
    try std.testing.expect(!entryOf(&menu, "future-chat").known);

    // Exercise every shipped ID through live-list ingestion and row admission.
    // The independent exclusion projection is generated from the source's
    // type/modalities, not from canChat or the picker's filtering result.
    const facts = @import("model_catalog_snapshot.zig");
    var body: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer body.deinit();
    for (catalog.shipped) |entry| try body.writer.print("{s}\n", .{entry.id});
    var whole = try testMenu(&.{.{ .provider = .openai, .list = .{ .live = .{ .bytes = body.written() } } }});
    defer whole.deinit(std.testing.allocator);
    var offered_chat: usize = 0;
    for (whole.entries) |entry| {
        try std.testing.expect(entry.known);
        offered_chat += @intFromBool(Query.parse("").row(entry, .{}) != null);
    }
    try std.testing.expectEqual(catalog.shipped.len - facts.non_chat_ids.len, offered_chat);
    for (facts.non_chat_ids) |id| try std.testing.expect(Query.parse("").row(entryOf(&whole, id), .{}) == null);
}
