#include "onepage_string_reader.h"
#include "allocation_tracker.h"
#include <stdio.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>
#include <limits.h>
#include <sys/resource.h>
#ifdef __APPLE__
#include <mach/mach.h>
#endif

typedef struct {
    int fd, staged, mutate;
    uint64_t size, position, bytes_read;
    size_t calls, read_calls, fail_read_at;
    uint8_t *workspace, *whole_input;
    size_t window_size;
    const char *failure;
} Decoder;
static Decoder decoder;
static uint64_t footprint_peak;
static size_t armed_engine_failure, armed_native_failure;
static int arm_once;
static size_t decode_attempts;
static JSValue join_intrinsic;

static uint64_t footprint(void) {
#ifdef __APPLE__
    struct task_vm_info t;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&t, &count) != KERN_SUCCESS) abort();
    return t.phys_footprint;
#else
    return 0;
#endif
}
static void report(JSRuntime *rt, const char *phase) {
    uint64_t physical = footprint();
    if (physical > footprint_peak) footprint_peak = physical;
    JSMemoryUsage usage = {0};
    if (rt) JS_ComputeMemoryUsage(rt, &usage);
    struct rusage cpu;
    getrusage(RUSAGE_SELF, &cpu);
    printf("{\"phase\":\"%s\",\"engine_live\":%zu,\"native_live\":%zu,"
           "\"engine_requested\":%zu,\"native_requested\":%zu,"
           "\"engine_peak\":%zu,\"native_peak\":%zu,\"overlap_peak\":%zu,"
           "\"decode_overlap_peak\":%zu,\"decode_engine_peak\":%zu,\"decode_native_peak\":%zu,"
           "\"engine_accounted\":%lld,\"js_used_estimate\":%lld,"
           "\"physical_footprint\":%llu,\"sampled_physical_peak\":%llu,"
           "\"maxrss_raw\":%ld,\"cpu_user_us\":%lld,\"cpu_system_us\":%lld,"
           "\"read_bytes\":%llu,\"read_calls\":%zu,\"decode_calls\":%zu,"
           "\"engine_injected_failures\":%zu,\"engine_attempts\":%zu,\"native_attempts\":%zu,\"decode_attempts\":%zu,\"failure\":\"%s\"}\n",
           phase, engine.live, native.live, engine.requested, native.requested,
           engine.peak, native.peak, overlap_peak, decode_peak, decode_engine_peak, decode_native_peak,
           (long long)usage.malloc_size, (long long)usage.memory_used_size,
           (unsigned long long)physical, (unsigned long long)footprint_peak, cpu.ru_maxrss,
           (long long)cpu.ru_utime.tv_sec * 1000000 + cpu.ru_utime.tv_usec,
           (long long)cpu.ru_stime.tv_sec * 1000000 + cpu.ru_stime.tv_usec,
           (unsigned long long)decoder.bytes_read, decoder.read_calls, decoder.calls,
           engine.injected_failures, engine.attempts, native.attempts, decode_attempts, decoder.failure);
    fflush(stdout);
}

