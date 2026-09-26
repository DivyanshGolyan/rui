/* Compiled at the end of pinned quickjs.c. Only op_allocate_string below touches
 * string layout; sizing also uses the pin's JS_STRING_LEN_MAX bound. */
#include "evaluator_string_reader.h"
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

int OP_VisitStringUnits(JSValueConst value, OPStringUnits visit, void *opaque) {
    assert(JS_IsString(value) && visit);
    JSStringRopeIter iterator;
    string_rope_iter_init(&iterator, value);
    const size_t window_units = 4096;
    JSString *string;
    while ((string = string_rope_iter_next(&iterator))) {
        size_t length = string->len;
        int wide = string->is_wide_char;
        for (size_t offset = 0; offset < length;) {
            size_t count = length - offset;
            if (count > window_units) count = window_units;
            const void *units = wide ? (const void *)(str16(string) + offset) :
                                       (const void *)(str8(string) + offset);
            if (visit(opaque, units, count, wide)) return -1;
            offset += count;
        }
    }
    return 0;
}
