//! Static image container validation. This checks framing and metadata, not
//! whether a pixel decoder can decode the compressed entropy stream.
const std = @import("std");

pub const Format = enum(u8) {
    png = 1,
    jpeg = 2,

    pub fn mime(self: Format) []const u8 {
        return switch (self) {
            .png => "image/png",
            .jpeg => "image/jpeg",
        };
    }
};

pub const Metadata = struct {
    format: Format,
    width: u32,
    height: u32,
};

pub const Limits = struct {
    max_bytes: u64 = 384_000_000,
    max_dimension: u32 = std.math.maxInt(u32),
};

pub const Error = error{ UnsupportedImage, MalformedImage, TruncatedImage, ImageMimeMismatch, ImageResourceLimit };

/// One image's resumable scanner. Its memory does not depend on image size,
/// dimensions, chunk lengths or the number of images in an input.
pub const Scanner = struct {
    length: u64,
    assertion: ?Format,
    limits: Limits,
    position: u64 = 0,
    metadata: ?Metadata = null,
    state: union(enum) {
        signature: struct { bytes: [8]u8 = undefined, len: u4 = 0 },
        png: Png,
        jpeg: Jpeg,
    } = .{ .signature = .{} },

    pub fn init(length: u64, assertion: ?Format, limits: Limits) Error!Scanner {
        if (length > limits.max_bytes or length > @import("content_string.zig").max_bytes) return error.ImageResourceLimit;
        if (length < 2) return error.TruncatedImage;
        return .{ .length = length, .assertion = assertion, .limits = limits };
    }

    /// Consumes no more than `allowance` bytes. Cancellation belongs to the
    /// request owner, which can stop between these bounded calls.
    pub fn advance(self: *Scanner, bytes: []const u8, allowance: *usize) Error!usize {
        const count = @min(bytes.len, allowance.*);
        if (count > self.length - self.position) return error.MalformedImage;
        for (bytes[0..count]) |byte| {
            self.position += 1;
            switch (self.state) {
                .signature => |*signature| {
                    signature.bytes[signature.len] = byte;
                    signature.len += 1;
                    if (signature.len == 2 and std.mem.eql(u8, signature.bytes[0..2], "\xff\xd8")) {
                        try self.checkFormat(.jpeg);
                        self.state = .{ .jpeg = .{} };
                    } else if (signature.len == 8) {
                        if (!std.mem.eql(u8, &signature.bytes, "\x89PNG\r\n\x1a\n")) return error.UnsupportedImage;
                        try self.checkFormat(.png);
                        self.state = .{ .png = .{} };
                    }
                },
                .png => |*png| if (try png.feed(byte)) |image_dimensions| {
                    try self.dimensions(.png, image_dimensions[0], image_dimensions[1]);
                },
                .jpeg => |*jpeg| if (try jpeg.feed(byte)) |image_dimensions| {
                    try self.dimensions(.jpeg, image_dimensions[0], image_dimensions[1]);
                },
            }
        }
        allowance.* -= count;
        return count;
    }

    fn checkFormat(self: *const Scanner, actual: Format) Error!void {
        if (self.assertion) |asserted| if (actual != asserted) return error.ImageMimeMismatch;
    }

    fn dimensions(self: *Scanner, format: Format, width: u32, height: u32) Error!void {
        if (width == 0 or height == 0) return error.MalformedImage;
        if (width > self.limits.max_dimension or height > self.limits.max_dimension) return error.ImageResourceLimit;
        _ = std.math.mul(u64, width, height) catch return error.ImageResourceLimit;
        self.metadata = .{ .format = format, .width = width, .height = height };
    }

    pub fn finish(self: *const Scanner) Error!Metadata {
        if (self.position != self.length) return error.TruncatedImage;
        const complete = switch (self.state) {
            .signature => false,
            .png => |png| png.stage == .done,
            .jpeg => |jpeg| jpeg.stage == .done,
        };
        if (!complete) return error.TruncatedImage;
        return self.metadata orelse error.MalformedImage;
    }
};

