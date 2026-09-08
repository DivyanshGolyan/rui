# Local diagnostic retention conventions

Research date: 2026-09-06. Advisory evidence for the execution-model discussion; this does not select a model or amend OnePage's accepted contract.

## Primary-source findings

- **Local diagnostic files can be useful without a central service.** VS Code's agent debug logs persist locally, show chronological events and summaries, and can be exported as an OTLP JSON file for sharing or offline analysis. Its separate Chat Debug view exposes full request and response details. These are concrete examples of summary-oriented inspection, detailed payload inspection, and user-exportable evidence; they do not establish a universal retention policy. [VS Code: Debug chat interactions](https://code.visualstudio.com/docs/agents/agent-troubleshooting/chat-debug-view)
- **Bounded retention is an established operating choice.** Docker recommends its `local` logging driver to avoid disk exhaustion. That driver rotates files, deletes the oldest excess files, and compresses rotated logs by default; its documented default is five 20 MB files per container. These numbers are Docker's defaults, not proposed OnePage quotas. [Docker: Configure logging drivers](https://docs.docker.com/engine/logging/configure/), [Docker: Local file logging driver](https://docs.docker.com/engine/logging/drivers/local/)
- **Crash evidence and uploading are separate decisions.** Electron's crash reporter can collect and store crash reports locally with `uploadToServer: false`. Its docs distinguish that capture from server submission. This is evidence that a central collection backend is not necessary to retain crash evidence; it is not a recommendation to add Electron or crash dumps to OnePage. [Electron: crashReporter](https://www.electronjs.org/docs/latest/api/crash-reporter)
- **A recovery log is different from a diagnostic log despite the shared word.** SQLite's WAL can contain committed database state; separating it from the database can lose transactions or corrupt the database. It is not disposable diagnostic history. [SQLite: Write-Ahead Logging, The WAL File](https://www.sqlite.org/wal.html#the_wal_file)

## Recommendation for discussion

Separate by purpose and deletion consequences, not by whether the information is useful to developers or users. Both groups can need both kinds of information.

1. **Product and recovery state:** the facts required to preserve promised results and decide what may happen next. Retention follows the product's lifetime contract. Deleting these facts may change correctness.
2. **Diagnostics:** recent evidence that helps explain a fault. Keep small structured summaries locally by default, persist them across ordinary restarts, and bound their total storage. They may expire without changing workflow behavior. Losing a tail during a crash must not make recovery unsafe.

Within diagnostics, full provider payloads and tool output are a more expensive level of detail, not a second source of execution authority. Make additional verbose capture explicit and bounded. A rejection code alone will not explain every parser or provider incompatibility: if the original rejected bytes were not captured, later diagnosis may require reproducing the problem with verbose capture enabled. Conversely, any payload required for accepted continuation or another promised behavior belongs in product state even when it is also useful for debugging.

Give users a way to export recent diagnostics with app/provider versions and relevant operation identifiers. They can inspect and choose whether to share that file. Sharing policy is separate from local capture; a central backend is unnecessary.

The simplifying rule is: **the runtime never consults diagnostic history to decide recovery or permission to act.** Deleting diagnostics may make a bug harder to explain; it must not change what the application does. This separation alone does not decide whether execution facts use mutable current state or immutable per-try records, and it does not require choosing a new storage system, retention duration, or quota now.