static int source_read(void *opaque, uint64_t offset, uint8_t *out, size_t length) {
    Decoder *d = opaque;
    d->read_calls++;
    if (d->fail_read_at && d->read_calls == d->fail_read_at) {
        d->failure = "injected_read_failure";
        return -1;
    }
    if (offset > d->size || length > d->size - offset) {
        d->failure = "invalid_range";
        return -1;
    }
    if (d->whole_input) { memcpy(out, d->whole_input + offset, length); return 0; }
    while (length) {
        ssize_t n = pread(d->fd, out, length, (off_t)offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { d->failure = "short_read"; return -1; }
        d->bytes_read += (uint64_t)n;
        out += n; offset += (uint64_t)n; length -= (size_t)n;
    }
    return 0;
}
static int take(Decoder *d, uint8_t *out, size_t length) {
    if (source_read(d, d->position, out, length)) return -1;
    d->position += length;
    return 0;
}
static uint64_t little(const uint8_t *p, size_t size) {
    uint64_t result = 0;
    for (size_t i = 0; i < size; i++) result |= (uint64_t)p[i] << (8 * i);
    return result;
}
typedef struct { Decoder *decoder; uint64_t base; unsigned starts; } StringSource;
static int string_read(void *opaque, uint64_t offset, uint8_t *out, size_t length) {
    StringSource *s = opaque;
    int result = source_read(s->decoder, s->base + offset, out, length);
    if (!result && offset == 0 && ++s->starts == 2 && s->decoder->mutate && length == 2) {
        /* Fault injection: violate source immutability after the counting pass. */
        out[0] = 0xc4; out[1] = 0x80;
    }
    return result;
}
static JSValue decode_string(JSContext *ctx, Decoder *d) {
    uint8_t header[8];
    if (take(d, header, sizeof(header))) return JS_ThrowTypeError(ctx, "missing string length");
    uint64_t length = little(header, sizeof(header));
    if (length > d->size - d->position) {
        d->failure = "invalid_range";
        return JS_ThrowRangeError(ctx, "string range");
    }
    StringSource source = {d, d->position};
    OPStringStatus status;
    JSValue value = d->staged == 2 ?
        OP_NewStringUTF8Public(ctx, length, string_read, &source,
                              d->workspace, d->window_size, &status, join_intrinsic) :
        OP_NewStringUTF8Reader(ctx, length, string_read, &source,
                              d->workspace, d->window_size, &status);
    d->position += length;
    if (status == OP_STRING_INVALID_UTF8) d->failure = "invalid_utf8";
    if (status == OP_STRING_ENGINE_MEMORY) d->failure = "engine_exhaustion";
    if (status == OP_STRING_UNREPRESENTABLE) d->failure = "unrepresentable";
    if (status == OP_STRING_INPUT_CHANGED) d->failure = "input_changed";
    return value;
}
static int define_index(JSContext *ctx, JSValue array, uint32_t index, JSValue item) {
#ifdef OP_NEGATIVE_SET
    return JS_SetPropertyUint32(ctx, array, index, item);
#else
    /* Populate data without invoking author-installed prototype setters. */
    return JS_DefinePropertyValueUint32(ctx, array, index, item, JS_PROP_C_W_E);
#endif
}
static JSValue decode_value(JSContext *ctx, Decoder *d, unsigned depth) {
    if (depth > 64) { d->failure = "prototype_depth"; return JS_ThrowRangeError(ctx, "prototype depth"); }
    uint8_t header[8];
    if (take(d, header, 1)) return JS_ThrowTypeError(ctx, "missing tag");
    unsigned tag = header[0];
    if (tag == 0) return JS_NULL;
    if (tag == 1) return JS_FALSE;
    if (tag == 2) return JS_TRUE;
    if (tag == 3) {
        if (take(d, header, 8)) return JS_ThrowTypeError(ctx, "missing number");
        uint64_t bits = little(header, 8); double number;
        memcpy(&number, &bits, sizeof(number));
        if (!isfinite(number)) { d->failure = "invalid_number"; return JS_ThrowTypeError(ctx, "nonfinite number"); }
        return JS_NewFloat64(ctx, number == 0 ? 0 : number);
    }
    if (tag == 4) return decode_string(ctx, d);
    if (tag != 5 && tag != 6) { d->failure = "invalid_tag"; return JS_ThrowTypeError(ctx, "tag"); }
    if (take(d, header, 4)) return JS_ThrowTypeError(ctx, "missing count");
    uint64_t count = little(header, 4);
    JSValue result = tag == 5 ? JS_NewArray(ctx) : JS_NewObject(ctx);
    if (JS_IsException(result)) goto engine_error;
    for (uint64_t i = 0; i < count; i++) {
        JSAtom atom = JS_ATOM_NULL;
        if (tag == 6) {
            JSValue key = decode_string(ctx, d);
            if (JS_IsException(key)) goto fail;
            atom = JS_ValueToAtom(ctx, key);
            JS_FreeValue(ctx, key);
            if (atom == JS_ATOM_NULL) goto engine_error;
            int exists = JS_GetOwnProperty(ctx, NULL, result, atom);
            if (exists != 0) {
                JS_FreeAtom(ctx, atom);
                if (exists < 0) goto engine_error;
                d->failure = "duplicate_key";
                JS_ThrowTypeError(ctx, "duplicate key");
                goto fail;
            }
        }
        JSValue item = decode_value(ctx, d, depth + 1);
        if (JS_IsException(item)) { JS_FreeAtom(ctx, atom); goto fail; }
        int status = tag == 5 ? define_index(ctx, result, (uint32_t)i, item) :
            JS_DefinePropertyValue(ctx, result, atom, item, JS_PROP_C_W_E);
        JS_FreeAtom(ctx, atom);
        if (status < 0) goto engine_error;
    }
    return result;
engine_error:
    d->failure = "engine_exhaustion";
    /* The pinned atom API can return NULL without installing an exception. */
    JS_ThrowOutOfMemory(ctx);
fail:
    JS_FreeValue(ctx, result);
    return JS_EXCEPTION;
}
static JSValue lookup(JSContext *ctx, JSValueConst this_value, int argc, JSValueConst *argv) {
    (void)this_value; (void)argc; (void)argv;
    Decoder *d = &decoder;
    d->calls++;
    if (!arm_once++) {
        engine.attempts = native.attempts = 0;
        engine.fail_at = armed_engine_failure;
        native.fail_at = armed_native_failure;
    }
    in_decode = 1;
    allocation_sample();
    d->position = 0;
    d->workspace = tracked_malloc(&native, d->window_size);
    JSValue value = JS_UNDEFINED;
    if (!d->workspace) { d->failure = "native_exhaustion"; JS_ThrowOutOfMemory(ctx); goto fail; }
    if (d->staged == 1) {
        uint8_t *input = tracked_malloc(&native, (size_t)d->size);
        if (!input) { d->failure = "native_exhaustion"; JS_ThrowOutOfMemory(ctx); goto fail; }
        /* Set whole_input only after the file read, so source_read cannot read
         * uninitialized staging. Capture failures retain one cleanup owner. */
        if (source_read(d, 0, input, (size_t)d->size)) { tracked_free(&native, input); JS_ThrowTypeError(ctx, "staging"); goto fail; }
        d->whole_input = input;
    }
    value = decode_value(ctx, d, 0);
    if (JS_IsException(value)) goto fail;
    if (d->position != d->size) {
        d->failure = "trailing_bytes";
        JS_ThrowTypeError(ctx, "trailing bytes");
        goto fail;
    }
    report(JS_GetRuntime(ctx), "decoded_before_scratch_release");
    tracked_free(&native, d->whole_input); d->whole_input = NULL;
    tracked_free(&native, d->workspace); d->workspace = NULL;
    JSValue promise = JS_NewSettledPromise(ctx, false, value);
    JS_FreeValue(ctx, value);
    if (JS_IsException(promise)) d->failure = "engine_exhaustion";
    decode_attempts = engine.attempts;
    in_decode = 0;
    engine.fail_at = native.fail_at = 0;
    return promise;
fail:
    JS_FreeValue(ctx, value);
    tracked_free(&native, d->whole_input); d->whole_input = NULL;
    tracked_free(&native, d->workspace); d->workspace = NULL;
    decode_attempts = engine.attempts;
    in_decode = 0;
    engine.fail_at = native.fail_at = 0;
    return JS_EXCEPTION;
}
static JSValue mark(JSContext *ctx, JSValueConst this_value, int argc, JSValueConst *argv) {
    (void)this_value; (void)argc;
    const char *label = JS_ToCString(ctx, argv[0]);
    if (!label) return JS_EXCEPTION;
    report(JS_GetRuntime(ctx), label);
    JS_FreeCString(ctx, label);
    return JS_UNDEFINED;
}
int main(int argc, char **argv) {
    if (argc != 11) return 2;
    decoder = (Decoder){.fd = atoi(argv[1]), .size = strtoull(argv[2], NULL, 10),
        .staged = atoi(argv[3]), .mutate = atoi(argv[8]), .window_size = strtoul(argv[4], NULL, 10),
        .fail_read_at = strtoul(argv[7], NULL, 10), .failure = "none"};
    armed_engine_failure = strtoul(argv[5], NULL, 10);
    armed_native_failure = strtoul(argv[6], NULL, 10);
    if (!decoder.window_size || decoder.size > SIZE_MAX || decoder.size > INT64_MAX) return 2;
    /* Sanitizer-only diagnostic profile; production-policy measurements use 1/2. */
    int diagnostic = atoi(argv[9]);
    assert(diagnostic == 0 || diagnostic == 1);
    struct rlimit core = {0,0}, cpu = {diagnostic ? 10 : 1, diagnostic ? 11 : 2};
    if (setrlimit(RLIMIT_CORE, &core) || setrlimit(RLIMIT_CPU, &cpu)) return 3;
    JSMallocFunctions allocator = {engine_calloc, engine_malloc, engine_free, engine_realloc, engine_usable};
    JSRuntime *rt = JS_NewRuntime2(&allocator, NULL);
    assert(rt);
    JS_SetMemoryLimit(rt, 16 * 1024 * 1024);
    JS_SetMaxStackSize(rt, 512 * 1024);
    JSContext *ctx = JS_NewContext(rt);
    assert(ctx);
    JSValue array = JS_NewArray(ctx);
    assert(!JS_IsException(array));
    join_intrinsic = JS_GetPropertyStr(ctx, array, "join");
    JS_FreeValue(ctx, array);
    assert(!JS_IsException(join_intrinsic));
    JSValue global = JS_GetGlobalObject(ctx);
    assert(JS_SetPropertyStr(ctx, global, "lookup", JS_NewCFunction(ctx, lookup, "lookup", 0)) >= 0);
    assert(JS_SetPropertyStr(ctx, global, "mark", JS_NewCFunction(ctx, mark, "mark", 1)) >= 0);
    JS_FreeValue(ctx, global);
    report(rt, "cold");
    JSValue root = JS_Eval(ctx, argv[10], strlen(argv[10]), "oracle", JS_EVAL_TYPE_GLOBAL);
    int failed = JS_IsException(root), job_status = 0;
    JSContext *job;
    while (!failed && (job_status = JS_ExecutePendingJob(rt, &job)) > 0) {}
    if (job_status < 0) failed = 1;
    if (!failed && (!JS_IsObject(root) || JS_PromiseState(ctx, root) != JS_PROMISE_FULFILLED)) failed = 1;
    if (failed && !strcmp(decoder.failure, "none")) decoder.failure = "js_oracle_or_job";
    report(rt, failed ? "failed" : "completed");
    JS_FreeValue(ctx, root);
    JSValue exception = JS_GetException(ctx);
    JS_FreeValue(ctx, exception);
    JS_RunGC(rt);
    report(rt, "released_idle");
    JS_FreeValue(ctx, join_intrinsic);
    JS_FreeContext(ctx); JS_FreeRuntime(rt);
    report(NULL, "runtime_freed");
    close(decoder.fd);
    return failed ? 10 : 0;
}
