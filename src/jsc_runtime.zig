const std = @import("std");

const page_size = 64 * 1024;
const framework_path = "/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore";

const JSContext = opaque {};
const JSString = opaque {};
const JSValue = opaque {};
const JSObject = opaque {};

const JSContextRef = ?*JSContext;
const JSStringRef = ?*JSString;
const JSValueRef = ?*const JSValue;
pub const JSObjectRef = ?*JSObject;

const Api = struct {
    JSGlobalContextCreate: *const fn (?*anyopaque) callconv(.c) JSContextRef,
    JSGlobalContextRelease: *const fn (JSContextRef) callconv(.c) void,
    JSStringCreateWithUTF8CString: *const fn ([*:0]const u8) callconv(.c) JSStringRef,
    JSStringRelease: *const fn (JSStringRef) callconv(.c) void,
    JSEvaluateScript: *const fn (
        JSContextRef,
        JSStringRef,
        JSObjectRef,
        JSStringRef,
        c_int,
        *JSValueRef,
    ) callconv(.c) JSValueRef,
    JSValueToStringCopy: *const fn (JSContextRef, JSValueRef, *JSValueRef) callconv(.c) JSStringRef,
    JSStringGetMaximumUTF8CStringSize: *const fn (JSStringRef) callconv(.c) usize,
    JSStringGetUTF8CString: *const fn (JSStringRef, [*]u8, usize) callconv(.c) usize,
    JSValueToObject: *const fn (JSContextRef, JSValueRef, *JSValueRef) callconv(.c) JSObjectRef,
    JSValueToNumber: *const fn (JSContextRef, JSValueRef, *JSValueRef) callconv(.c) f64,
    JSValueMakeNumber: *const fn (JSContextRef, f64) callconv(.c) JSValueRef,
    JSObjectCallAsFunction: *const fn (
        JSContextRef,
        JSObjectRef,
        JSObjectRef,
        usize,
        [*]const JSValueRef,
        *JSValueRef,
    ) callconv(.c) JSValueRef,
    JSObjectGetTypedArrayBytesPtr: *const fn (JSContextRef, JSObjectRef, *JSValueRef) callconv(.c) ?*anyopaque,
    JSObjectGetTypedArrayByteLength: *const fn (JSContextRef, JSObjectRef, *JSValueRef) callconv(.c) usize,
};