const Png = struct {
    stage: enum { header, payload, crc, done } = .header,
    header: [8]u8 = undefined,
    header_len: u4 = 0,
    length: u32 = 0,
    at: u32 = 0,
    prefix: [13]u8 = undefined,
    crc: u32 = 0xffffffff,
    claimed_crc: u32 = 0,
    crc_len: u3 = 0,
    ihdr: bool = false,
    palette: bool = false,
    idat: bool = false,
    idat_ended: bool = false,
    data_bytes: u64 = 0,
    color: u8 = 0,
    depth: u8 = 0,

    fn chunk(self: *const Png, name: *const [4]u8) bool {
        return std.mem.eql(u8, self.header[4..8], name);
    }

    fn feed(self: *Png, byte: u8) Error!?[2]u32 {
        switch (self.stage) {
            .done => return error.MalformedImage,
            .header => {
                self.header[self.header_len] = byte;
                self.header_len += 1;
                if (self.header_len < 8) return null;
                self.length = std.mem.readInt(u32, self.header[0..4], .big);
                if (self.length > std.math.maxInt(i32)) return error.MalformedImage;
                for (self.header[4..8]) |letter| if (!std.ascii.isAlphabetic(letter)) return error.MalformedImage;
                if (!std.ascii.isUpper(self.header[6])) return error.MalformedImage;
                if (!self.ihdr and !self.chunk("IHDR")) return error.MalformedImage;
                if (self.chunk("acTL") or self.chunk("fcTL") or self.chunk("fdAT")) return error.UnsupportedImage;
                if (self.chunk("IHDR")) {
                    if (self.ihdr or self.length != 13) return error.MalformedImage;
                } else if (self.chunk("PLTE")) {
                    if (self.palette or self.idat or self.length == 0 or self.length % 3 != 0 or self.length > 768 or self.color == 0 or self.color == 4) return error.MalformedImage;
                    if (self.color == 3 and self.length / 3 > @as(u32, 1) << @intCast(self.depth)) return error.MalformedImage;
                    self.palette = true;
                } else if (self.chunk("IDAT")) {
                    if (self.idat_ended or (self.color == 3 and !self.palette)) return error.MalformedImage;
                    self.idat = true;
                    self.data_bytes = std.math.add(u64, self.data_bytes, self.length) catch return error.ImageResourceLimit;
                } else if (self.chunk("IEND")) {
                    if (self.length != 0 or !self.idat or self.data_bytes == 0) return error.MalformedImage;
                } else if (std.ascii.isUpper(self.header[4])) return error.UnsupportedImage;
                if (self.idat and !self.chunk("IDAT")) self.idat_ended = true;
                self.crc = 0xffffffff;
                for (self.header[4..8]) |letter| self.crc = crcByte(self.crc, letter);
                self.at = 0;
                self.crc_len = 0;
                self.claimed_crc = 0;
                self.stage = if (self.length == 0) .crc else .payload;
            },
            .payload => {
                if (self.at < self.prefix.len) self.prefix[self.at] = byte;
                self.crc = crcByte(self.crc, byte);
                self.at += 1;
                if (self.at == self.length) self.stage = .crc;
            },
            .crc => {
                self.claimed_crc = (self.claimed_crc << 8) | byte;
                self.crc_len += 1;
                if (self.crc_len < 4) return null;
                if (self.claimed_crc != ~self.crc) return error.MalformedImage;
                if (self.chunk("IEND")) {
                    self.stage = .done;
                    return null;
                }
                self.stage = .header;
                self.header_len = 0;
                if (self.chunk("IHDR")) {
                    self.ihdr = true;
                    self.depth = self.prefix[8];
                    self.color = self.prefix[9];
                    const valid_depth = switch (self.color) {
                        0 => self.depth == 1 or self.depth == 2 or self.depth == 4 or self.depth == 8 or self.depth == 16,
                        2, 4, 6 => self.depth == 8 or self.depth == 16,
                        3 => self.depth == 1 or self.depth == 2 or self.depth == 4 or self.depth == 8,
                        else => false,
                    };
                    if (!valid_depth or self.prefix[10] != 0 or self.prefix[11] != 0 or self.prefix[12] > 1) return error.MalformedImage;
                    const width = std.mem.readInt(u32, self.prefix[0..4], .big);
                    const height = std.mem.readInt(u32, self.prefix[4..8], .big);
                    if (width > std.math.maxInt(i32) or height > std.math.maxInt(i32)) return error.MalformedImage;
                    return .{ width, height };
                }
            },
        }
        return null;
    }
};

