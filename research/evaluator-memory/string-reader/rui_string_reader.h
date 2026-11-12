#ifndef RUI_STRING_READER_H
#define RUI_STRING_READER_H
#include "quickjs.h"
#include <stdint.h>
#include <stddef.h>

typedef enum {
    OP_STRING_OK,
    OP_STRING_READ_FAILED,
    OP_STRING_INVALID_UTF8,
    OP_STRING_UNREPRESENTABLE,
    OP_STRING_ENGINE_MEMORY,
    OP_STRING_INPUT_CHANGED
} OPStringStatus;

/* Read exactly length bytes at a relative offset. Return 0 on success, nonzero
 * on short read/I/O/cancellation. The reader must not invoke JS or retain dst.
 * The source is immutable and readable for both passes, through this call. */
typedef int (*OPStringRead)(void *opaque, uint64_t offset,
                            uint8_t *dst, size_t length);

/* Return one ordinary owned JS string or JS_EXCEPTION. No partially initialized
 * value or engine storage escapes. workspace is exclusively borrowed until
 * return, must have positive size, and may immediately be reused afterwards.
 * Caller owns the workspace allocation/budget. Both passes use bounded reads.
 * Invalid UTF-8 (including encoded surrogates) is rejected, not replaced.
 * On failure, status classifies the failure and a JS exception is pending.
 * Context and callback/workspace ownership remain on one native thread.
 * This is a research-only extension, not an upstream QuickJS API. */
JSValue OP_NewStringUTF8Reader(JSContext *ctx, uint64_t byte_length,
                              OPStringRead read, void *opaque,
                              uint8_t *workspace, size_t workspace_size,
                              OPStringStatus *status);
/* Measurement baseline only, using public QuickJS operations. join must be a
 * pristine intrinsic captured by the native owner before author code runs. */
JSValue OP_NewStringUTF8Public(JSContext *ctx, uint64_t byte_length,
                              OPStringRead read, void *opaque,
                              uint8_t *workspace, size_t workspace_size,
                              OPStringStatus *status, JSValueConst join);
#endif
