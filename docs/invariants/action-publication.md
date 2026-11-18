# Action publication invariants

These rows cover publication owners added by the Action value change. They do not describe all Action, Message, or ingress behavior.

| Id | Level | Invariant | Seam | Owner test | Source |
| --- | --- | --- | --- | --- | --- |
| APV-1 | Module | Ingress captures the exact decoded publication value. | `Ingress` | `APV-1 action publication captures exact decoded content` | `src/wire_request.zig` |
| APV-2 | Module | Ingress accepts a value at the decoded byte limit and refuses a larger value. | `Ingress` | `APV-2 action publication enforces the decoded byte limit` | `docs/contracts/execution.md` |
| APV-4 | Module | A failed publication commit leaves no partial publication. | `Store.publishActionValueForTesting` | `APV-4 publication rollback leaves no partial rows` | `docs/contracts/execution.md` |
| APV-5 | Module | A publication key replays its receipt for the same value and conflicts for a different value throughout the sender lifecycle without adding rows. | `Store.publishActionValue` | `APV-5 publication keys replay or conflict across sender lifecycle` | `docs/contracts/execution.md` |
| APV-6 | Module | The Store refuses an oversized publication without adding rows. | `Store.publishActionValue` | `APV-6 oversized values leave no partial rows` | `docs/contracts/execution.md` |
| APV-7 | Module | A background Action at its pending value limit refuses another value without adding rows. | `Store.publishActionValue` | `APV-7 background backlog refuses overflow without partial rows` | `docs/contracts/execution.md` |
| APV-8 | Module | Stopped and retired senders cannot publish new values. | `Store.publishActionValue` | `APV-8 stopped and retired senders reject new values` | `docs/contracts/execution.md` |
| APV-9 | Module | A resolved Action rejects fresh publications. | `Store.publishActionValue` | `APV-9 resolved Actions reject fresh publications` | `src/store/domain/action_value.zig` |
| APV-10 | Module | A background value adds no Activity or public Conversation rows while other inputs remain visible across pages. | Store activity and conversation pages | `APV-10 public pages omit Action values while preserving other inputs` | `docs/contracts/inspection.md` |
| APV-11 | Module | Ingress rejects invalid publication requests and releases scratch. | `Ingress` | `APV-11 invalid publication requests release scratch` | `src/wire_request.zig` |
| APV-12 | Module | Publication receipts identify the Action and ordinal and include an admission only for background values. | `Store.publishActionValue` | `APV-12 publication receipts identify foreground and background values` | `docs/contracts/execution.md` |
| APV-13 | Module | Hidden Action value history does not increase SQLite Activity page work. | Store Activity pages | `hidden value admissions and user entries do not increase Activity page work` | `docs/contracts/inspection.md` |
