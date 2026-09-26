/* Disposable QuickJS worker. This executable has no filesystem, process or
 * network intrinsics. It is invoked only with prepared stdin and captured
 * stdout by the lifecycle owner; neither fd is an authority in JavaScript. */
#include "quickjs.h"
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif

static int write_all(const void *data, size_t size) {
    const unsigned char *p = data;
    while (size) {
        ssize_t n = write(STDOUT_FILENO, p, size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n;
        size -= (size_t)n;
    }
    return 0;
}

/* Copy only strict data. JSON.stringify on an author object can invoke
 * getters and toJSON, so it must see only our own null-prototype values. */
static JSValue strict_data(JSContext *ctx, JSValueConst value,
                           JSValueConst *ancestors, unsigned depth) {
    if (JS_IsNull(value) || JS_IsBool(value) || JS_IsString(value))
        return JS_DupValue(ctx, value);
    if (JS_IsNumber(value)) {
        double number;
        if (JS_ToFloat64(ctx, &number, value) || !isfinite(number))
            return JS_ThrowTypeError(ctx, "nonfinite number");
        return JS_DupValue(ctx, value);
    }
    if (!JS_IsObject(value) || JS_IsProxy(value) || depth >= 128)
        return JS_ThrowTypeError(ctx, "unsupported data value");
    for (unsigned i = 0; i < depth; i++) {
        if (JS_IsStrictEqual(ctx, ancestors[i], value))
            return JS_ThrowTypeError(ctx, "cyclic data");
    }
    if (JS_IsFunction(ctx, value))
        return JS_ThrowTypeError(ctx, "function is not data");
    JSValue original_proto = JS_GetPrototype(ctx, value);
    JSValue ordinary = JS_IsArray(value) ? JS_NewArray(ctx) : JS_NewObject(ctx);
    if (JS_IsException(original_proto) || JS_IsException(ordinary)) {
        JS_FreeValue(ctx, original_proto);
        JS_FreeValue(ctx, ordinary);
        return JS_EXCEPTION;
    }
    JSValue standard_proto = JS_GetPrototype(ctx, ordinary);
    int valid_proto = JS_IsNull(original_proto) ||
        JS_IsStrictEqual(ctx, original_proto, standard_proto);
    JS_FreeValue(ctx, original_proto);
    JS_FreeValue(ctx, standard_proto);
    if (!valid_proto || JS_IsException(ordinary) ||
        JS_SetPrototype(ctx, ordinary, JS_NULL) < 0) {
        JS_FreeValue(ctx, ordinary);
        return JS_ThrowTypeError(ctx, "unsupported prototype");
    }
    JSPropertyEnum *keys = NULL;
    uint32_t count = 0;
    if (JS_GetOwnPropertyNames(ctx, &keys, &count, value,
                               JS_GPN_STRING_MASK | JS_GPN_SYMBOL_MASK | JS_GPN_SET_ENUM) < 0) {
        JS_FreeValue(ctx, ordinary);
        return JS_EXCEPTION;
    }
    ancestors[depth] = value;
    int failed = 0;
    int64_t array_length = 0;
    if (JS_IsArray(value) &&
        (JS_GetLength(ctx, value, &array_length) || array_length < 0)) failed = 1;
    for (uint32_t i = 0; i < count && !failed; i++) {
        JSValue key = JS_AtomToValue(ctx, keys[i].atom);
        if (!JS_IsString(key)) failed = 1;
        size_t name_length = 0;
        const char *name = !failed ? JS_ToCStringLen(ctx, &name_length, key) : NULL;
        if (!failed && !name) failed = 1;
        if (!failed && !keys[i].is_enumerable &&
            !(JS_IsArray(value) && name_length == 6 &&
              memcmp(name, "length", 6) == 0)) failed = 1;
        if (!failed && JS_IsArray(value) && keys[i].is_enumerable) {
            uint64_t index = 0;
            if (!name_length || (name_length > 1 && name[0] == '0')) failed = 1;
            for (size_t j = 0; j < name_length && !failed; j++) {
                if (name[j] < '0' || name[j] > '9') failed = 1;
                else index = index * 10 + (unsigned)(name[j] - '0');
                if (index >= (uint64_t)array_length) failed = 1;
            }
        }
        if (name) JS_FreeCString(ctx, name);
        JS_FreeValue(ctx, key);
        if (failed || !keys[i].is_enumerable) continue;
        JSPropertyDescriptor property;
        if (JS_GetOwnProperty(ctx, &property, value, keys[i].atom) != 1) {
            failed = 1;
            continue;
        }
        if ((property.flags & JS_PROP_GETSET) ||
            JS_IsUndefined(property.value)) {
            failed = 1;
        } else {
            JSValue item = strict_data(ctx, property.value, ancestors, depth + 1);
            if (JS_IsException(item)) failed = 1;
            else if (JS_DefinePropertyValue(ctx, ordinary, keys[i].atom,
                                            item, JS_PROP_C_W_E) < 0) failed = 1;
        }
        JS_FreeValue(ctx, property.value);
        JS_FreeValue(ctx, property.getter);
        JS_FreeValue(ctx, property.setter);
    }
    /* JSON.stringify would silently turn sparse array entries into null. */
    for (int64_t i = 0; i < array_length && !failed; i++) {
        JSAtom atom = JS_NewAtomUInt32(ctx, (uint32_t)i);
        JSPropertyDescriptor property;
        if (atom == JS_ATOM_NULL) { failed = 1; break; }
        int found = JS_GetOwnProperty(ctx, &property, value, atom);
        JS_FreeAtom(ctx, atom);
        if (found != 1) { failed = 1; break; }
        if (!(property.flags & JS_PROP_ENUMERABLE)) failed = 1;
        JS_FreeValue(ctx, property.value);
        JS_FreeValue(ctx, property.getter);
        JS_FreeValue(ctx, property.setter);
    }
    JS_FreePropertyEnum(ctx, keys, count);
    if (failed) {
        JS_FreeValue(ctx, ordinary);
        return JS_ThrowTypeError(ctx, "non-data property");
    }
    return ordinary;
}

int main(int argc, char **argv) {
    if (argc != 2 || (strcmp(argv[1], "check") && strcmp(argv[1], "run"))) return 2;
    struct rlimit core = {0, 0}, cpu = {1, 2}, stack = {1024 * 1024, 1024 * 1024};
    if (setrlimit(RLIMIT_CORE, &core) || setrlimit(RLIMIT_CPU, &cpu) ||
        setrlimit(RLIMIT_STACK, &stack)) return 3;
#ifdef __linux__
    if (prctl(PR_SET_DUMPABLE, 0) != 0) return 3;
#endif
    /* Source compilation needs contiguous storage. This temporary native
     * allocation is separate from the 16 MiB engine heap; failure is not a
     * successful partial compilation. */
    const size_t source_limit = 8 * 1024 * 1024;
    size_t capacity = 4096;
    char *source = malloc(capacity + 1);
    if (!source) return 4;
    size_t size = 0;
    for (;;) {
        if (size == capacity) {
            if (capacity == source_limit) {
                char extra;
                ssize_t n;
                do { n = read(STDIN_FILENO, &extra, 1); } while (n < 0 && errno == EINTR);
                if (n != 0) return 4;
                break;
            }
            capacity *= 2;
            char *grown = realloc(source, capacity + 1);
            if (!grown) return 4;
            source = grown;
        }
        ssize_t n = read(STDIN_FILENO, source + size, capacity - size);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) return 4;
        if (!n) break;
        size += (size_t)n;
    }
    source[size] = 0;
    JSRuntime *rt = JS_NewRuntime();
    if (!rt) return 4;
    JS_SetMemoryLimit(rt, 16 * 1024 * 1024);
    JS_SetMaxStackSize(rt, 512 * 1024);
    JSContext *ctx = JS_NewContextRaw(rt);
    if (!ctx || JS_AddIntrinsicBaseObjects(ctx) || JS_AddIntrinsicEval(ctx) ||
        JS_AddIntrinsicPromise(ctx) ||
        JS_AddIntrinsicJSON(ctx)) return 4;
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue math = JS_GetPropertyStr(ctx, global, "Math");
    JSAtom random = JS_NewAtom(ctx, "random");
    if (JS_IsException(math) || random == JS_ATOM_NULL ||
        JS_DeleteProperty(ctx, math, random, 0) <= 0) return 4;
    JS_FreeAtom(ctx, random);
    JSAtom eval = JS_NewAtom(ctx, "eval");
    if (eval == JS_ATOM_NULL || JS_DeleteProperty(ctx, global, eval, 0) <= 0) return 4;
    JS_FreeAtom(ctx, eval);
    JS_FreeValue(ctx, math);
    JS_FreeValue(ctx, global);

    int check = !strcmp(argv[1], "check");
    JSValue root = JS_Eval(ctx, source, size, "workflow.js",
        JS_EVAL_TYPE_GLOBAL | (check ? JS_EVAL_FLAG_COMPILE_ONLY : 0));
    free(source);
    if (JS_IsException(root)) return 5;
    if (check) {
        JS_FreeValue(ctx, root);
        JS_FreeContext(ctx);
        JS_FreeRuntime(rt);
        return 0;
    }
    JSContext *job = NULL;
    int pending;
    while ((pending = JS_ExecutePendingJob(rt, &job)) > 0) {}
    if (pending < 0) return 5;
    if (JS_IsPromise(root)) {
        if (JS_PromiseState(ctx, root) != JS_PROMISE_FULFILLED) return 5;
        JSValue value = JS_PromiseResult(ctx, root);
        JS_FreeValue(ctx, root);
        root = value;
    }
    JSValueConst ancestors[128];
    JSValue data = strict_data(ctx, root, ancestors, 0);
    JS_FreeValue(ctx, root);
    if (JS_IsException(data)) return 5;
    JSValue json = JS_JSONStringify(ctx, data, JS_UNDEFINED, JS_UNDEFINED);
    JS_FreeValue(ctx, data);
    if (JS_IsException(json) || JS_IsUndefined(json)) return 5;
    size_t length;
    const char *text = JS_ToCStringLen(ctx, &length, json);
    if (!text) return 5;
    /* One little-endian length followed by precisely that many UTF-8 bytes.
     * The parent must validate the exit and EOF as well as this frame. */
    unsigned char header[8];
    for (unsigned i = 0; i < 8; i++) header[i] = (uint8_t)((uint64_t)length >> (8 * i));
    int status = write_all(header, sizeof(header)) || write_all(text, length);
    JS_FreeCString(ctx, text);
    JS_FreeValue(ctx, json);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    return status ? 6 : 0;
}
