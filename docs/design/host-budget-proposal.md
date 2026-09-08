> Historical withdrawal note: the component split below remains withdrawn. Later acceptance selected the 256 MiB whole-Host target and 128/120 client policy; see [accepted policy](host-final-recommendations.md) and [current memory accounting](host-memory-accounting.md). Statements below that those policies were unaccepted describe the earlier decision state.

# Host budget proposal — withdrawn allocation model

The former 200/32/4/20 MiB split, 32/96 MiB idle targets, 32 KiB client
allowance and implied per-tool memory allowance are withdrawn from the current
recommendation. They were assistant-selected planning allowances, not costs
derived from OnePage's implementation. The resulting 128-client/8-place
headroom proposal is unselected, not a demonstrated requirement.

The overall 256 MiB target remains an unaccepted proposal; it is not an enforced
RSS limit or a whole-Host measurement. The user's acceptance of approximately
250 MiB for a model-stream fixture did not approve that complete budget.

The worker experiment deliberately touched 64 KiB of stack per worker. Its
roughly 79 MiB total says nothing about actual OnePage worker requirements and
selects neither a worker-per-tool topology nor an 80 KiB per-worker budget.
Its raw observations remain historical evidence, not grounds for a capacity
or executor-cost claim. No further artificial worker benchmark is planned.

The planned 1,000 shared Active Capacity remains accepted on its own terms,
with actual Host qualification before release. The ordinary curl buffer
improvement remains supported by its narrow before/after evidence.

Use the [current Host decision aid](host-resource-controls.md) for accepted
choices and remaining questions. The [previous proposal](archive/host-budget-proposal-2026-09-06-before-consolidation.md)
is preserved as history, not current guidance.
