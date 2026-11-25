#!/usr/bin/env python3
"""Refuse a thread's words to the person that the person cannot act on.

Two rules, each learned from a message Divyansh answered with "didn't understand" or "what do you need from me?":
- A message or checklist saying the work waits on the person needs a question open: a question mark, the word
  card, or request_decision called this turn. A checklist never lists what the person must do, so it never passes.
- A decision card says what changes in everyday words: no backticks, quoted symbols, identifiers or flags.
An unreadable transcript counts as asked: the hook catches a forgotten question, it does not police the person's inbox.
"""
import json
import re
import sys

SENTENCE = re.compile(r"(?<=[.!?:;])\s+|\n+")
WAITS = re.compile(r"\b(?:waits?|waiting|awaits?|awaiting|blocked|pending|needs?|needed)\s+(?:on|for|from)?\s*"
                   r"(?:you|your|Divyansh)\b", re.I)
NEGATED = re.compile(r"\b(?:nothing|not|no longer|isn't|aren't|never|nobody|no one|without)\b", re.I)
CHECKLIST = "mcp__hearthbot__update_progress_checklist"
CARD = "mcp__hearthbot__request_decision"
CODE_WORDS = re.compile(r"""`|"[^\w"]{1,3}"|'[^\w']{1,3}'|\b[a-z]+_[a-z_0-9]+\b|(?<!\w)--[a-z]|\.(?:zig|py|ts|md|json)\b""")
CARD_REFUSAL = ("A decision card is read by a person, not a compiler: \"{found}\" is code. Say what changes for them in "
                "everyday words: what is on screen or happening now, what it looks like after, and your recommendation.")

REFUSAL = ("This says the work waits on the person, but no question is open. Post the question first with "
           "request_decision (one decision, everyday words, a recommended option), or make the choice yourself when "
           "it is reversible (AGENTS.md#authority). {extra}")


def claims_to_wait(text):
    """The first sentence saying the work waits on the person, or None."""
    return next((s.strip() for s in SENTENCE.split(text) if WAITS.search(s) and not NEGATED.search(s)), None)


def decided_this_turn(transcript_path):
    """Whether request_decision was called since the person's last message; True when the transcript is unreadable."""
    try:
        entries = [json.loads(line) for line in open(transcript_path, encoding="utf-8") if line.strip()]
    except (OSError, TypeError, ValueError):
        return True
    called = False
    for entry in entries:
        content = (entry.get("message") or {}).get("content")
        blocks = content if isinstance(content, list) else []
        if entry.get("type") == "user" and not any(b.get("type") == "tool_result" for b in blocks if isinstance(b, dict)):
            called = False
        elif entry.get("type") == "assistant":
            called |= any(b.get("type") == "tool_use" and b.get("name", "").endswith("request_decision")
                          for b in blocks if isinstance(b, dict))
    return called


def card_text(args):
    options = [option for option in args.get("options") or [] if isinstance(option, dict)]
    return "\n".join(str(part) for part in [args.get("question"), args.get("reason"),
                      *(value for option in options for value in (option.get("label"), option.get("consequence")))] if part)


def refusal(payload):
    tool, args = payload.get("tool_name", ""), payload.get("tool_input") or {}
    if tool == CARD:
        found = CODE_WORDS.search(card_text(args))
        return CARD_REFUSAL.format(found=found[0]) if found else None
    text = args.get("text") or ""
    sentence = claims_to_wait(text)
    if sentence is None:
        return None
    if tool == CHECKLIST:
        return REFUSAL.format(extra="A checklist never lists what the person must do: \"" + sentence[:80] + "\".")
    if "?" in text or re.search(r"\bcard\b", text, re.I) or decided_this_turn(payload.get("transcript_path")):
        return None
    return REFUSAL.format(extra="Said: \"" + sentence[:80] + "\".")


def main():
    reason = refusal(json.load(sys.stdin))
    if reason:
        print(reason, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
