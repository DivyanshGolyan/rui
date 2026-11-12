# Tool activity label style

Inspected 2026-10-13. This note records the source basis for Rui's accepted label guidance, not implementation evidence. The final agreement requires a description in original Bash arguments, at most 100 decoded UTF-8 bytes, with no backward compatibility. It supersedes the initial 120-byte agreement. The model-generated label stays unchanged across observed states. [Architecture](../ARCHITECTURE.md#model-output-tools-and-permission) owns the accepted contract.

## What the sources recommend

These are exact quotations from inspected first-party pages. Section names identify the passages. All URLs were accessed on 2026-10-13.

| Source and section | Direct recommendation | Relevance and limit |
| --- | --- | --- |
| Microsoft, [Command Buttons in Windows 7](https://learn.microsoft.com/en-us/windows/win32/uxguide/ctrl-command-buttons), **Labels** | "Start labels with an imperative verb and clearly describe the action that the button performs. Don't use ending punctuation." "While short labels are preferred, use enough text to explain the command sufficiently." "Use sentence-style capitalization." | Action labels name the operation. The same section recommends a direct object when context does not identify it. These are button rules, not rules for passive activity records. The page explicitly says this Windows 7 guide has not been updated for newer Windows versions. |
| Microsoft, [Progress Bars](https://learn.microsoft.com/en-us/windows/win32/uxguide/progress-bars), **Labels → Progress bar labels** | "Start the label with a verb (for example, Copying) and end with an ellipsis. This label may change dynamically if the operation has multiple steps or is processing multiple objects." | Progress text describes current activity rather than naming an action. The same Windows 7 age limitation applies. Its ellipsis recommendation belongs to live progress text. |
| IBM Carbon, [Button](https://www.carbondesignsystem.com/building-blocks/core/components/button/guidelines), **Content → Main elements → Button label** | 'To provide enough context, use the {verb} + {noun} content formula on buttons except in the case of common actions like "Done", "Close", "Cancel", "Add", or "Delete".' "By default Carbon uses sentence case for all button labels." | Supports a concrete verb and target. Carbon permits exceptions for compact UIs and translation. This does not establish a word-count rule for Rui. |
| IBM Carbon, [Inline loading](https://www.carbondesignsystem.com/building-blocks/core/components/inline-loading/guidelines), **Content → Main elements → Label (optional)** | "The label should describe the state of the action being performed." "Once the loading status changes to finished, the label should change." | Examples are "Saving …" while active and "Saved" when finished. Error wording also changes. For Rui, this argues against treating an unchanged description as live status or a success report. Both inspected Carbon pages display an update date of 2026-09-30. |
| GOV.UK Design System, [Button](https://design-system.service.gov.uk/components/button/), **How it works** and **Warning buttons** | "Write button text in sentence case, describing the action it performs." "You may need to include more or different words to better describe the action." "Make sure the context and button text make clear what will happen if the user selects it." | Examples distinguish "Continue" without saving from "Save and continue" with saving. The warning guidance requires destructive consequences to be clear, not conveyed only by colour. These are action-control recommendations, not evidence that a summary can replace exact command inspection. |
| Google Material 2, [Writing](https://m2.material.io/design/communication/writing.html), **Principles**, **Write simply and directly**, **Write for all reading levels**, **Skip unnecessary punctuation**, and **Content structure → Use consistent words** | "Text should be clear, accurate, and concise." "Use simple, direct language that makes content easy to understand." "Use common words that are clearly and easily understandable across all reading levels." "Skip colons after labels." "Use words in a consistent manner across your UI features." | Supports plain, consistent wording. The punctuation section also lists labels among elements where solitary sentences avoid periods. The page explicitly says Material 2 is no longer maintained; this is historical Google guidance, not a claim about Material 3 policy. |

Action and progress wording are different, not competing universal rules. Microsoft uses a base verb for commands and an *-ing* form for live progress. Carbon makes the distinction explicit by changing the loading label with the state. Neither pattern directly prescribes an immutable, model-generated activity label.

## Accepted style for Rui

Use a short **base verb + concrete target + useful scope**, in sentence case, without trailing punctuation. For example, `Search src for retry handling` or `Run parser tests`. Treat the phrase as the task's name, not an instruction to the reader or a statement of execution state. The schema recommends 40–60 characters and excludes status, safety, and success claims; runtime validation enforces mechanical constraints, not prose quality.

This adapts action-label guidance to the unchanged-label scenario. Actual unresolved, approval, and terminal facts come from Rui's state presentation, not from the model's description. Layout, markers, storage, validation, and permissions follow Architecture, not these source quotations.

The following adaptations follow from the sources and this scenario:

- Name what this call does, not the whole investigation or desired eventual outcome. Prefer `Search tests for timeout cases` over `Investigate the issue` or `Use Bash`.
- Include enough scope to distinguish similar calls. Use a relevant directory, file, test group, or external destination when it helps. Retain meaningful identifier casing. Avoid raw argument dumps and implementation jargon that adds no useful distinction.
- Describe the operation rather than promise its result. Prefer `Run parser tests` to `Ensure parser tests pass`, and `Search src for retries` to `Find all retry bugs`. A search may find nothing, and a test run may fail.
- State consequential effects plainly. Use `Delete generated build files`, not `Safely clean everything`. A model-generated description is not evidence of safety, approval, rollback, or absence of side effects. Exact arguments and Rui's permission and outcome facts remain authoritative under [the existing authorization contract](../ARCHITECTURE.md#authorizing-exact-actions).
- Keep one consistent verb for the same operation. Prefer ordinary words, but preserve a technical term when the user needs it to identify the work. Omit conversational padding such as `I will`, `Please wait`, and `Now`.
- Use the fewest words that still identify the action and target. The final 100-byte ceiling counts decoded UTF-8 bytes, not JSON spelling, characters, words, or screen columns. It is a Rui constraint, not a source recommendation. None of the cited passages establishes the byte ceiling or the 40–60-character aim. The ceiling is not a preferred length; retain important effects within it.

## Alternatives and their costs

| Form | Example | Tradeoff in the unchanged-label scenario |
| --- | --- | --- |
| Base-verb task phrase, accepted | `Run parser tests` | Clear and compact. Its command-like form could look clickable or sound like an instruction without surrounding task context. The passive-record interpretation is Rui's adaptation, not button guidance itself. |
| Noun phrase | `Parser test run` | Explicitly names a task without claiming state. Less direct, and longer noun strings become harder to read. Microsoft's **Labels → Progress dialog box titles** permits an operation name as a title, but that does not mandate noun phrases for Rui. |
| Activity phrase | `Running parser tests` | Familiar for progress. It can imply execution has begun while pending, or remains active after completion, denial, cancellation, or failure. Use only if the surrounding context makes it unambiguously a task name. Live progress text that changes with state is a different design, outside this research scenario. |

Past-tense success phrases such as `Parser tests passed` are unsuitable as pre-execution labels retained unchanged. They report a result that the model does not yet know. Ellipses likewise suggest an unfinished process and add no useful meaning to a stable task name.

## Evidence limits

This is first-party content guidance, not a comparative usability study of Rui or proof of model compliance. Full pages were inspected, including the legacy notices and contrary progress-text rules. Quotations preserve source wording; the adaptations below them are Rui-specific inferences. No source establishes the best verb form for every language, byte-budget usability, terminal wrapping, accessibility of Rui's rendered states, or the accuracy of generated summaries. The original investigation changed no runtime or permission behavior and qualified neither. Architecture now records the accepted design; this note supplies no implementation or native-platform evidence.