fn crcByte(initial: u32, byte: u8) u32 {
    var crc = initial ^ @as(u32, byte);
    for (0..8) |_| crc = if (crc & 1 == 0) crc >> 1 else (crc >> 1) ^ 0xedb88320;
    return crc;
}

const Jpeg = struct {
    stage: enum { marker_start, marker, length_hi, length_lo, payload, entropy, entropy_marker, done } = .marker_start,
    marker: u8 = 0,
    length: u16 = 0,
    at: u16 = 0,
    prefix: [6]u8 = undefined,
    trailer: [3]u8 = undefined,
    frame: bool = false,
    progressive: bool = false,
    components: u8 = 0,
    component_ids: [32]u8 = @splat(0),
    component_quant: [64]u8 = @splat(0),
    scan_ids: [32]u8 = @splat(0),
    covered_ids: [32]u8 = @splat(0),
    scan_data: bool = false,
    next_restart: u3 = 0,
    scan_quant: u8 = 0,
    scan_dc: u8 = 0,
    scan_ac: u8 = 0,
    scans: u32 = 0,
    scan_bytes: u64 = 0,
    restart_interval: u16 = 0,
    table_phase: enum { header, quant, counts, symbols } = .header,
    table_id: u3 = 0,
    table_precision: u1 = 0,
    table_high: u8 = 0,
    table_left: u16 = 0,
    table_symbols: u16 = 0,
    table_slots: u32 = 0,
    symbol_ids: [32]u8 = @splat(0),
    quant_tables: u8 = 0,
    dc_tables: u8 = 0,
    ac_tables: u8 = 0,

    fn has(set: *const [32]u8, id: u8) bool {
        return set[id / 8] & (@as(u8, 1) << @intCast(id % 8)) != 0;
    }

    fn include(set: *[32]u8, id: u8) void {
        set[id / 8] |= @as(u8, 1) << @intCast(id % 8);
    }

    fn startMarker(self: *Jpeg, byte: u8) Error!void {
        if (byte == 0xff) return;
        if (byte == 0xd9) {
            if (!self.frame or self.scans == 0 or self.scan_bytes == 0 or !std.mem.eql(u8, &self.component_ids, &self.covered_ids)) return error.MalformedImage;
            self.stage = .done;
            return;
        }
        if (byte == 0x00 or byte == 0xd8 or byte == 0x01 or (byte >= 0xd0 and byte <= 0xd7)) return error.MalformedImage;
        if (!((byte >= 0xe0 and byte <= 0xef) or byte == 0xfe or byte == 0xc0 or byte == 0xc1 or byte == 0xc2 or byte == 0xc4 or byte == 0xdb or byte == 0xda or byte == 0xdd)) return error.UnsupportedImage;
        self.marker = byte;
        self.stage = .length_hi;
    }

    fn feed(self: *Jpeg, byte: u8) Error!?[2]u32 {
        switch (self.stage) {
            .done => return error.MalformedImage,
            .marker_start => {
                if (byte != 0xff) return error.MalformedImage;
                self.stage = .marker;
            },
            .marker => try self.startMarker(byte),
            .length_hi => {
                self.length = @as(u16, byte) << 8;
                self.stage = .length_lo;
            },
            .length_lo => {
                self.length |= byte;
                if (self.length < 2) return error.MalformedImage;
                self.length -= 2;
                self.at = 0;
                self.table_phase = .header;
                self.scan_ids = @splat(0);
                self.scan_quant = 0;
                self.scan_dc = 0;
                self.scan_ac = 0;
                self.stage = .payload;
                if (self.length == 0) return self.endSegment();
            },
            .payload => {
                if (self.at < self.prefix.len) self.prefix[self.at] = byte;
                if (self.marker == 0xdb or self.marker == 0xc4) try self.tableByte(byte);
                if (self.marker == 0xc0 or self.marker == 0xc1 or self.marker == 0xc2) try self.frameByte(byte);
                if (self.marker == 0xda) try self.scanByte(byte);
                self.at += 1;
                if (self.at == self.length) return self.endSegment();
            },
            .entropy => {
                if (byte == 0xff) {
                    self.stage = .entropy_marker;
                } else {
                    self.scan_bytes += 1;
                    self.scan_data = true;
                }
            },
            .entropy_marker => {
                if (byte == 0xff) return null;
                if (byte == 0 or (byte >= 0xd0 and byte <= 0xd7)) {
                    if (byte != 0) {
                        if (self.restart_interval == 0 or byte - 0xd0 != self.next_restart) return error.MalformedImage;
                        self.next_restart +%= 1;
                    } else {
                        self.scan_bytes += 1;
                        self.scan_data = true;
                    }
                    self.stage = .entropy;
                } else {
                    if (!self.scan_data) return error.MalformedImage;
                    try self.startMarker(byte);
                }
            },
        }
        return null;
    }

    fn frameByte(self: *Jpeg, byte: u8) Error!void {
        if (self.at == 5) {
            if (self.frame or byte == 0 or self.length != 6 + @as(u16, 3) * byte) return error.MalformedImage;
            self.components = byte;
        } else if (self.at >= 6) {
            switch ((self.at - 6) % 3) {
                0 => {
                    if (has(&self.component_ids, byte)) return error.MalformedImage;
                    include(&self.component_ids, byte);
                    self.table_high = byte;
                },
                1 => if (byte >> 4 == 0 or byte >> 4 > 4 or byte & 15 == 0 or byte & 15 > 4) return error.MalformedImage,
                2 => {
                    if (byte > 3) return error.MalformedImage;
                    self.component_quant[self.table_high / 4] |= byte << @intCast((self.table_high % 4) * 2);
                },
                else => unreachable,
            }
        }
    }

    fn scanByte(self: *Jpeg, byte: u8) Error!void {
        if (self.at == 0) {
            if (!self.frame or byte == 0 or byte > self.components or self.length != 4 + @as(u16, 2) * byte) return error.MalformedImage;
        } else if (self.at < self.length - 3) {
            if (self.at % 2 == 1) {
                if (!has(&self.component_ids, byte) or has(&self.scan_ids, byte)) return error.MalformedImage;
                include(&self.scan_ids, byte);
                const table = (self.component_quant[byte / 4] >> @intCast((byte % 4) * 2)) & 3;
                self.scan_quant |= @as(u8, 1) << @intCast(table);
            } else {
                if (byte >> 4 > 3 or byte & 15 > 3) return error.MalformedImage;
                self.scan_dc |= @as(u8, 1) << @intCast(byte >> 4);
                self.scan_ac |= @as(u8, 1) << @intCast(byte & 15);
            }
        } else self.trailer[self.at - (self.length - 3)] = byte;
    }

    fn tableByte(self: *Jpeg, byte: u8) Error!void {
        switch (self.table_phase) {
            .header => {
                if (byte & 15 > 3 or byte >> 4 > 1) return error.MalformedImage;
                self.table_id = @intCast(byte & 15);
                self.table_precision = @intCast(byte >> 4);
                if (self.marker == 0xdb) {
                    self.table_left = @as(u16, 64) << self.table_precision;
                    self.table_phase = .quant;
                } else {
                    self.table_left = 16;
                    self.table_symbols = 0;
                    self.table_slots = 1;
                    self.symbol_ids = @splat(0);
                    self.table_phase = .counts;
                }
            },
            .quant => {
                if (self.table_precision == 0) {
                    if (byte == 0) return error.MalformedImage;
                } else if (self.table_left % 2 == 0) {
                    self.table_high = byte;
                } else if (self.table_high == 0 and byte == 0) return error.MalformedImage;
                self.table_left -= 1;
                if (self.table_left == 0) {
                    self.quant_tables |= @as(u8, 1) << self.table_id;
                    self.table_phase = .header;
                }
            },
            .counts => {
                self.table_slots *= 2;
                if (byte >= self.table_slots) return error.MalformedImage;
                self.table_slots -= byte;
                self.table_symbols += byte;
                if (self.table_symbols > 256) return error.MalformedImage;
                self.table_left -= 1;
                if (self.table_left == 0) {
                    if (self.table_symbols == 0) return error.MalformedImage;
                    self.table_left = self.table_symbols;
                    self.table_phase = .symbols;
                }
            },
            .symbols => {
                if (has(&self.symbol_ids, byte)) return error.MalformedImage;
                include(&self.symbol_ids, byte);
                if (self.table_precision == 0 and byte > 15) return error.MalformedImage;
                self.table_left -= 1;
                if (self.table_left == 0) {
                    if (self.table_precision == 0) self.dc_tables |= @as(u8, 1) << self.table_id else self.ac_tables |= @as(u8, 1) << self.table_id;
                    self.table_phase = .header;
                }
            },
        }
    }

    fn endSegment(self: *Jpeg) Error!?[2]u32 {
        self.stage = .marker_start;
        switch (self.marker) {
            0xc0, 0xc1, 0xc2 => {
                if (self.length < 6 or self.components == 0) return error.MalformedImage;
                if (self.prefix[0] != 8 and !(self.marker != 0xc0 and self.prefix[0] == 12)) return error.MalformedImage;
                self.frame = true;
                self.progressive = self.marker == 0xc2;
                return .{ std.mem.readInt(u16, self.prefix[3..5], .big), std.mem.readInt(u16, self.prefix[1..3], .big) };
            },
            0xda => {
                if (self.length < 4) return error.MalformedImage;
                const spectral = &self.trailer;
                if (spectral[0] > spectral[1] or spectral[1] > 63 or spectral[2] >> 4 > 13 or spectral[2] & 15 > 13) return error.MalformedImage;
                if (!self.progressive and !std.mem.eql(u8, spectral, &.{ 0, 63, 0 })) return error.MalformedImage;
                if (self.progressive and ((spectral[0] == 0 and spectral[1] != 0) or (spectral[0] != 0 and self.prefix[0] != 1))) return error.MalformedImage;
                if (self.progressive and spectral[2] >> 4 != 0 and spectral[2] & 15 != (spectral[2] >> 4) - 1) return error.MalformedImage;
                if (self.scan_quant & ~self.quant_tables != 0) return error.MalformedImage;
                if ((!self.progressive or (spectral[0] == 0 and spectral[2] >> 4 == 0)) and self.scan_dc & ~self.dc_tables != 0) return error.MalformedImage;
                if ((!self.progressive or spectral[0] != 0) and self.scan_ac & ~self.ac_tables != 0) return error.MalformedImage;
                if (spectral[0] == 0 and spectral[2] >> 4 == 0) {
                    for (&self.covered_ids, self.scan_ids) |*covered, scanned| covered.* |= scanned;
                }
                self.scans = std.math.add(u32, self.scans, 1) catch return error.ImageResourceLimit;
                self.scan_data = false;
                self.next_restart = 0;
                self.stage = .entropy;
            },
            0xdd => {
                if (self.length != 2) return error.MalformedImage;
                self.restart_interval = std.mem.readInt(u16, self.prefix[0..2], .big);
            },
            0xdb => if (self.length < 65 or self.table_phase != .header) return error.MalformedImage,
            0xc4 => if (self.length < 18 or self.table_phase != .header) return error.MalformedImage,
            else => {},
        }
        return null;
    }
};

