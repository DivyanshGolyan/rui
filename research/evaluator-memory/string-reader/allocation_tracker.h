/* Backing allocations, including overlapping old/new blocks during forced
 * moving realloc. Every comparison uses the same allocator. No hidden ledger. */
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include <stdint.h>
#include <assert.h>
#ifdef __APPLE__
#include <malloc/malloc.h>
#else
#include <malloc.h>
#endif

typedef union {
    struct { size_t requested, usable; } size;
    max_align_t alignment;
} AllocationHeader;
typedef struct {
    size_t requested, live, peak, attempts, fail_at, injected_failures;
} Population;
static Population engine, native;
static size_t overlap_peak, decode_peak, decode_native_peak, decode_engine_peak;
static int in_decode;
static size_t block_size(void *p) {
#ifdef __APPLE__
    return malloc_size(p);
#else
    return malloc_usable_size(p);
#endif
}
static void allocation_sample(void) {
    size_t total = engine.live + native.live;
    if (total > overlap_peak) overlap_peak = total;
    if (engine.live > engine.peak) engine.peak = engine.live;
    if (native.live > native.peak) native.peak = native.live;
    if (in_decode) {
        if (total > decode_peak) decode_peak = total;
        if (native.live > decode_native_peak) decode_native_peak = native.live;
        if (engine.live > decode_engine_peak) decode_engine_peak = engine.live;
    }
}
static void *tracked_malloc(Population *owner, size_t size) {
    owner->attempts++;
    if (owner->fail_at && owner->attempts == owner->fail_at) {
        owner->injected_failures++;
        return NULL;
    }
    if (owner == &native && (size > 8 * 1024 * 1024 ||
        owner->requested > 8 * 1024 * 1024 - size)) return NULL;
    if (size > SIZE_MAX - sizeof(AllocationHeader)) return NULL;
    AllocationHeader *h = malloc(sizeof(*h) + size);
    if (!h) return NULL;
    h->size.requested = size;
    h->size.usable = block_size(h);
    owner->live += h->size.usable;
    owner->requested += size;
    allocation_sample();
    return h + 1;
}
static void tracked_free(Population *owner, void *ptr) {
    if (!ptr) return;
    AllocationHeader *h = (AllocationHeader *)ptr - 1;
    owner->live -= h->size.usable;
    owner->requested -= h->size.requested;
    free(h);
}
static void *engine_malloc(void *opaque, size_t size) {
    (void)opaque;
    return tracked_malloc(&engine, size);
}
static void engine_free(void *opaque, void *ptr) {
    (void)opaque;
    tracked_free(&engine, ptr);
}
static void *engine_calloc(void *opaque, size_t count, size_t size) {
    if (size && count > SIZE_MAX / size) return NULL;
    void *p = engine_malloc(opaque, count * size);
    if (p) memset(p, 0, count * size);
    return p;
}
static size_t engine_usable(const void *ptr) {
    if (!ptr) return 0;
    const AllocationHeader *h = (const AllocationHeader *)ptr - 1;
    return h->size.usable - sizeof(*h);
}
static void *engine_realloc(void *opaque, void *ptr, size_t size) {
    if (!size) { engine_free(opaque, ptr); return NULL; }
    void *next = engine_malloc(opaque, size);
    if (!next) return NULL;
    if (ptr) {
        AllocationHeader *old = (AllocationHeader *)ptr - 1;
        size_t length = old->size.requested < size ? old->size.requested : size;
        memcpy(next, ptr, length);
        engine_free(opaque, ptr);
    }
    return next;
}
