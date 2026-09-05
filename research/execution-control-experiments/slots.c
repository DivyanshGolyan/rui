/* Throwaway bookkeeping microbenchmark; no provider, SQLite, or scheduler model. */
#include <assert.h>
#include <inttypes.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

enum { FREE, RESERVED, DISPATCHABLE, ACTIVE, SEALED };
struct Cell {
    _Atomic uint32_t state;
    uint8_t kind, terminal_seen, root_reaped, flags;
    uint64_t attempt_id, operation_id, started_ns, completed_ns;
    uint64_t bytes_a, bytes_b, callbacks, deadline_ns, grace_deadline_ns;
    void *easy, *runtime;
    int spool_a, spool_b, pipe_a, pipe_b;
    pid_t root_pid, process_group;
    int wait_status;
};
_Static_assert(sizeof(struct Cell) == 128, "Match integrated PhysicalCustody stride");
static volatile uint64_t sink;

static uint64_t now_ns(void) {
    struct timespec t;
    assert(clock_gettime(CLOCK_MONOTONIC, &t) == 0);
    return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}

/* Compiler barrier prevents whole-call hoisting; atomics retain actual state loads. */
#define BARRIER() __asm__ volatile("" ::: "memory")
__attribute__((noinline)) static uint64_t state_scan(struct Cell *cells, unsigned n, unsigned occupied) {
    (void)occupied;
    BARRIER();
    uint64_t count = 0;
    for (unsigned i = 0; i < n; i++)
        count += atomic_load_explicit(&cells[i].state, memory_order_acquire) == ACTIVE;
    return count;
}

/* Mirrors the prototype's dispatch scan with already active/free model records. */
__attribute__((noinline)) static uint64_t dispatch_scan(struct Cell *cells, unsigned n, unsigned occupied) {
    (void)occupied;
    BARRIER();
    uint64_t count = 0;
    for (unsigned i = 0; i < n; i++) {
        uint32_t expected = DISPATCHABLE;
        if (atomic_compare_exchange_strong_explicit(&cells[i].state, &expected, ACTIVE,
                    memory_order_acq_rel, memory_order_acquire)) abort();
        count += atomic_load_explicit(&cells[i].state, memory_order_acquire) == ACTIVE;
    }
    return count;
}

/* Each completed model handle is searched from the start, like curl completion lookup. */
__attribute__((noinline)) static uint64_t completion_lookup(struct Cell *cells, unsigned n, unsigned occupied) {
    BARRIER();
    uint64_t count = 0;
    for (unsigned j = 0; j < occupied; j++) {
        unsigned target = ((uint64_t)j * n) / occupied;
        void *handle = (void *)(uintptr_t)(target + 1);
        for (unsigned i = 0; i < n; i++) {
            if (cells[i].easy == handle) { count++; break; }
        }
    }
    return count;
}

/* Full completion burst, linear lookup, owner settlement sweep, first-free reuse.
 * This deliberately explores generic first-free admission; the existing prototype
 * admits known array positions instead. No resources need cleanup in this model. */
__attribute__((noinline)) static uint64_t completion_reuse(struct Cell *cells, unsigned n, unsigned occupied) {
    BARRIER();
    uint64_t count = 0;
    for (unsigned j = 0; j < occupied; j++) {
        void *handle = (void *)(uintptr_t)(j + 1);
        for (unsigned i = 0; i < n; i++) {
            if (cells[i].easy != handle) continue;
            assert(atomic_load_explicit(&cells[i].state, memory_order_acquire) == ACTIVE);
            cells[i].easy = NULL;
            atomic_store_explicit(&cells[i].state, SEALED, memory_order_release);
            count++;
            break;
        }
    }
    for (unsigned i = 0; i < n; i++) {
        if (atomic_load_explicit(&cells[i].state, memory_order_acquire) == SEALED)
            atomic_store_explicit(&cells[i].state, FREE, memory_order_release);
    }
    for (unsigned j = 0; j < occupied; j++) {
        unsigned i;
        for (i = 0; i < n; i++) {
            uint32_t expected = FREE;
            if (!atomic_compare_exchange_strong_explicit(&cells[i].state, &expected, RESERVED,
                        memory_order_acq_rel, memory_order_acquire)) continue;
            cells[i].attempt_id++;
            cells[i].easy = (void *)(uintptr_t)(j + 1);
            atomic_store_explicit(&cells[i].state, ACTIVE, memory_order_release);
            break;
        }
        assert(i < n);
    }
    return count;
}

int main(int argc, char **argv) {
    if (argc != 6) return 2;
    unsigned n = (unsigned)strtoul(argv[1], NULL, 10);
    unsigned percent = (unsigned)strtoul(argv[2], NULL, 10);
    unsigned mode = (unsigned)strtoul(argv[3], NULL, 10);
    uint64_t iterations = strtoull(argv[4], NULL, 10);
    unsigned repeats = (unsigned)strtoul(argv[5], NULL, 10);
    assert(n && n <= 1000 && percent <= 100 && mode < 4 && iterations && repeats && repeats <= 20);
    unsigned occupied = (n * percent) / 100;
    struct Cell *cells = calloc(n, sizeof(*cells));
    assert(cells);
    for (unsigned i = 0; i < n; i++) atomic_init(&cells[i].state, FREE);
    for (unsigned j = 0; j < occupied; j++) {
        unsigned i = mode == 3 ? j : (unsigned)(((uint64_t)j * n) / occupied);
        atomic_store(&cells[i].state, ACTIVE);
        cells[i].easy = (void *)(uintptr_t)(i + 1);
        cells[i].kind = 1;
    }
    uint64_t (*run)(struct Cell *, unsigned, unsigned) =
        mode == 0 ? state_scan : mode == 1 ? dispatch_scan : mode == 2 ? completion_lookup : completion_reuse;
    for (unsigned i = 0; i < 100; i++) sink += run(cells, n, occupied);
    printf("{\"capacity\":%u,\"requested_occupancy_percent\":%u,\"occupied\":%u,\"stride_bytes\":%zu,\"mode\":%u,\"iterations\":%" PRIu64 ",\"elapsed_ns\":[", n, percent, occupied, sizeof(*cells), mode, iterations);
    uint64_t total_checksum = 0;
    for (unsigned r = 0; r < repeats; r++) {
        uint64_t checksum = 0, start = now_ns();
        for (uint64_t i = 0; i < iterations; i++) checksum += run(cells, n, occupied);
        uint64_t elapsed = now_ns() - start;
        assert(checksum == iterations * occupied);
        total_checksum += checksum;
        sink = checksum;
        printf("%s%" PRIu64, r ? "," : "", elapsed);
    }
    assert(state_scan(cells, n, occupied) == occupied);
    uint64_t generations = 0;
    for (unsigned i = 0; i < n; i++) generations += cells[i].attempt_id;
    assert(generations == (mode == 3 ? (100 + iterations * repeats) * occupied : 0));
    printf("],\"checksum\":%" PRIu64 ",\"reuse_generation_sum\":%" PRIu64 "}\n", total_checksum, generations);
    free(cells);
    return 0;
}