const png_fixture = "\x89PNG\r\n\x1a\n" ++
    "\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++
    "\x00\x00\x00\x0dIDAT\x08\xd7\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x72\x9c\x52\x67" ++
    "\x00\x00\x00\x00IEND\xae\x42\x60\x82";

// This is a framed JPEG scanner fixture, not a claim that its entropy decodes.
const jpeg_tables = "\xff\xdb\x00\x43\x00" ++ "\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01" ++
    "\xff\xc4\x00\x26\x00\x01" ++ "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++ "\x00\x10\x01" ++ "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++ "\x00";
const jpeg_fixture = "\xff\xd8" ++ jpeg_tables ++ "\xff\xc0\x00\x0b\x08\x00\x02\x00\x03\x01\x01\x11\x00" ++
    "\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00\x01\xff\x00\x02\xff\xd9";

fn scan(bytes: []const u8, assertion: ?Format, limits: Limits, window: usize) !Metadata {
    var scanner = try Scanner.init(bytes.len, assertion, limits);
    var at: usize = 0;
    while (at < bytes.len) {
        var allowance = window;
        at += try scanner.advance(bytes[at..], &allowance);
    }
    return scanner.finish();
}

test "static image scanners retain dimensions across every byte boundary" {
    for (1..png_fixture.len + 1) |window| {
        const png = try scan(png_fixture, .png, .{}, window);
        try std.testing.expectEqual(Metadata{ .format = .png, .width = 1, .height = 1 }, png);
        const jpeg = try scan(jpeg_fixture, .jpeg, .{}, window);
        try std.testing.expectEqual(Metadata{ .format = .jpeg, .width = 3, .height = 2 }, jpeg);
    }
}

