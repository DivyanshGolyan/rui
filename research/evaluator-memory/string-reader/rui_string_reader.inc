/* Compiled at the end of pinned quickjs.c. Only op_allocate_string below touches
 * string layout; sizing also uses the pin's JS_STRING_LEN_MAX bound. */
#include "rui_string_reader.h"
#include <assert.h>

typedef struct {
    OPStringRead read;
    void *opaque;
    uint8_t *window;
    size_t capacity, cursor, available;
    uint64_t length, next;
    OPStringStatus status;
} OPStringCursor;

static int op_byte(OPStringCursor *r, uint8_t *out) {
    if (r->cursor == r->available) {
        if (r->next == r->length) return 0;
        uint64_t remaining = r->length - r->next;
        size_t size = remaining < r->capacity ? (size_t)remaining : r->capacity;
        if (r->read(r->opaque, r->next, r->window, size)) {
            r->status = OP_STRING_READ_FAILED;
            return -1;
        }
        r->next += size;
        r->cursor = 0;
        r->available = size;
    }
    *out = r->window[r->cursor++];
    return 1;
}

/* One scalar, preserving errors even when a multibyte sequence crosses windows. */
static int op_scalar(OPStringCursor *r, uint32_t *scalar) {
    uint8_t lead;
    int present = op_byte(r, &lead);
    if (present <= 0) return present;
    if (lead < 0x80) { *scalar = lead; return 1; }
    unsigned count;
    uint32_t value, minimum;
    if (lead >= 0xc2 && lead <= 0xdf) {
        count = 1; value = lead & 0x1f; minimum = 0x80;
    } else if (lead >= 0xe0 && lead <= 0xef) {
        count = 2; value = lead & 0x0f; minimum = 0x800;
    } else if (lead >= 0xf0 && lead <= 0xf4) {
        count = 3; value = lead & 7; minimum = 0x10000;
    } else goto invalid;
    for (unsigned i = 0; i < count; i++) {
        uint8_t next;
        int result = op_byte(r, &next);
        if (result < 0) return -1;
        if (!result || (next & 0xc0) != 0x80) goto invalid;
        value = (value << 6) | (next & 0x3f);
    }
    if (value < minimum || value > 0x10ffff ||
        (value >= 0xd800 && value <= 0xdfff)) goto invalid;
    *scalar = value;
    return 1;
invalid:
    r->status = OP_STRING_INVALID_UTF8;
    return -1;
}

/* Compatibility seam audited against the pinned QuickJS string owner. Engine
 * allocation, limit enforcement, exception and refcount cleanup stay upstream.
 * No outside consumer sees JSString or assumes its layout. */
static JSValue op_allocate_string(JSContext *ctx, int units, int wide,
                                  uint8_t **narrow, uint16_t **utf16) {
    JSString *string = js_alloc_string(ctx, units, wide);
    if (!string) return JS_EXCEPTION;
    *narrow = wide ? NULL : str8(string);
    *utf16 = wide ? str16(string) : NULL;
    if (!wide) (*narrow)[units] = 0;
    return JS_MKPTR(JS_TAG_STRING, string);
}

JSValue OP_NewStringUTF8Reader(JSContext *ctx, uint64_t byte_length,
                              OPStringRead read, void *opaque,
                              uint8_t *workspace, size_t workspace_size,
                              OPStringStatus *status) {
    assert(ctx && read && workspace && workspace_size && status);
    *status = OP_STRING_OK;
    OPStringCursor cursor = {.read = read, .opaque = opaque, .window = workspace,
        .capacity = workspace_size, .length = byte_length};
    uint64_t units = 0;
    int wide = 0, step;
    uint32_t scalar;
    while ((step = op_scalar(&cursor, &scalar)) > 0) {
        units += scalar > 0xffff ? 2 : 1;
        wide |= scalar > 0xff;
        if (units > JS_STRING_LEN_MAX) {
            *status = OP_STRING_UNREPRESENTABLE;
            return JS_ThrowRangeError(ctx, "string length is not representable");
        }
    }
    if (step < 0) goto read_error;
    uint8_t *narrow;
    uint16_t *utf16;
    JSValue value = op_allocate_string(ctx, (int)units, wide, &narrow, &utf16);
    if (JS_IsException(value)) {
        *status = OP_STRING_ENGINE_MEMORY;
        return value;
    }
    cursor.cursor = cursor.available = 0;
    cursor.next = 0;
    uint64_t index = 0;
    while ((step = op_scalar(&cursor, &scalar)) > 0) {
        unsigned needed = scalar > 0xffff ? 2 : 1;
        if (needed > units - index || (!wide && scalar > 0xff)) {
            cursor.status = OP_STRING_INPUT_CHANGED;
            step = -1;
            break;
        }
        if (!wide) narrow[index++] = (uint8_t)scalar;
        else if (scalar <= 0xffff) utf16[index++] = (uint16_t)scalar;
        else {
            scalar -= 0x10000;
            utf16[index++] = 0xd800 | (scalar >> 10);
            utf16[index++] = 0xdc00 | (scalar & 0x3ff);
        }
    }
    if (step < 0 || index != units) {
        JS_FreeValue(ctx, value);
        if (step >= 0) cursor.status = OP_STRING_INPUT_CHANGED;
        goto read_error;
    }
    return value;
read_error:
    *status = cursor.status;
    return JS_ThrowTypeError(ctx, "prepared UTF-8 input failed (%d)", *status);
}

