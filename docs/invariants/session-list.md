# Invariants: Session list facts and read work

[Test requirements](../verification/testing.md) define the catalog and its owner tests.

| id | level | invariant | seam that observes it | owner test | source |
|---|---|---|---|---|---|
| SL-1 | Module | A Session list row reports its own work-change time and the maximum time, count and needs-you count for its eligible creator subtree, including descendants beyond the response page. Workspace and archive filters apply at every link. | Store Session-list read | `SL-1: Session list rolls up eligible descendants beyond the page` in `src/store/tests/session_list.zig` | docs/contracts/cli.md:143 |
| SL-2 | Module | Reading a fixed creator subtree does not scan unrelated Sessions in the same Workspace for every descendant batch. | Store Session-list read and SQLite work counter | `SL-2: a fixed creator subtree skips unrelated Sessions in its Workspace` in `src/store/sqlite_tests/session_list.zig` | src/store/domain/session_list_read.zig |
| SL-3 | Module | A Session's list clock records meaningful durable work transitions, retains its time across retries and automatic tool completion, and rejects a missing bound execution projection. | Store Session-list read | `SL-3: Session list dates meaningful work transitions` in `src/store/tests/session_list.zig` | docs/contracts/cli.md:144 |
| SL-4 | Module | A changed Session listing includes each affected Session and eligible creator ancestor once, including across cursor pages and archive changes. | Store Session-list read | `SL-4: changed Session pages include eligible creator ancestors` in `src/store/tests/session_list.zig` | docs/contracts/cli.md:149 |
| SL-5 | Module | A Session list row names its Session's own first Message, with its sender when a peer sent it, and its first awaiting approval, as the Session's report and activity reads name them, with or without a Turn. | Store Session-list read | `SL-5: a list row's first Message, first approval and last line are the owners' values, for every Session shape` in `src/store/tests/session_list.zig` | src/store/domain/session_list_read.zig |

The SL-1 owner covers real agent births, a three-level subtree beyond the first page, controlled work-change times and archive filter cases. Its MySQL execution remains a required hosted check. The SL-2 owner checks returned facts and SQLite VM work before and after adding 128 unrelated Sessions; it does not establish a bound for arbitrary subtree size.