test "static media admission accepts independently decoded baseline and progressive JPEG originals" {
    for ([_][]const u8{ @embedFile("testing/fixtures/input-baseline.jpg"), @embedFile("testing/fixtures/input-progressive.jpg") }) |fixture| {
        for (1..fixture.len + 1) |window| {
            const actual = try scan(fixture, .jpeg, .{}, window);
            try std.testing.expectEqual(Metadata{ .format = .jpeg, .width = 3, .height = 2 }, actual);
        }
        for (0..fixture.len) |end| {
            if (scan(fixture[0..end], .jpeg, .{}, 7)) |_| return error.AcceptedTruncatedImage else |_| {}
        }
    }
}

test "static image scanners reject every incomplete prefix and trailing bytes" {
    for ([_][]const u8{ png_fixture, jpeg_fixture }) |fixture| {
        for (0..fixture.len) |end| {
            if (scan(fixture[0..end], null, .{}, 1)) |_| return error.AcceptedTruncatedImage else |_| {}
        }
        var scanner = try Scanner.init(fixture.len + 1, null, .{});
        var allowance: usize = fixture.len;
        _ = try scanner.advance(fixture, &allowance);
        allowance = 1;
        try std.testing.expectError(error.MalformedImage, scanner.advance("x", &allowance));
    }
}

