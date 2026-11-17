# Consent

In **ask first** mode, a proposed tool call opens Approval with its command and working directory. Read it, select **Allow once** or **Deny** with Left/Right, then press Enter. Typing moves to a draft reason; Esc returns to the choice without losing that draft.

## Sub-features

- Approval shows the request, working directory and time limit. A clipped request shows how many rows remain.
- Long requests need scrolling before **Allow once** can be confirmed.
- Left selects **Allow once**; Right selects **Deny**. Enter confirms the shown choice. Clicking a choice uses the same decision path.
- A typed reason can deny the call and send the reason when the footer offers **enter denies the call and sends this**.
- Pasted text is draft text, not approval. Single `a`, `d`, `y` or `n` letters do not decide the call.

## How to get to it (user POV)

In Session `approve`, or after choosing **ask first** in Chat info's **Permissions**, send a request that proposes a tool call. Read the request with PgUp/PgDn, arrows or the wheel. Choose **Allow once** or **Deny**, then confirm. Type a reason if needed; Esc or Ctrl-G restores the selector.

## Driving it with verify-rui

Frame states: `approval`, `approval-hover`, `approval-typing`, `approval-after-esc`, `read-image-approval`

Run `$V frames FULLSHA --only approval,approval-hover,approval-typing,approval-after-esc` for the request, Deny hover, retained draft and return to the selector.

The `read-image-approval` state proposes the built-in `read_image` tool in ask mode, showing its exact path arguments and **Allow once**/**Deny** without an MCP Server label. The source file need not exist while approval is pending. This is a new state on revisions that offer `read_image`; it cannot run on an earlier revision without that tool.

Use a fresh terminal on `--session approve` with `doctor` PASS for side effects:

- Open `$V term "$RUN" k1 --surface tmux-attached --session approve`, wait for the input, send `consent check` then Enter, and wait for **Run Bash**.
- Send `--keys PgDn`, waiting for each new committed frame, until the complete command has been shown. Save snapshots of the pages.
- Send `--keys Left`, wait for the selected **Allow once** frame, then `--keys Enter`. Wait for **Fixture tool summary**. `project/progress.log` gains 30 lines and `provider.jsonl` records `tool-summary`.
- On a second proposal, read it, send `--keys Right`, wait for the **Deny** selection, then Enter. The file stays unchanged and the provider receives a denial.
- On a new proposal, paste with `--hex 1b5b3230307e610d1b5b3230317e`. No command runs. Send Esc, wait for the selector, and capture it.

Use `wait --after GEN` between steps, save `screen` snapshots and export `$V evidence "$RUN"`. Compare the file and provider log before and after each decision.

## Gotchas

The fixture proposes a 32-line command for each `consent check`; the file grows by 30 lines for each allowed call. A still of Approval does not prove that a call ran. The current physical-input coach still asks for obsolete letter choices; see [Hardware input](./hardware-input.md) for that limit.

Source: [approval keys](../../../../src/session_keys.zig), [choice and reason rules](../../../../src/session_consent.zig), [reading and delivered choice](../../../../src/SessionScreen.zig).
