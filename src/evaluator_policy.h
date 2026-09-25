#ifndef RUI_EVALUATOR_POLICY_H
#define RUI_EVALUATOR_POLICY_H
#include "quickjs.h"

/* Inspect the compiled module without linking or executing author code.
 * A failed check sets a bounded compiler exception on ctx. */
int OP_CheckWorkflowModule(JSContext *ctx, JSValueConst module);
/* Call after compiling the sole source and before running any author code.
 * Blocks indirect Function/AsyncFunction constructors as well as eval. */
void OP_DisableCompilation(JSContext *ctx);
#endif
