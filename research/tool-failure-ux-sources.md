# Terminal coding-agent activity log: bounded UX source note

Read on 14 October 2026. This is research advice, not an accepted product specification or usability qualification. No code changes or external publication.

## Scope and conclusion

The supplied screenshot has a red `!`, a long action title ending in `— Failed`, `Bash failed. Exit code: 1.`, and `/details for output.` Success rows have a checkmark and a blank line between rows. The research worker investigated external sources. The coordinating thread inspected the screenshot and [Rui's renderer](../src/session_view.zig), where `toolState` uses `!` for several outcomes, including failure, timeout, cancellation, and uncertainty. `toolHeading` emits a leading and trailing newline, and `Summary.emit` retains the Bash failure sentence. These are source observations, not a fresh runtime reproduction.

The sources support removing repeated failure wording while retaining one explicit, visible textual outcome. Keep useful diagnostics and a clear route to full output. An icon plus text can provide useful complementary cues; two adjacent sentences that merely repeat "failed" do not provide the same benefit. None of the sources mandates a terminal blank-line count.

## Primary sources and exact short quotes

### W3C: normative web requirements, with limited applicability

1. [WCAG 2.2, SC 1.4.1 Use of Color, Level A](https://www.w3.org/TR/WCAG22/#use-of-color): "Color is not used as the only visual means of conveying information, indicating an action, prompting a response, or distinguishing a visual element."
   - Requires a non-color visual cue for web content. It does not require an icon plus text plus repeated status wording. Keeping explicit outcome text is a terminal design inference, especially when one icon represents several outcomes.

2. [WCAG 2.2, SC 3.3.1 Error Identification, Level A](https://www.w3.org/TR/WCAG22/#error-identification): "If an input error is automatically detected, the item that is in error is identified and the error is described to the user in text."
   [SC 3.3.3 Error Suggestion, Level AA](https://www.w3.org/TR/WCAG22/#error-suggestion): "If an input error is automatically detected and suggestions for correction are known, then the suggestions are provided to the user, unless it would jeopardize the security or purpose of the content."
   - These concern input errors, not every failed subprocess. Do not cite them as a requirement to explain or fix all Bash failures. Transfer the principle of identifying the affected action and giving a known correction, without inventing a cause.

3. [WCAG 2.2, SC 4.1.3 Status Messages, Level AA](https://www.w3.org/TR/WCAG22/#status-messages): "In content implemented using markup languages, status messages can be programmatically determined through role or properties such that they can be presented to the user by assistive technologies without receiving focus."
   [W3C Understanding Status Messages](https://www.w3.org/WAI/WCAG22/Understanding/status-messages.html), informative guidance: "there is a risk of making an application too 'chatty' for a screen reader user."
   - Web status semantics are not a prescription to add ARIA to terminal text. Clear text alone does not establish accessible announcement behavior. Test the actual terminal and assistive-technology combination.

4. [W3C WCAG2ICT](https://www.w3.org/TR/wcag2ict/): "It provides informative guidance (guidance that is not normative and does not set requirements)."
   [Appendix B.3, Applying WCAG 2 to Text Applications](https://www.w3.org/TR/wcag2ict/#applying-wcag-2-to-text-applications): "A terminal emulator acts as the user agent for text-based applications; it might render some content such as escape codes as semantic elements, but otherwise exposes only lines of text to assistive technology."
   - WCAG itself specifies web conformance. WCAG2ICT explains adaptation to non-web software, including terminals, but is not a conformance standard. A separate law, procurement rule, or contract may impose non-web accessibility requirements; none was assessed here.

### Official design systems: transferable advice, not terminal standards

5. [Microsoft Fluent 2, Message bar, Content](https://fluent2.microsoft.design/components/web/react/core/messagebar/usage): "Don't repeat the title in the message body. Build on it instead." Also: "Provide clear, concise, actionable information that the user needs in order to proceed."
   - Direct support for replacing `Bash failed.` with information the title does not already contain. Message bars are not activity-log rows, so their mandatory buttons, dismissal behavior, and error-severity taxonomy do not automatically transfer.

6. [Microsoft, Error Messages in Windows 7, Text and Progressive disclosure](https://learn.microsoft.com/en-us/windows/win32/uxguide/mess-error): "Remove redundant text." "Don't hide needed information, because users might not find it." "Don't just restate the existing information in a more verbose format."
   - Supports deduplication and putting advanced details behind a disclosure mechanism, not hiding the useful explanation. The page explicitly says it is a Windows 7 guide not updated for newer Windows. Its advice to avoid the words "error" and "failure" relies on Windows icons and should not be copied into this terminal log, where `!` is ambiguous.

7. [GOV.UK Design System, Error message](https://design-system.service.gov.uk/components/error-message/): "Describe what has happened and tell them how to fix it." "Above all, aim for clarity."
   - This component is explicitly for validation errors, not service problems. It also deliberately repeats a message in the page summary and beside a field, and supplies a hidden `Error:` prefix for screen readers. Therefore it is not evidence for banning all repetition; those repetitions serve different locations and modalities.
   [GOV.UK Design System, Details](https://design-system.service.gov.uk/components/details/): "Do not use the details component to hide information that the majority of your users will need." "Make the link text short and descriptive so users can quickly work out if they need to click on it."
   - Transfer the content hierarchy and clear disclosure label, not the HTML interaction model.

### CLI guidance and spacing evidence

8. [Command Line Interface Guidelines, Errors](https://clig.dev/#errors): "Catch errors and rewrite them for humans." "The more irrelevant output you produce, the longer it's going to take the user to figure out what they did wrong."
   [Output](https://clig.dev/#output): "Display output on success, but keep it brief."
   [Robustness](https://clig.dev/#robustness-guidelines): "if there is an error, make sure you print out the logs. Otherwise, it will be very hard to debug."
   - Authored practitioner guidance, not a formal standard. Its introduction excludes full-screen terminal programs. The Errors section also allows debug logs in a file instead of flooding the terminal. Together these support brief summaries plus available diagnostics, not a universal policy of hiding useful failure output.

9. [NN/g, Proximity Principle in Visual Design, Aurora Harley](https://www.nngroup.com/articles/gestalt-proximity/): "Items close together are likely to be perceived as part of the same group" and "Using varying amounts of whitespace to either unite or separate elements is key to communicating meaningful groupings."
   - The first quote is an exact excerpt from a longer sentence. This visual-design advice supports keeping a failure's explanation and disclosure instruction close to its title, with clearer separation between different calls. Combined with CLIG's brief-success advice, it supports trying compact adjacent success rows. It does not prescribe removing every blank line or prove that zero blank lines works in this log. Spacing evidence was supplied by the coordinating thread and independently checked against the full article here.

## Recommendations to evaluate

- State each outcome once in plain text. Preserve distinctions such as `Failed`, `Timed out`, `Cancelled`, and `Outcome unknown`. Do not replace them with the shared `!`. Keep or remove the icon according to its scanning value, not a claim that WCAG bans redundancy. Check the retained label remains visible when long titles wrap or truncate.
- For the reported failure, retain the title's `Failed` and remove the duplicate `Bash failed.` The exit code adds information and can remain briefly visible for a coding audience. Exit code 1 alone does not explain the cause or establish that Bash itself malfunctioned.
- If a reliable reason or recovery action is available, show it without requiring `/details`. If only the exit status is known, report that honestly. Do not guess the cause, promise retry safety, or imply that every failed agent action requires user intervention.
- Keep the `/details` instruction discoverable and accurate. [Rui's current contract](../ARCHITECTURE.md#staged-persistent-input) says it shows the latest Conversation page with full saved Tool Results, not one selected call. A wording change must preserve that scope. The shorter current instruction and a more explicit instruction are candidates to compare, not a research-settled choice.
- Keep full command output available through details. Useful failure diagnostics may need to appear immediately, consistent with CLIG's logs-on-error advice. Details should add real diagnostics, not repeat the summary. Do not collapse the only actionable explanation by default.
- Preserve capture, cleanup, and uncertainty warnings even after a successful exit, as required by [Rui's presentation contract](../ARCHITECTURE.md#staged-persistent-input). Deduplicate recognized repeated wording without hiding unknown diagnostics or changing saved results.
- Evaluate compact success rows and tighter spacing within a failure than between calls. Preserve meaningful call boundaries. This is a research inference to test, not an accepted blank-line rule.

Illustrative wording only, not a spacing specification:

```text
! <action title> — Failed (exit code 1)
  /details for output.
```

## Evidence limits

Actual source pages were read, including normative WCAG sections and the full NN/g article, rather than relying on search snippets. The coordinating thread checked Fluent 2's repetition guidance, W3C's color guidance, GOV.UK's error-message guidance, CLIG, and NN/g directly. The bounded set gives principles and contextual examples, not terminal coding-agent experiments. Rui source and the supplied screenshot were inspected, but no fresh runtime rendering, output-selection interaction, screen reader, monochrome terminal, narrow-width layout, or usability task was tested. No source establishes optimal cue counts or blank-line counts. The evidence supports a candidate design and its constraints, not a claim of accessibility conformance or measured usability improvement.
