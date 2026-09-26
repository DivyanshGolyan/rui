#ifndef RUI_EVALUATOR_PARENT_H
#define RUI_EVALUATOR_PARENT_H
#include <stddef.h>
#include <stdint.h>

/* The caller owns an immutable read-only source fd, an immutable read-only
 * regular prepared-input fd (-1 only for compile-only), and an append callback
 * that owns its output storage, capacity and cleanup on failure. The callback
 * receives complete framed body slices and returns nonzero on failure.
 * This synchronous shim cannot bound a stalled callback. The caller also
 * owns serialization: another lifecycle cannot begin until this call returns.
 * No database transaction should be held during this call. Returns 1 only
 * for confirmed cancellation, -1 for failure, and 0 only after exact framing,
 * EOF and normal child exit. The caller must validate the untrusted output.
 * Compiler stderr is copied only up to diagnostic_capacity; the remainder is
 * drained. diagnostic_length is reset even when spawn or validation fails. */
int rui_evaluate(const char *executable, int source_fd, int prepared_fd,
                 int compile_only,
                 int (*cancelled)(void *), void *cancel_context,
                 int (*append_output)(void *, const unsigned char *, size_t), void *output_context,
                 char *diagnostic, size_t diagnostic_capacity,
                 size_t *diagnostic_length);
#endif