pub const Runtime = struct {
    library: std.DynLib,
    api: Api,
    context: JSContextRef,

    pub fn open() !Runtime {
        var library = try std.DynLib.open(framework_path);
        errdefer library.close();
        var api: Api = undefined;
        inline for (@typeInfo(Api).@"struct".fields) |field| {
            @field(api, field.name) = library.lookup(field.type, field.name) orelse {
                return error.MissingJavaScriptCoreSymbol;
            };
        }
        const context = api.JSGlobalContextCreate(null) orelse return error.ContextCreationFailed;
        return .{ .library = library, .api = api, .context = context };
    }

    pub fn close(self: *Runtime) void {
        self.api.JSGlobalContextRelease(self.context);
        self.library.close();
    }

    pub fn instantiate(
        self: *const Runtime,
        allocator: std.mem.Allocator,
        wasm: []const u8,
    ) !void {
        const hex = try encodeHex(allocator, wasm);
        defer allocator.free(hex);
        const source = try std.mem.concat(allocator, u8, &.{
            "globalThis.__onepage = {}; const hex = '",
            hex,
            "'; const bytes = new Uint8Array(hex.length / 2); " ++
                "for (let i = 0; i < bytes.length; i++) " ++
                "bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16); " ++
                "__onepage.module = new WebAssembly.Module(bytes); " ++
                "__onepage.instance = new WebAssembly.Instance(__onepage.module, {});",
        });
        defer allocator.free(source);
        _ = try self.evaluate(allocator, source);
    }

    pub fn evaluate(
        self: *const Runtime,
        allocator: std.mem.Allocator,
        source: []const u8,
    ) !JSValueRef {
        const source_z = try allocator.dupeZ(u8, source);
        defer allocator.free(source_z);
        const source_ref = self.api.JSStringCreateWithUTF8CString(source_z.ptr);
        defer self.api.JSStringRelease(source_ref);
        var exception: JSValueRef = null;
        const value = self.api.JSEvaluateScript(self.context, source_ref, null, null, 1, &exception);
        if (exception != null) return error.JavaScriptException;
        return value;
    }

    pub fn valueString(
        self: *const Runtime,
        allocator: std.mem.Allocator,
        value: JSValueRef,
    ) ![]u8 {
        var exception: JSValueRef = null;
        const string_ref = self.api.JSValueToStringCopy(self.context, value, &exception);
        if (exception != null or string_ref == null) return error.JavaScriptStringConversionFailed;
        defer self.api.JSStringRelease(string_ref);
        const capacity = self.api.JSStringGetMaximumUTF8CStringSize(string_ref);
        const buffer = try allocator.alloc(u8, capacity);
        errdefer allocator.free(buffer);
        const written = self.api.JSStringGetUTF8CString(string_ref, buffer.ptr, buffer.len);
        if (written == 0) return error.JavaScriptStringConversionFailed;
        return buffer[0 .. written - 1];
    }

    pub fn memory(self: *const Runtime, allocator: std.mem.Allocator) ![]u8 {
        const value = try self.evaluate(
            allocator,
            "new Uint8Array(__onepage.instance.exports.memory.buffer)",
        );
        var exception: JSValueRef = null;
        const object = self.api.JSValueToObject(self.context, value, &exception);
        if (exception != null or object == null) return error.MemoryBufferUnavailable;
        const length = self.api.JSObjectGetTypedArrayByteLength(self.context, object, &exception);
        if (exception != null or length != page_size) return error.InvalidMemoryLength;
        const raw = self.api.JSObjectGetTypedArrayBytesPtr(self.context, object, &exception);
        if (exception != null or raw == null) return error.MemoryBufferUnavailable;
        const bytes: [*]u8 = @ptrCast(raw.?);
        return bytes[0..length];
    }

    pub fn function(
        self: *const Runtime,
        allocator: std.mem.Allocator,
        source: []const u8,
    ) !JSObjectRef {
        const value = try self.evaluate(allocator, source);
        var exception: JSValueRef = null;
        const object = self.api.JSValueToObject(self.context, value, &exception);
        if (exception != null or object == null) return error.JavaScriptFunctionUnavailable;
        return object;
    }

    pub fn callNumbers(
        self: *const Runtime,
        function_ref: JSObjectRef,
        numbers: []const u32,
    ) !void {
        _ = try self.callNumbersValue(function_ref, numbers);
    }

    pub fn callNumber(
        self: *const Runtime,
        function_ref: JSObjectRef,
        numbers: []const u32,
    ) !u32 {
        const value = try self.callNumbersValue(function_ref, numbers);
        var exception: JSValueRef = null;
        const number = self.api.JSValueToNumber(self.context, value, &exception);
        if (exception != null or number < 0 or number > std.math.maxInt(u32)) {
            return error.JavaScriptNumberConversionFailed;
        }
        return @intFromFloat(number);
    }

    fn callNumbersValue(
        self: *const Runtime,
        function_ref: JSObjectRef,
        numbers: []const u32,
    ) !JSValueRef {
        if (numbers.len > 8) return error.TooManyArguments;
        var arguments: [8]JSValueRef = undefined;
        for (numbers, 0..) |number, index| {
            arguments[index] = self.api.JSValueMakeNumber(self.context, @floatFromInt(number));
        }
        var exception: JSValueRef = null;
        const value = self.api.JSObjectCallAsFunction(
            self.context,
            function_ref,
            null,
            numbers.len,
            &arguments,
            &exception,
        );
        if (exception != null) return error.JavaScriptCallFailed;
        return value;
    }
};

fn encodeHex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const alphabet = "0123456789abcdef";
    const result = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        result[index * 2] = alphabet[byte >> 4];
        result[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return result;
}