test "static image scanners enforce asserted format and parameterized resource bounds" {
    try std.testing.expectError(error.ImageMimeMismatch, scan(png_fixture, .jpeg, .{}, 1));
    try std.testing.expectError(error.ImageMimeMismatch, scan(jpeg_fixture, .png, .{}, 1));
    try std.testing.expectError(error.UnsupportedImage, scan("GIF89a00", null, .{}, 1));
    for (0..3) |delta| {
        const max_bytes = png_fixture.len - 1 + delta;
        if (delta == 0) try std.testing.expectError(error.ImageResourceLimit, scan(png_fixture, null, .{ .max_bytes = max_bytes }, 1)) else _ = try scan(png_fixture, null, .{ .max_bytes = max_bytes }, 1);
    }
    try std.testing.expectError(error.ImageResourceLimit, scan(jpeg_fixture, null, .{ .max_dimension = 2 }, 1));
    _ = try scan(jpeg_fixture, null, .{ .max_dimension = 3 }, 1);
    _ = try scan(jpeg_fixture, null, .{ .max_dimension = 4 }, 1);
}

test "static PNG framing requires CRC and valid IHDR and forbids animation" {
    var changed: [png_fixture.len]u8 = undefined;
    @memcpy(&changed, png_fixture);
    changed[45] ^= 1;
    try std.testing.expectError(error.MalformedImage, scan(&changed, null, .{}, 1));
    @memcpy(&changed, png_fixture);
    changed[24] = 3;
    try std.testing.expectError(error.MalformedImage, scan(&changed, null, .{}, 1));
    const animated = png_fixture[0..33] ++ "\x00\x00\x00\x08acTL";
    try std.testing.expectError(error.UnsupportedImage, scan(animated, null, .{}, 1));
}

