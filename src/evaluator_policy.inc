/* Included at the end of the evaluator's pinned QuickJS translation unit.
 * The parser marks only direct default-exported async declarations; inspecting
 * a namespace here would access unlinked export bindings and is unsafe. */
#include "evaluator_policy.h"

int OP_CheckWorkflowModule(JSContext *ctx, JSValueConst value) {
    if (!JS_IsModule(value)) {
        JS_ThrowSyntaxError(ctx, "workflow module required");
        return -1;
    }
    JSModuleDef *module = JS_VALUE_GET_PTR(value);
    if (!module->op_has_workflow_entry) {
        JS_ThrowSyntaxError(ctx, "workflow.js: direct default async function required");
        return -1;
    }
    if (module->req_module_entries_count) {
        JS_ThrowSyntaxError(ctx, "imports are unavailable in a workflow");
        return -1;
    }
    return 0;
}

void OP_DisableCompilation(JSContext *ctx) {
    ctx->eval_internal = NULL;
}
