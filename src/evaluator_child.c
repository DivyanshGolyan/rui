/* Disposable QuickJS worker. This executable has no filesystem, process or
 * network intrinsics. It is invoked only with prepared stdin and captured
 * stdout by the lifecycle owner; neither fd is an authority in JavaScript. */
#include "quickjs.h"
#include "evaluator_string_reader.h"
#include "evaluator_policy.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif

static int write_to(int fd, const void *data, size_t size) {
    const unsigned char *p = data;
    while (size) {
        ssize_t n = write(fd, p, size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n;
        size -= (size_t)n;
    }
    return 0;
}

static int write_all(const void *data, size_t size) {
    return write_to(STDOUT_FILENO, data, size);
}

static void report_compiler_error(JSContext *ctx) {
    JSValue exception = JS_GetException(ctx);
    JSValue stack = JS_GetPropertyStr(ctx, exception, "stack");
    size_t remaining = 4096;
    JSValueConst parts[2] = {exception, stack};
    for (unsigned i = 0; i < 2 && remaining; i++) {
        if (i && !JS_IsString(stack)) break;
        if (i) {
            (void)write_to(STDERR_FILENO, "\n", 1);
            remaining--;
        }
        size_t length = 0;
        const char *message = JS_ToCStringLen(ctx, &length, parts[i]);
        if (message) {
            size_t count = length < remaining ? length : remaining;
            (void)write_to(STDERR_FILENO, message, count);
            remaining -= count;
            JS_FreeCString(ctx, message);
        }
    }
    JS_FreeValue(ctx, stack);
    JS_FreeValue(ctx, exception);
}

enum { output_window_size = 16 * 1024 };

typedef struct {
    uint8_t bytes[output_window_size];
    size_t length;
} JsonOutput;

static int json_flush(JsonOutput *output) {
    if (!output->length) return 0;
    uint8_t header[4];
    uint32_t length = (uint32_t)output->length;
    for (unsigned i = 0; i < 4; i++) header[i] = (uint8_t)(length >> (8 * i));
    if (write_all(header, sizeof(header)) ||
        write_all(output->bytes, output->length)) return -1;
    output->length = 0;
    return 0;
}

static int json_write(JsonOutput *output, const void *data, size_t length) {
    const uint8_t *bytes = data;
    while (length) {
        size_t available = sizeof(output->bytes) - output->length;
        size_t count = length < available ? length : available;
        memcpy(output->bytes + output->length, bytes, count);
        output->length += count;
        bytes += count;
        length -= count;
        if (output->length == sizeof(output->bytes) && json_flush(output)) return -1;
    }
    return 0;
}

static int json_byte(JsonOutput *output, uint8_t byte) {
    return json_write(output, &byte, 1);
}

typedef struct {
    JsonOutput *output;
    uint16_t lead;
} JsonString;

static int json_scalar(JsonOutput *output, uint32_t scalar) {
    static const char hex[] = "0123456789abcdef";
    if (scalar == '"' || scalar == '\\') {
        uint8_t escaped[2] = {'\\', (uint8_t)scalar};
        return json_write(output, escaped, sizeof(escaped));
    }
    if (scalar < 0x20) {
        uint8_t escaped[6] = {'\\', 'u', '0', '0',
                              hex[scalar >> 4], hex[scalar & 15]};
        return json_write(output, escaped, sizeof(escaped));
    }
    uint8_t encoded[4];
    size_t count;
    if (scalar < 0x80) { encoded[0] = (uint8_t)scalar; count = 1; }
    else if (scalar < 0x800) {
        encoded[0] = 0xc0 | (uint8_t)(scalar >> 6);
        encoded[1] = 0x80 | (uint8_t)(scalar & 0x3f);
        count = 2;
    } else if (scalar < 0x10000) {
        encoded[0] = 0xe0 | (uint8_t)(scalar >> 12);
        encoded[1] = 0x80 | (uint8_t)((scalar >> 6) & 0x3f);
        encoded[2] = 0x80 | (uint8_t)(scalar & 0x3f);
        count = 3;
    } else {
        encoded[0] = 0xf0 | (uint8_t)(scalar >> 18);
        encoded[1] = 0x80 | (uint8_t)((scalar >> 12) & 0x3f);
        encoded[2] = 0x80 | (uint8_t)((scalar >> 6) & 0x3f);
        encoded[3] = 0x80 | (uint8_t)(scalar & 0x3f);
        count = 4;
    }
    return json_write(output, encoded, count);
}

static int json_string_units(void *opaque, const void *units,
                             size_t length, int wide) {
    JsonString *string = opaque;
    for (size_t i = 0; i < length; i++) {
        uint16_t unit = wide ? ((const uint16_t *)units)[i] :
                               ((const uint8_t *)units)[i];
        if (string->lead) {
            uint16_t lead = string->lead;
            string->lead = 0;
            if (unit >= 0xdc00 && unit <= 0xdfff) {
                uint32_t scalar = 0x10000 + (((uint32_t)lead - 0xd800) << 10) +
                                  ((uint32_t)unit - 0xdc00);
                if (json_scalar(string->output, scalar)) return -1;
                continue;
            }
            return -1;
        }
        if (unit >= 0xd800 && unit <= 0xdbff) string->lead = unit;
        else if (unit >= 0xdc00 && unit <= 0xdfff) return -1;
        else if (json_scalar(string->output, unit)) return -1;
    }
    return 0;
}

static int json_string(JsonOutput *output, JSValueConst value) {
    JsonString string = {output, 0};
    if (json_byte(output, '"') ||
        OP_VisitStringUnits(value, json_string_units, &string) ||
        string.lead ||
        json_byte(output, '"')) return -1;
    return 0;
}

static int serialize_json(JSContext *ctx, JsonOutput *output,
                          JSValueConst value, unsigned depth) {
    if (depth > 128) return -1;
    if (JS_IsNull(value)) return json_write(output, "null", 4);
    if (JS_IsBool(value)) return JS_ToBool(ctx, value) ?
        json_write(output, "true", 4) : json_write(output, "false", 5);
    if (JS_IsString(value)) return json_string(output, value);
    if (JS_IsNumber(value)) {
        size_t length;
        const char *number = JS_ToCStringLen(ctx, &length, value);
        if (!number) return -1;
        int failed = json_write(output, number, length);
        JS_FreeCString(ctx, number);
        return failed;
    }
    if (!JS_IsObject(value)) return -1;
    if (JS_IsArray(value)) {
        int64_t length;
        if (JS_GetLength(ctx, value, &length) || json_byte(output, '[')) return -1;
        for (int64_t i = 0; i < length; i++) {
            if (i && json_byte(output, ',')) return -1;
            JSValue item = JS_GetPropertyUint32(ctx, value, (uint32_t)i);
            if (JS_IsException(item)) return -1;
            int failed = serialize_json(ctx, output, item, depth + 1);
            JS_FreeValue(ctx, item);
            if (failed) return -1;
        }
        return json_byte(output, ']');
    }
    JSPropertyEnum *keys = NULL;
    uint32_t count = 0;
    if (JS_GetOwnPropertyNames(ctx, &keys, &count, value,
                              JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY) < 0) return -1;
    if (json_byte(output, '{')) {
        JS_FreePropertyEnum(ctx, keys, count);
        return -1;
    }
    int failed = 0;
    for (uint32_t i = 0; i < count && !failed; i++) {
        JSValue key = JS_AtomToValue(ctx, keys[i].atom);
        JSPropertyDescriptor property;
        if (JS_IsException(key) ||
            JS_GetOwnProperty(ctx, &property, value, keys[i].atom) != 1) {
            JS_FreeValue(ctx, key);
            failed = 1;
            break;
        }
        failed = (i && json_byte(output, ',')) || json_string(output, key) ||
                 json_byte(output, ':') ||
                 serialize_json(ctx, output, property.value, depth + 1);
        JS_FreeValue(ctx, key);
        JS_FreeValue(ctx, property.value);
        JS_FreeValue(ctx, property.getter);
        JS_FreeValue(ctx, property.setter);
    }
    JS_FreePropertyEnum(ctx, keys, count);
    return failed || json_byte(output, '}') ? -1 : 0;
}

static int descriptor_read(void *opaque, uint64_t offset,
                           uint8_t *dst, size_t length) {
    int fd = *(const int *)opaque;
    while (length) {
        if (offset > INT64_MAX) return -1;
        ssize_t n = pread(fd, dst, length, (off_t)offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        dst += n;
        length -= (size_t)n;
        offset += (size_t)n;
    }
    return 0;
}

typedef struct {
    int fd;
    uint64_t size;
    uint64_t position;
    uint8_t *workspace;
    size_t workspace_size;
} PreparedInput;

typedef struct {
    PreparedInput *input;
    uint64_t base;
} PreparedString;

static int prepared_take(PreparedInput *input, void *dst, size_t length) {
    if ((uint64_t)length > input->size - input->position ||
        descriptor_read(&input->fd, input->position, dst, length)) return -1;
    input->position += length;
    return 0;
}

static uint64_t little_endian(const uint8_t *bytes, size_t length) {
    uint64_t value = 0;
    for (size_t i = 0; i < length; i++) value |= (uint64_t)bytes[i] << (8 * i);
    return value;
}

static int prepared_string_read(void *opaque, uint64_t offset,
                                uint8_t *dst, size_t length) {
    PreparedString *string = opaque;
    if (offset > string->input->size - string->base ||
        (uint64_t)length > string->input->size - string->base - offset) return -1;
    return descriptor_read(&string->input->fd, string->base + offset, dst, length);
}

static JSValue decode_string(JSContext *ctx, PreparedInput *input) {
    uint8_t header[8];
    if (prepared_take(input, header, sizeof(header)))
        return JS_ThrowTypeError(ctx, "missing string length");
    uint64_t length = little_endian(header, sizeof(header));
    if (length > input->size - input->position)
        return JS_ThrowRangeError(ctx, "string range");
    PreparedString string = {input, input->position};
    OPStringStatus status;
    JSValue value = OP_NewStringUTF8Reader(ctx, length, prepared_string_read,
        &string, input->workspace, input->workspace_size, &status);
    input->position += length;
    return value;
}

static JSValue decode_value(JSContext *ctx, PreparedInput *input, unsigned depth) {
    if (depth > 64) return JS_ThrowRangeError(ctx, "prepared input depth");
    uint8_t bytes[8];
    if (prepared_take(input, bytes, 1)) return JS_ThrowTypeError(ctx, "missing tag");
    switch (bytes[0]) {
    case 0: return JS_NULL;
    case 1: return JS_FALSE;
    case 2: return JS_TRUE;
    case 3: {
        if (prepared_take(input, bytes, 8)) return JS_ThrowTypeError(ctx, "missing number");
        uint64_t bits = little_endian(bytes, 8);
        double number;
        memcpy(&number, &bits, sizeof(number));
        if (!isfinite(number)) return JS_ThrowTypeError(ctx, "nonfinite number");
        return JS_NewFloat64(ctx, number == 0 ? 0 : number);
    }
    case 4:
        return decode_string(ctx, input);
    case 5:
    case 6:
        break;
    default:
        return JS_ThrowTypeError(ctx, "invalid tag");
    }
    unsigned tag = bytes[0];
    if (prepared_take(input, bytes, 4)) return JS_ThrowTypeError(ctx, "missing count");
    uint64_t count = little_endian(bytes, 4);
    JSValue result = tag == 5 ? JS_NewArray(ctx) : JS_NewObject(ctx);
    if (JS_IsException(result)) return result;
    for (uint64_t i = 0; i < count; i++) {
        JSAtom atom = JS_ATOM_NULL;
        if (tag == 6) {
            JSValue key = decode_string(ctx, input);
            if (JS_IsException(key)) goto fail;
            atom = JS_ValueToAtom(ctx, key);
            JS_FreeValue(ctx, key);
            if (atom == JS_ATOM_NULL) goto engine_error;
            int exists = JS_GetOwnProperty(ctx, NULL, result, atom);
            if (exists != 0) {
                JS_FreeAtom(ctx, atom);
                if (exists < 0) goto fail;
                JS_ThrowTypeError(ctx, "duplicate key");
                goto fail;
            }
        }
        JSValue item = decode_value(ctx, input, depth + 1);
        if (JS_IsException(item)) {
            JS_FreeAtom(ctx, atom);
            goto fail;
        }
        int defined = tag == 5 ?
            JS_DefinePropertyValueUint32(ctx, result, (uint32_t)i, item, JS_PROP_C_W_E) :
            JS_DefinePropertyValue(ctx, result, atom, item, JS_PROP_C_W_E);
        JS_FreeAtom(ctx, atom);
        if (defined < 0) goto fail;
    }
    return result;
engine_error:
    JS_ThrowOutOfMemory(ctx);
fail:
    JS_FreeValue(ctx, result);
    return JS_EXCEPTION;
}

/* Validate before serialization, which reads only own data descriptors and
 * never calls getters or toJSON. Keep the original graph: copying a shared
 * subtree for each reference could exhaust the engine before streaming it. */
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
    int valid_class = JS_GetClassID(value) == JS_GetClassID(ordinary);
    int valid_proto = valid_class && (JS_IsNull(original_proto) ||
        JS_IsStrictEqual(ctx, original_proto, standard_proto));
    JS_FreeValue(ctx, original_proto);
    JS_FreeValue(ctx, standard_proto);
    JS_FreeValue(ctx, ordinary);
    if (!valid_proto) {
        return JS_ThrowTypeError(ctx, "unsupported prototype");
    }
    JSPropertyEnum *keys = NULL;
    uint32_t count = 0;
    if (JS_GetOwnPropertyNames(ctx, &keys, &count, value,
                               JS_GPN_STRING_MASK | JS_GPN_SYMBOL_MASK | JS_GPN_SET_ENUM) < 0) {
        return JS_EXCEPTION;
    }
    ancestors[depth] = value;
    int failed = 0;
    int64_t array_length = 0;
    uint64_t array_items = 0;
    JSAtom length_atom = JS_ATOM_NULL;
    if (JS_IsArray(value) &&
        (JS_GetLength(ctx, value, &array_length) || array_length < 0)) failed = 1;
    if (JS_IsArray(value) && !failed) {
        length_atom = JS_NewAtom(ctx, "length");
        if (length_atom == JS_ATOM_NULL) failed = 1;
    }
    for (uint32_t i = 0; i < count && !failed; i++) {
        JSValue key = JS_AtomToValue(ctx, keys[i].atom);
        if (!JS_IsString(key)) failed = 1;
        if (!failed && !keys[i].is_enumerable &&
            !(JS_IsArray(value) && keys[i].atom == length_atom)) failed = 1;
        if (!failed && JS_IsArray(value) && keys[i].is_enumerable) array_items++;
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
            else JS_FreeValue(ctx, item);
        }
        JS_FreeValue(ctx, property.value);
        JS_FreeValue(ctx, property.getter);
        JS_FreeValue(ctx, property.setter);
    }
    JS_FreeAtom(ctx, length_atom);
    if (JS_IsArray(value) && array_items != (uint64_t)array_length) failed = 1;
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
        return JS_ThrowTypeError(ctx, "non-data property");
    }
    return JS_DupValue(ctx, value);
}

