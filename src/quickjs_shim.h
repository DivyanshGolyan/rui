#ifndef ONEPAGE_QUICKJS_SHIM_H
#define ONEPAGE_QUICKJS_SHIM_H

#include "quickjs.h"

static inline JSModuleDef *onepage_quickjs_module(JSValue value) {
    return (JSModuleDef *)JS_VALUE_GET_PTR(value);
}

static inline JSValue onepage_quickjs_undefined(void) { return JS_UNDEFINED; }
static inline JSValue onepage_quickjs_null(void) { return JS_NULL; }
static inline JSValue onepage_quickjs_false(void) { return JS_FALSE; }
static inline JSValue onepage_quickjs_true(void) { return JS_TRUE; }
static inline JSValue onepage_quickjs_exception(void) { return JS_EXCEPTION; }

#endif
