/* Synthetic empty-table scheduler CPU probe; not a whole-runtime idle baseline. */
#include <assert.h>
#include <errno.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

struct Cell { _Atomic uint32_t state; unsigned char other_metadata[124]; };
_Static_assert(sizeof(struct Cell) == 128, "Preserve PhysicalCustody stride");
struct Wake {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    int finish;
};

static uint64_t clock_ns(clockid_t id) {
    struct timespec t;
    assert(clock_gettime(id, &t) == 0);
    return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}

static void *wake_after_one_second(void *arg) {
    struct Wake *wake = arg;
    struct timespec delay = {.tv_sec = 1, .tv_nsec = 0};
    while (nanosleep(&delay, &delay) != 0) assert(errno == EINTR);
    assert(pthread_mutex_lock(&wake->mutex) == 0);
    wake->finish = 1;
    assert(pthread_cond_signal(&wake->condition) == 0);
    assert(pthread_mutex_unlock(&wake->mutex) == 0);
    return NULL;
}

__attribute__((noinline)) static uint64_t scan(struct Cell *cells, unsigned capacity) {
    __asm__ volatile("" ::: "memory");
    uint64_t count = 0;
    for (unsigned i = 0; i < capacity; i++)
        count += atomic_load_explicit(&cells[i].state, memory_order_acquire) != 0;
    return count;
}

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    unsigned capacity = (unsigned)strtoul(argv[1], NULL, 10);
    int polling = atoi(argv[2]);
    assert((capacity == 100 || capacity == 1000) && (polling == 0 || polling == 1));
    struct Cell *cells = calloc(capacity, sizeof(*cells));
    assert(cells);
    for (unsigned i = 0; i < capacity; i++) atomic_init(&cells[i].state, 0);
    struct Wake wake = {.mutex = PTHREAD_MUTEX_INITIALIZER,
                        .condition = PTHREAD_COND_INITIALIZER, .finish = 0};
    pthread_t waker;
    uint64_t scans = 0, timeouts = 0, returns = 0, checksum = 0;
    uint64_t started_cpu = clock_ns(CLOCK_PROCESS_CPUTIME_ID);
    uint64_t started_wall = clock_ns(CLOCK_MONOTONIC);
    assert(pthread_create(&waker, NULL, wake_after_one_second, &wake) == 0);
    assert(pthread_mutex_lock(&wake.mutex) == 0);
    while (!wake.finish) {
        int result;
        if (polling) {
            /* macOS condition timed waits use absolute CLOCK_REALTIME deadlines. */
            uint64_t deadline = clock_ns(CLOCK_REALTIME) + 5000000;
            struct timespec until = {.tv_sec = (time_t)(deadline / 1000000000),
                                     .tv_nsec = (long)(deadline % 1000000000)};
            result = pthread_cond_timedwait(&wake.condition, &wake.mutex, &until);
        } else {
            result = pthread_cond_wait(&wake.condition, &wake.mutex);
        }
        assert(result == 0 || result == ETIMEDOUT);
        returns++;
        timeouts += result == ETIMEDOUT;
        checksum += scan(cells, capacity);
        scans++;
    }
    assert(pthread_mutex_unlock(&wake.mutex) == 0);
    assert(pthread_join(waker, NULL) == 0);
    uint64_t elapsed_wall = clock_ns(CLOCK_MONOTONIC) - started_wall;
    uint64_t elapsed_cpu = clock_ns(CLOCK_PROCESS_CPUTIME_ID) - started_cpu;
    assert(scans == returns && checksum == 0);
    assert(polling || timeouts == 0);
    assert(pthread_cond_destroy(&wake.condition) == 0);
    assert(pthread_mutex_destroy(&wake.mutex) == 0);
    printf("{\"capacity\":%u,\"stride_bytes\":%zu,\"poll_timeout_ms\":%u,"
           "\"wall_ns\":%" PRIu64 ",\"process_cpu_ns\":%" PRIu64 ","
           "\"wait_returns\":%" PRIu64 ",\"timeout_returns\":%" PRIu64 ","
           "\"external_signals\":1,\"scan_count\":%" PRIu64 ",\"checksum\":%" PRIu64 "}\n",
           capacity, sizeof(*cells), polling ? 5 : 0, elapsed_wall, elapsed_cpu,
           returns, timeouts, scans, checksum);
    free(cells);
    return 0;
}
