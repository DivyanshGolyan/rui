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

typedef int (*OPStringRead)(void *opaque, uint64_t offset,
                            uint8_t *dst, size_t length);

JSValue OP_NewStringUTF8Reader(JSContext *ctx, uint64_t byte_length,
                              OPStringRead read, void *opaque,
                              uint8_t *workspace, size_t workspace_size,
                              OPStringStatus *status);
JSValue OP_NewStringUTF8Public(JSContext *ctx, uint64_t byte_length,
                              OPStringRead read, void *opaque,
                              uint8_t *workspace, size_t workspace_size,
                              OPStringStatus *status, JSValueConst join);
#endif
