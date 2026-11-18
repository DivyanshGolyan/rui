# Working, queued, stopped and Host stopped

A working chat shows **Thinking** or the running tool and offers **ctrl+x stop**. A follow-up can wait as a queued message. A settled stop shows **■ Stopped**. If the Host goes away, Overview and the open chat show **Host stopped**.

## Sub-features

- Ctrl-X stops work in the open chat or on the selected list row. Clicking the chat's **ctrl+x stop** hint uses the same action.
- A queued follow-up shows **◌** and its text. Parallel tools have their own working marks.
- The first settled stop frame and its list row agree; the old answer preview must not survive as the stop result.
- An unreadable reply shows **× The model's reply didn't come through · ctrl+r retries**. Ctrl-R retries through the existing request handling.
- A stopped Host offers a start or retry when available. Use the shown control; `r` is the start key in chat. A ready Host removes the stopped notice.

## How to get to it (user POV)

Send a request, then send a follow-up while it is working to see the queue. Press Ctrl-X to stop. Host stopped appears when the connected Host ends; use its displayed start or retry action, or restart the Host from the CLI.

## Driving it with verify-rui

Run `$V frames FULLSHA --only chat-working,chat-queued,tools-running,stop,stop-narrow,stopped,chat-failed,host-stopped,host-stopped-chat,host-back`.

Frame states: `chat-working`, `chat-queued`, `tools-running`, `stop`, `stop-narrow`, `stopped`, `chat-failed`, `host-stopped`, `host-stopped-chat`, `host-back`

These recipes own separate slow chats so they do not borrow another state's work. Check **Thinking**, the queued text, both active tool rows and the stop result at both widths. Host recipes pause and start only the fixture-owned Host. **host-back** waits for the stopped notice to disappear and the session list to return.

## Gotchas

**Host paused**, **Host unreachable** and **Host is a different Rui version** are different notices. They do not always offer the same recovery. A Host restart capture does not prove an interrupted tool ran again. Ctrl-C leaves the client; use Ctrl-X to stop work.

Source: [stop and queue keys](../../../../src/session_keys.zig), [Host controls](../../../../src/Overview.zig), [chat stop clicks](../../../../src/SessionFrontend.zig), [work presentation](../../../../src/session_view.zig).