test "static PNG semantic headers reject zero overflow and invalid depths with valid CRCs" {
    const cases = [_]struct { width: u32, height: u32, depth: u8, color: u8, crc: u32 }{
        .{ .width = 0, .height = 1, .depth = 8, .color = 6, .crc = 0xf0d7afb7 },
        .{ .width = 1, .height = 0, .depth = 8, .color = 6, .crc = 0xd449172c },
        .{ .width = 0x80000000, .height = 1, .depth = 8, .color = 6, .crc = 0x50bd8aa0 },
        .{ .width = 1, .height = 1, .depth = 3, .color = 6, .crc = 0x68c5f598 },
        .{ .width = 1, .height = 1, .depth = 8, .color = 5, .crc = 0x0da06b67 },
    };
    for (cases) |case| {
        var bytes: [png_fixture.len]u8 = undefined;
        @memcpy(&bytes, png_fixture);
        std.mem.writeInt(u32, bytes[16..20], case.width, .big);
        std.mem.writeInt(u32, bytes[20..24], case.height, .big);
        bytes[24] = case.depth;
        bytes[25] = case.color;
        std.mem.writeInt(u32, bytes[29..33], case.crc, .big);
        try std.testing.expectError(error.MalformedImage, scan(&bytes, null, .{}, 1));
    }
}

test "static JPEG framing rejects zero dimensions repeated frames and malformed scans" {
    var changed: [jpeg_fixture.len]u8 = undefined;
    @memcpy(&changed, jpeg_fixture);
    const frame = 2 + jpeg_tables.len;
    changed[frame + 6] = 0;
    try std.testing.expectError(error.MalformedImage, scan(&changed, null, .{}, 1));
    @memcpy(&changed, jpeg_fixture);
    changed[frame + 21] = 64;
    try std.testing.expectError(error.MalformedImage, scan(&changed, null, .{}, 1));
    try std.testing.expectError(error.MalformedImage, scan(jpeg_fixture[0 .. frame + 13] ++ jpeg_fixture[frame..], null, .{}, 1));
}

test "static image scanning honors a zero allowance without reading" {
    var scanner = try Scanner.init(png_fixture.len, null, .{});
    var allowance: usize = 0;
    try std.testing.expectEqual(@as(usize, 0), try scanner.advance(png_fixture, &allowance));
    try std.testing.expectEqual(@as(u64, 0), scanner.position);
    try std.testing.expectError(error.TruncatedImage, scanner.finish());
}

test "real JPEG admission rejects missing tables malformed scans and incomplete component coverage" {
    @setEvalBranchQuota(10_000);
    const baseline = @embedFile("testing/fixtures/input-baseline.jpg");
    const table = comptime std.mem.indexOf(u8, baseline, "\xff\xdb").?;
    const frame = comptime std.mem.indexOf(u8, baseline, "\xff\xc0").?;
    const scan_at = comptime std.mem.indexOf(u8, baseline, "\xff\xda").?;
    var bytes: [baseline.len]u8 = undefined;
    @memcpy(&bytes, baseline);
    bytes[table + 4] = 2;
    try std.testing.expectError(error.MalformedImage, scan(&bytes, .jpeg, .{}, 1));
    @memcpy(&bytes, baseline);
    bytes[scan_at + 4] = 0;
    try std.testing.expectError(error.MalformedImage, scan(&bytes, .jpeg, .{}, 1));
    @memcpy(&bytes, baseline);
    bytes[frame + 4] = 7;
    try std.testing.expectError(error.MalformedImage, scan(&bytes, .jpeg, .{}, 1));
    const without_tables = baseline[0..table] ++ baseline[frame..];
    try std.testing.expectError(error.MalformedImage, scan(without_tables, .jpeg, .{}, 1));
}

test "progressive JPEG refinement requires adjacent approximation levels" {
    const original = @embedFile("testing/fixtures/input-progressive.jpg");
    const approximation = 0x23d;
    try std.testing.expectEqual(@as(u8, 0x10), original[approximation]);
    var malformed = original.*;
    malformed[approximation] = 0x11;
    try std.testing.expectError(error.MalformedImage, scan(&malformed, .jpeg, .{}, 1));
    for (1..14) |high| {
        for (0..14) |low| {
            if (low == high - 1) continue;
            malformed[approximation] = @as(u8, @intCast(high)) << 4 | @as(u8, @intCast(low));
            try std.testing.expectError(error.MalformedImage, scan(&malformed, .jpeg, .{}, 1));
        }
    }
}