int main(int argc, char **argv) {
    int prepared_check = argc == 2 && !strcmp(argv[1], "check-prepared");
    int prepared_run = argc == 2 && !strcmp(argv[1], "run-prepared");
    if (!prepared_check && !prepared_run) return 2;
    struct rlimit core = {0, 0}, cpu = {1, 2}, stack = {1024 * 1024, 1024 * 1024};
    if (setrlimit(RLIMIT_CORE, &core) || setrlimit(RLIMIT_CPU, &cpu) ||
        setrlimit(RLIMIT_STACK, &stack)) return 3;
#ifdef __linux__
    if (prctl(PR_SET_DUMPABLE, 0) != 0) return 3;
#endif
    /* The pin compiles from one contiguous native source buffer. Bound that
     * allocation, including its terminator, separately from the 16 MiB
     * engine heap; reject resource exhaustion before any author code runs. */
    const size_t native_source_budget = 64 * 1024 * 1024;
    struct stat source_stat;
    int source_fd = 3;
    int source_flags = fcntl(source_fd, F_GETFL);
    if (source_flags < 0 || (source_flags & O_ACCMODE) != O_RDONLY ||
        fstat(source_fd, &source_stat) || !S_ISREG(source_stat.st_mode) ||
        source_stat.st_size < 0 ||
        (uint64_t)source_stat.st_size >= native_source_budget) return 4;
    size_t size = (size_t)source_stat.st_size;
    char *source = malloc(size + 1);
    if (!source || descriptor_read(&source_fd, 0, (uint8_t *)source, size)) {
        free(source);
        return 4;
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
    JSAtom function = JS_NewAtom(ctx, "Function");
    if (function == JS_ATOM_NULL || JS_DeleteProperty(ctx, global, function, 0) <= 0) return 4;
    JS_FreeAtom(ctx, function);
    JSValue promise = JS_GetPropertyStr(ctx, global, "Promise");
    JSAtom race = JS_NewAtom(ctx, "race");
    JSAtom any = JS_NewAtom(ctx, "any");
    if (JS_IsException(promise) || race == JS_ATOM_NULL || any == JS_ATOM_NULL ||
        JS_DeleteProperty(ctx, promise, race, 0) <= 0 ||
        JS_DeleteProperty(ctx, promise, any, 0) <= 0) return 4;
    JS_FreeAtom(ctx, race);
    JS_FreeAtom(ctx, any);
    JS_FreeValue(ctx, promise);
    JS_FreeValue(ctx, math);
    JS_FreeValue(ctx, global);

    int check = prepared_check;
    JSValue args = JS_UNDEFINED;
    if (prepared_run) {
        int input_fd = 4;
        int flags = fcntl(input_fd, F_GETFL);
        struct stat input;
        uint8_t workspace[4096];
        if (flags < 0 || (flags & O_ACCMODE) != O_RDONLY ||
            fstat(input_fd, &input) || !S_ISREG(input.st_mode) ||
            input.st_size < 0) return 4;
        PreparedInput prepared = {input_fd, (uint64_t)input.st_size, 0,
                                  workspace, sizeof(workspace)};
        args = decode_value(ctx, &prepared, 0);
        if (JS_IsException(args) || !JS_IsArray(args) ||
            prepared.position != prepared.size) {
            JS_FreeValue(ctx, args);
            return 5;
        }
    }
    JSValue module = JS_Eval(ctx, source, size, "workflow.js",
                             JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    free(source);
    if (JS_IsException(module) || OP_CheckWorkflowModule(ctx, module)) {
        if (check) report_compiler_error(ctx);
        return 5;
    }
    OP_DisableCompilation(ctx);
    if (check) {
        JS_FreeValue(ctx, module);
        JS_FreeContext(ctx);
        JS_FreeRuntime(rt);
        return 0;
    }
    JSModuleDef *module_def = JS_VALUE_GET_PTR(module);
    JSValue evaluated = JS_EvalFunction(ctx, module);
    if (JS_IsException(evaluated)) return 5;
    JSContext *job = NULL;
    int pending;
    while ((pending = JS_ExecutePendingJob(rt, &job)) > 0) {}
    if (pending < 0) return 5;
    if (JS_IsPromise(evaluated) && JS_PromiseState(ctx, evaluated) != JS_PROMISE_FULFILLED)
        return 5;
    JS_FreeValue(ctx, evaluated);
    JSValue namespace = JS_GetModuleNamespace(ctx, module_def);
    if (JS_IsException(namespace)) return 5;
    JSValue entry = JS_GetPropertyStr(ctx, namespace, "default");
    JS_FreeValue(ctx, namespace);
    if (!JS_IsFunction(ctx, entry)) return 5;
    JSValue capabilities = JS_NewObject(ctx);
    if (JS_IsException(capabilities)) return 5;
    int64_t count;
    if (JS_GetLength(ctx, args, &count) || count < 0 || count >= INT_MAX ||
        (uint64_t)count + 1 > native_source_budget / sizeof(JSValue)) return 5;
    /* JS_Call borrows a contiguous argument vector. Its native allocation is
     * bounded by the same workspace budget as the now-released source. */
    size_t call_count = (size_t)count + 1;
    JSValue *call_args = malloc(call_count * sizeof(*call_args));
    if (!call_args) return 5;
    call_args[0] = capabilities;
    size_t provided = 1;
    for (; provided < call_count; provided++) {
        call_args[provided] = JS_GetPropertyUint32(ctx, args, (uint32_t)(provided - 1));
        if (JS_IsException(call_args[provided])) break;
    }
    JSValue root = provided == call_count ?
        JS_Call(ctx, entry, JS_UNDEFINED, (int)call_count, call_args) : JS_EXCEPTION;
    for (size_t i = 0; i < provided; i++) JS_FreeValue(ctx, call_args[i]);
    free(call_args);
    JS_FreeValue(ctx, entry);
    JS_FreeValue(ctx, args);
    if (JS_IsException(root)) return 5;
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
    JsonOutput output = {0};
    int status = serialize_json(ctx, &output, data, 0) || json_flush(&output);
    JS_FreeValue(ctx, data);
    uint8_t end[4] = {0};
    if (!status) status = write_all(end, sizeof(end));
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    return status ? 6 : 0;
}