/* Comparison only: bounded public constructors plus a captured pristine join
 * intrinsic. This uses no string-layout internals. Parts stay live until join
 * returns, and upstream controls flattening/widening and its allocation cost. */
static int op_public_part(JSContext *ctx, JSValue parts, uint32_t *index,
                          const uint8_t *bytes, size_t length) {
    JSValue part = JS_NewStringLen(ctx, (const char *)bytes, length);
    if (JS_IsException(part)) return -1;
    #ifdef OP_NEGATIVE_SET
    return JS_SetPropertyUint32(ctx, parts, (*index)++, part);
#else
    return JS_DefinePropertyValueUint32(ctx, parts, (*index)++, part, JS_PROP_C_W_E);
#endif
}

JSValue OP_NewStringUTF8Public(JSContext *ctx, uint64_t byte_length,
                              OPStringRead read, void *opaque,
                              uint8_t *workspace, size_t workspace_size,
                              OPStringStatus *status, JSValueConst join) {
    assert(ctx && read && workspace && workspace_size && status);
    *status = OP_STRING_OK;
    OPStringCursor cursor = {.read = read, .opaque = opaque, .window = workspace,
        .capacity = workspace_size, .length = byte_length};
    uint64_t units = 0;
    uint32_t scalar;
    int step;
    while ((step = op_scalar(&cursor, &scalar)) > 0) {
        units += scalar > 0xffff ? 2 : 1;
        if (units > JS_STRING_LEN_MAX) {
            *status = OP_STRING_UNREPRESENTABLE;
            return JS_ThrowRangeError(ctx, "string length is not representable");
        }
    }
    if (step < 0) {
        *status = cursor.status;
        return JS_ThrowTypeError(ctx, "prepared UTF-8 input failed");
    }
    JSValue parts = JS_NewArray(ctx);
    if (JS_IsException(parts)) goto memory_error;
    cursor.cursor = cursor.available = 0;
    cursor.next = 0;
    uint8_t bytes[4096];
    size_t used = 0;
    uint32_t index = 0;
    while ((step = op_scalar(&cursor, &scalar)) > 0) {
        if (used > sizeof(bytes) - 4) {
            if (op_public_part(ctx, parts, &index, bytes, used) < 0) goto memory_error;
            used = 0;
        }
        if (scalar < 0x80) bytes[used++] = (uint8_t)scalar;
        else if (scalar < 0x800) {
            bytes[used++] = 0xc0 | (scalar >> 6);
            bytes[used++] = 0x80 | (scalar & 63);
        } else if (scalar < 0x10000) {
            bytes[used++] = 0xe0 | (scalar >> 12);
            bytes[used++] = 0x80 | ((scalar >> 6) & 63);
            bytes[used++] = 0x80 | (scalar & 63);
        } else {
            bytes[used++] = 0xf0 | (scalar >> 18);
            bytes[used++] = 0x80 | ((scalar >> 12) & 63);
            bytes[used++] = 0x80 | ((scalar >> 6) & 63);
            bytes[used++] = 0x80 | (scalar & 63);
        }
    }
    if (step < 0) {
        JS_FreeValue(ctx, parts);
        *status = cursor.status;
        return JS_ThrowTypeError(ctx, "prepared UTF-8 input failed");
    }
    if (used && op_public_part(ctx, parts, &index, bytes, used) < 0) goto memory_error;
    JSValue separator = JS_NewStringLen(ctx, "", 0);
    if (JS_IsException(separator)) goto memory_error;
    JSValue result = JS_Call(ctx, join, parts, 1, &separator);
    JS_FreeValue(ctx, separator);
    JS_FreeValue(ctx, parts);
    if (JS_IsException(result)) *status = OP_STRING_ENGINE_MEMORY;
    return result;
memory_error:
    JS_FreeValue(ctx, parts);
    *status = OP_STRING_ENGINE_MEMORY;
    return JS_EXCEPTION;
}
