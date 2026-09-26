#include "evaluator_string_reader.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Force individual engine allocations through the backing allocator, just
 * like the pin's sanitizer build. The production extension is unchanged. */
typedef union {
    size_t size;
    max_align_t alignment;
} Block;
static size_t live, calls, fail_at, failed;

static void *engine_malloc(void *opaque, size_t size) {
    (void)opaque;
    if (++calls == fail_at) { failed++; return NULL; }
    if (size > SIZE_MAX - sizeof(Block)) return NULL;
    Block *block = malloc(sizeof(Block) + size);
    if (!block) return NULL;
    block->size = size;
    live++;
    return block + 1;
}
static void engine_free(void *opaque, void *ptr) {
    (void)opaque;
    if (!ptr) return;
    Block *block = (Block *)ptr - 1;
    assert(live);
    live--;
    free(block);
}
static void *engine_calloc(void *opaque, size_t count, size_t size) {
    if (size && count > SIZE_MAX / size) return NULL;
    void *ptr = engine_malloc(opaque, count * size);
    if (ptr) memset(ptr, 0, count * size);
    return ptr;
}
static void *engine_realloc(void *opaque, void *ptr, size_t size) {
    if (!size) { engine_free(opaque, ptr); return NULL; }
    void *next = engine_malloc(opaque, size);
    if (!next) return NULL;
    if (ptr) {
        Block *old = (Block *)ptr - 1;
        memcpy(next, ptr, old->size < size ? old->size : size);
        engine_free(opaque, ptr);
    }
    return next;
}
static size_t engine_usable(const void *ptr) {
    return ptr ? ((const Block *)ptr - 1)->size : 0;
}

typedef struct {
    const uint8_t *bytes;
    size_t length, reads, fail_read, mutate_on;
} Input;
static int read_input(void *opaque, uint64_t offset, uint8_t *dst, size_t count) {
    Input *input = opaque;
    if (++input->reads == input->fail_read ||
        offset > input->length || count > input->length - offset) return -1;
    memcpy(dst, input->bytes + offset, count);
    if (input->reads == input->mutate_on) {
        assert(count == 2);
        dst[0] = 0xc4; dst[1] = 0x80; /* Latin-1 é becomes wide Ā. */
    }
    return 0;
}
static JSValue decode(JSContext *ctx, Input *input, size_t window,
                      OPStringStatus *status) {
    uint8_t workspace[4];
    assert(window > 0 && window <= sizeof(workspace));
    return OP_NewStringUTF8Reader(ctx, input->length, read_input, input,
                                  workspace, window, status);
}
static void expect_text(JSContext *ctx, Input input, const char *expected) {
    OPStringStatus status;
    JSValue value = decode(ctx, &input, 1, &status);
    assert(!JS_IsException(value) && status == OP_STRING_OK);
    const char *text = JS_ToCString(ctx, value);
    assert(text && !strcmp(text, expected));
    JS_FreeCString(ctx, text);
    JS_FreeValue(ctx, value);
}
static void expect_failure(JSContext *ctx, Input input, size_t window,
                           OPStringStatus expected) {
    OPStringStatus status;
    JSValue value = decode(ctx, &input, window, &status);
    if (!JS_IsException(value) || status != expected)
        fprintf(stderr, "string failure: expected %d, got %d (exception %d)\n",
                expected, status, JS_IsException(value));
    assert(JS_IsException(value) && status == expected);
    JS_FreeValue(ctx, JS_GetException(ctx));
}
static int visit(void *opaque, const void *units, size_t length, int wide) {
    size_t *count = opaque;
    (void)units; (void)wide;
    *count += length;
    return 0;
}

int main(void) {
    const JSMallocFunctions allocator = {
        engine_calloc, engine_malloc, engine_free, engine_realloc, engine_usable,
    };
    JSRuntime *rt = JS_NewRuntime2(&allocator, NULL);
    assert(rt);
    JS_SetMemoryLimit(rt, 16 * 1024 * 1024);
    JSContext *ctx = JS_NewContext(rt);
    assert(ctx);
    expect_text(ctx, (Input){(const uint8_t *)"", 0}, "");
    const char *scalars = "\177\302\200\303\277\304\200\344\270\255\360\237\230\200";
    expect_text(ctx, (Input){(const uint8_t *)scalars, strlen(scalars)}, scalars);
    Input wide = {(const uint8_t *)"x\344\270\255\360\237\230\200", 8};
    OPStringStatus status;
    JSValue value = decode(ctx, &wide, 1, &status);
    assert(!JS_IsException(value) && status == OP_STRING_OK);
    const char *text = JS_ToCString(ctx, value);
    assert(text && !strcmp(text, "x中😀"));
    JS_FreeCString(ctx, text);
    JS_FreeValue(ctx, value);
    expect_failure(ctx, (Input){(const uint8_t *)"abc", 3, .fail_read = 1}, 3,
                   OP_STRING_READ_FAILED);
    expect_failure(ctx, (Input){(const uint8_t *)"abc", 3, .fail_read = 2}, 3,
                   OP_STRING_READ_FAILED);
    expect_failure(ctx, (Input){(const uint8_t *)"\303\251", 2, .mutate_on = 2}, 2,
                   OP_STRING_INPUT_CHANGED);
    expect_failure(ctx, (Input){(const uint8_t *)"\355\240\200", 3}, 1,
                   OP_STRING_INVALID_UTF8);
    expect_text(ctx, (Input){(const uint8_t *)"reusable", 8}, "reusable");

    /* With arenas disabled, this is the actual string allocation rather than
     * a later pool refill. Failure must release the partial value and leave
     * the context reusable, including for subsequent atom creation. */
    fail_at = calls + 1;
    failed = 0;
    expect_failure(ctx, (Input){(const uint8_t *)"abc", 3}, 3,
                   OP_STRING_ENGINE_MEMORY);
    assert(failed == 1);
    fail_at = 0;
    expect_text(ctx, (Input){(const uint8_t *)"é中😀", 9}, "é中😀");
    JSValue key = JS_NewString(ctx, "é中😀");
    assert(!JS_IsException(key));
    JSAtom atom = JS_ValueToAtom(ctx, key);
    assert(atom != JS_ATOM_NULL);
    JS_FreeAtom(ctx, atom);
    JS_FreeValue(ctx, key);

    const char *rope = "'a'.repeat(600) + '中' + '😀'";
    value = JS_Eval(ctx, rope, strlen(rope), "rope.js", JS_EVAL_TYPE_GLOBAL);
    assert(!JS_IsException(value));
    size_t units = 0;
    assert(OP_VisitStringUnits(value, visit, &units) == 0);
    assert(units == 603); /* 600 ASCII units, 中, and two surrogate units. */
    JS_FreeValue(ctx, value);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    assert(live == 0);
    return 0;
}
