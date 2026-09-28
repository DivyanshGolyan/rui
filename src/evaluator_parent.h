#ifndef RUI_EVALUATOR_PARENT_H
#define RUI_EVALUATOR_PARENT_H
#include <stddef.h>
#include <stdint.h>

/* The caller owns an immutable read-only source fd, an immutable read-only
 * regular prepared-input fd (-1 only for compile-only), and a writable
 * regular scratch-file output fd. On failure, output may contain untrusted
 * partial bytes even if best-effort truncation was attempted. The caller
 * retains file custody and its charge until confirmed shrink, or confirmed
 * removal/absence plus final closure. Failure alone never authorizes refund
 * or artifact reuse.
 * This synchronous shim cannot bound a stalled filesystem write. The caller also
 * owns serialization: another lifecycle cannot begin until this call returns.
 * No database transaction should be held during this call. Returns 1 only
 * for confirmed cancellation, -1 for failure, and 0 only after exact framing,
 * EOF and normal child exit. The output fd then contains
 * the untrusted JSON bytes; the caller must validate their semantic meaning.
 * Compiler stderr is copied only up to diagnostic_capacity; the remainder is
 * drained. diagnostic_length is reset even when spawn or validation fails. */
int rui_evaluate(const char *executable, int source_fd, int prepared_fd,
                 int output_fd,
                 uint64_t output_budget, int compile_only,
                 int (*cancelled)(void *), void *cancel_context,
                 int (*reserve_output)(void *, uint64_t), void *budget_context,
                 char *diagnostic, size_t diagnostic_capacity,
                 size_t *diagnostic_length);
#endif
