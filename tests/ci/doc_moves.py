#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import posixpath
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
LINK = re.compile(r"(?<=\]\()([^\s)]+)(?=\))")


def slug(title):
    title = re.sub(r"\[([^]]+)\]\([^)]*\)", r"\1", title)
    return re.sub(r"[^\w\- ]", "", title.strip().lower()).replace(" ", "-")


def headings(text):
    result = set()
    counts = {}
    fence = None
    for line in text.splitlines():
        if match := re.match(r"^\s*(`{3,}|~{3,})", line):
            mark = match[1][0]
            fence = None if fence == mark else mark if fence is None else fence
        if fence:
            continue
        if match := re.match(r"^#{1,6} (.+)$", line):
            anchor = slug(match[1])
            count = counts.get(anchor, 0)
            result.add(f"{anchor}-{count}" if count else anchor)
            counts[anchor] = count + 1
    return result


def destination(target, origin, output, anchors):
    if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", target) or target.startswith("//"):
        return target
    path, sep, anchor = target.partition("#")
    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(origin), path)) if path else origin
    original = resolved
    if sep and (resolved, anchor) in anchors:
        resolved, anchor = anchors[(resolved, anchor)]
    if origin == output and resolved == original:
        return target
    relative = posixpath.relpath(resolved, posixpath.dirname(output) or ".")
    if resolved == output and sep:
        relative = ""
    return relative + sep + anchor


def rewrite(text, origin, output, anchors):
    return LINK.sub(lambda m: destination(m[0], origin, output, anchors), text)


def broken_links(documents):
    failures = set()
    for origin, text in documents.items():
        for match in LINK.finditer(text):
            target = match[0]
            if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", target) or target.startswith("//"):
                continue
            path, sep, anchor = target.partition("#")
            resolved = posixpath.normpath(posixpath.join(posixpath.dirname(origin), path)) if path else origin
            if resolved not in documents and not (ROOT / resolved).exists():
                failures.add((origin, target, "missing path"))
            elif sep and resolved.endswith(".md") and anchor not in headings(documents.get(resolved, (ROOT / resolved).read_text())):
                failures.add((origin, target, "missing anchor"))
    return failures


def audit(root=ROOT):
    manifest = json.loads((root / "tests/ci/doc_move_map.json").read_text())
    base = manifest["base"]
    paths = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", base], cwd=root, text=True).splitlines()
    before = {p: subprocess.check_output(["git", "show", f"{base}:{p}"], cwd=root, text=True)
              for p in paths if p.endswith(".md")}
    sources = {p: before[p].splitlines(keepends=True) for p in {s["source"] for s in manifest["segments"]}}
    anchors = {(a["source"], a["anchor"]): (a["destination"], a["destination_anchor"]) for a in manifest["anchors"]}
    after = {p: (root / p).read_text() for p in before if (root / p).exists()}
    for span in manifest["segments"]:
        path = span["destination"]
        after[path] = (root / path).read_text()
    errors = []
    for source, lines in sources.items():
        coverage = [line for s in manifest["segments"] if s["source"] == source
                    for line in range(s["start"], s["end"] + 1)]
        if coverage != list(range(1, len(lines) + 1)):
            errors.append(f"{source}: source lines are omitted, duplicated, or reordered in the map")
    for span in manifest["segments"]:
        source, output = span["source"], span["destination"]
        text = "".join(sources[source][span["start"] - 1:span["end"]])
        if hashlib.sha256(text.encode()).hexdigest() != span["sha256"]:
            errors.append(f"{source}:{span['start']}: baseline hash mismatch")
        text = re.sub(r"^(#{2,6}) ", lambda m: "#" * (len(m[1]) + span["heading_shift"]) + " ", text, flags=re.M)
        text = rewrite(text, source, output, anchors)
        for edit in manifest["index_edits"]:
            if edit["source"] == source:
                text = text.replace(edit["old"], edit["new"])
        if after[output].count(text.strip()) != 1:
            errors.append(f"{source}:{span['start']}-{span['end']}: expected exact moved content once in {output}")
    for (source, anchor), (output, target) in anchors.items():
        if target not in headings(after[output]):
            errors.append(f"{source}#{anchor}: destination {output} lost its anchor")
    old_failures = {(p, destination(t, p, p, anchors), why) for p, t, why in broken_links(before)}
    for path, target, why in sorted(broken_links(after) - old_failures):
        errors.append(f"{path}: {target}: {why}")
    for path, text in after.items():
        if path in sources:
            continue
        for match in LINK.finditer(text):
            migrated = destination(match[0], path, path, anchors)
            if migrated != match[0]:
                errors.append(f"{path}: unmigrated link {match[0]} (expected {migrated})")
    if errors:
        raise SystemExit("\n".join(errors))
    print(f"PASS: {sum(len(lines) for lines in sources.values())} source lines, "
          f"{len(manifest['segments'])} spans, {len(anchors)} anchors; no new broken links or stale root anchors")
    print(f"Pre-existing broken links retained: {len(old_failures)}")


if __name__ == "__main__":
    audit()
