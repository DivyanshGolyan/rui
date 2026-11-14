"""Keep Host leaf knowledge in its owner, including undotted JSON keys.

Vocabulary comes from generated HostSettings, emitted from Settings by the same
visitor as leaves, not a second setting inventory. We reject literal paths,
Host-specific keys/names, schema path member chains, and typed HostSettings
accesses (including overlapping wire names). Other wire schemas derive the
shared vocabulary; their unrooted fields are not Host-setting knowledge.

Generic byte/path words are not setting knowledge on their own. They still
fail in a setting path or on a typed HostSettings value. Like caller_errors,
this is a source gate, not a whole-program type checker: reflective/dynamically
constructed keys or aliases passed through unknown functions require review.
"""
import json
import re
import sys
from pathlib import Path

from caller_errors import Token, close_brace, lex, production

ROOT = Path(__file__).resolve().parents[2]
# Language/OS/transport primitives, not a setting inventory. These words do
# not identify a Host setting without a settings-rooted reference.
GENERIC = frozenset("path dir file env url endpoint hex value key owner interface".split())


def snake(name):
    return re.sub(r"[A-Z]", lambda m: "_" + m[0].lower(), name)


def vocabulary(schema, prefix=()):
    """All properties and group/leaf paths, including alternatives and maps."""
    keys, paths = set(), set()
    if not isinstance(schema, dict):
        return keys, paths
    for name, child in schema.get("properties", {}).items():
        keys.add(name)
        path = prefix + (name,)
        paths.add(path)
        ck, cp = vocabulary(child, path)
        keys.update(ck)
        paths.update(cp)
    for variant in ("oneOf", "anyOf", "allOf"):
        for child in schema.get(variant, []):
            ck, cp = vocabulary(child, prefix)
            keys.update(ck)
            paths.update(cp)
    additional = schema.get("additionalProperties")
    if isinstance(additional, dict):
        paths.add(prefix + ("*",))
        ck, cp = vocabulary(additional, prefix + ("*",))
        keys.update(ck)
        paths.update(cp)
    return keys, paths


def declaration_members(source, declaration):
    tokens = production(lex(source))
    names = [token.text for token in tokens]
    start = next((i for i in range(len(names) - 4)
                  if names[i:i + 4] == ["pub", "const", declaration, "="]), None)
    if start is None or names[start + 4] not in ("enum", "struct"):
        raise ValueError("expected explicit domain declaration " + declaration)
    brace = names.index("{", start)
    end = close_brace(tokens, brace)
    members, depth = set(), 0
    for i in range(brace + 1, end):
        if names[i] in ("{", "(", "["):
            depth += 1
        elif names[i] in ("}", ")", "]"):
            depth -= 1
        elif depth == 0 and re.fullmatch(r"[A-Za-z_]\w*", names[i]):
            struct_field = names[start + 4] == "struct" and names[i + 1] == ":"
            enum_tag = (names[start + 4] == "enum" and names[i - 1] in ("{", ",")
                        and names[i + 1] in (",", "}", "="))
            if struct_field or enum_tag:
                members.add(names[i])
    return members


def facts(root=ROOT):
    schemas = json.loads((root / "openapi.json").read_text())["components"]["schemas"]
    keys, paths = vocabulary(schemas["HostSettings"])
    shared, wire_paths = set(), set()
    for name, schema in schemas.items():
        if name == "HostSettings":
            continue
        wk, wp = vocabulary(schema)
        shared.update(wk)
        wire_paths.update(wp)
    # These independent domains overlap Host spelling but are not Host
    # configuration: routing engine tags and frozen tool-call fields/owners.
    # Derive their declarations, never maintain the overlapping names by hand.
    for file, declaration in (("store_target.zig", "Kind"),
                              ("tool_record.zig", "Owner"),
                              ("call_classification.zig", "BashArguments")):
        source = root / "src" / file
        if source.exists():
            shared.update(declaration_members(source.read_text(), declaration))
    spellings = lambda names: names | {snake(name) for name in names}
    return spellings(keys), paths, spellings(shared), wire_paths


def surfaces(root):
    paths = {root / name for name in (
        "src/cli.zig", "src/serve_grammar.zig", "src/cli_grammar.zig",
        "clients/ts/src/client.ts")}
    # TUI components are top-level PascalCase modules, not h2/Engine or Store.
    for path in (root / "src").rglob("*.zig"):
        relative = path.relative_to(root / "src")
        top_component = len(relative.parts) == 1 and path.name[0].isupper()
        presentation = (path.name.startswith(("tui_", "terminal_", "app_")) or
                        path.stem.endswith(("_view", "_style", "_input", "_window", "_reads")) or
                        relative.parts[0] == "widgets" or
                        '@import("vaxis")' in path.read_text())
        if top_component or presentation:
            paths.add(path)
    return sorted(path for path in paths if path.exists())


def tokens_for(source, typescript=False):
    if not typescript:
        # Preserve Zig multiline payloads as literal tokens and line numbers.
        source = re.sub(r"(?m)^([ \t]*)\\\\(.*)$",
                        lambda m: m[1] + json.dumps(m[2]), source)
        return production(lex(source))
    pattern = re.compile(
        r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|'
        r"'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|"
        r'[A-Za-z_][A-Za-z_0-9]*|=>|[^\s]', re.S)
    tokens = []
    line, end = 1, 0
    for match in pattern.finditer(source):
        line += source.count("\n", end, match.start())
        text = match[0]
        if not text.startswith(("//", "/*")):
            tokens.append(Token(text, line))
        line += text.count("\n")
        end = match.end()
    return tokens


def unquote(text):
    if text.startswith('"'):
        try:
            return json.loads(text)
        except ValueError:
            return text[1:-1]
    if text.startswith(("'", "`")):
        return text[1:-1]
    return None


def transition(tokens, relative):
    """Only one named declaration in one file owns migration spellings."""
    if relative != "src/serve_grammar.zig":
        return tokens
    names = [t.text for t in tokens]
    starts = [i for i in range(len(names) - 2)
              if names[i:i + 3] == ["pub", "const", "retired_options"]]
    if len(starts) > 1:
        raise ValueError("duplicate retired_options transition table")
    if not starts:
        return tokens
    start = starts[0]
    brace = names.index("{", start)
    end = close_brace(tokens, brace)
    header = names[start:brace + 1]
    if header != ["pub", "const", "retired_options", "=", "&", "[", "_", "]", "grammar", ".", "RetiredOption", "{"]:
        raise ValueError("retired_options must be a literal grammar.RetiredOption table")
    cursor = brace + 1
    exempt = set()

    def literal(what):
        nonlocal cursor
        if unquote(names[cursor]) is None:
            raise ValueError(f"retired option {what} must be literal")
        exempt.add(cursor)
        cursor += 1

    while cursor < end:
        # grammar.retired("flag", &.{ "PATH=VALUE", ... }, "note")
        if names[cursor:cursor + 4] != ["grammar", ".", "retired", "("]:
            raise ValueError("retired_options accepts only grammar.retired literal rows")
        cursor += 4
        literal("name")
        if names[cursor:cursor + 4] != [",", "&", ".", "{"]:
            raise ValueError("retired option requires its assignments")
        cursor += 4
        while names[cursor] != "}":
            literal("assignment")
            if names[cursor] == ",":
                cursor += 1
            elif names[cursor] != "}":
                raise ValueError("retired option assignments have unexpected code")
        cursor += 1
        if names[cursor] != ",":
            raise ValueError("retired option requires a note")
        cursor += 1
        literal("note")
        if names[cursor] == ",":
            cursor += 1
        if names[cursor] != ")":
            raise ValueError("retired option row has unexpected code")
        cursor += 1
        if names[cursor] == ",":
            cursor += 1
    return [token for index, token in enumerate(tokens) if index not in exempt]


def scan(source, relative="src/cli.zig", derived=None):
    keys, paths, shared, wire_paths = derived or facts()
    ts = relative.endswith(".ts")
    tokens = transition(tokens_for(source, ts), relative)
    names = [t.text for t in tokens]
    found = set()
    def hit(index, reason):
        found.add(f"{relative}:{tokens[index].line}: {reason}")

    # Expand both source spellings mechanically, with dynamic named map slots.
    host_paths = {tuple(snake(k) for k in path) for path in paths} | paths
    wire_paths = {tuple(snake(k) for k in path) for path in wire_paths} | wire_paths
    host_paths = {p for p in host_paths if len(p) > 1 and p not in wire_paths}
    patterns = [re.compile(r"(?<![\w.])" + r"\.".join(
        r"(?:[\w-]+|\*)" if part == "*" else re.escape(part) for part in path)
        + r"(?![\w.])") for path in host_paths]

    for i, token in enumerate(tokens):
        literal = unquote(token.text)
        if literal is not None:
            for pattern in patterns:
                if match := pattern.search(literal):
                    hit(i, "names setting path " + match[0])
            # Decoded JSON literals must not hide undotted keys via escaping.
            try:
                value = json.loads(literal)
            except (ValueError, TypeError):
                value = None
            def json_keys(value, prefix=()):
                if isinstance(value, dict):
                    for key, child in value.items():
                        path = prefix + (key,)
                        matches = any(len(path) == len(p) and all(
                            a == "*" or a == b for a, b in zip(p, path)) for p in host_paths)
                        if key in keys - shared - GENERIC or matches:
                            hit(i, "names setting JSON key " + ".".join(path))
                        json_keys(child, path)
                elif isinstance(value, list):
                    for child in value:
                        json_keys(child, prefix)
            json_keys(value)
        spelling = literal if literal is not None else token.text
        semantic_name = (literal is not None or
                         (i > 0 and names[i - 1] == ".") or
                         (i > 0 and names[i - 1] in ("const", "var")))
        if semantic_name and spelling in keys - shared - GENERIC:
            hit(i, "names setting key/name " + spelling)

        # Member chains identify group semantics even when every individual
        # field is a generic/shared word (store.sqlite.dir, tools.bash.path).
        chain = []
        j = i
        while j < len(names) and re.fullmatch(r"[A-Za-z_]\w*", names[j]):
            chain.append(names[j])
            if j + 1 >= len(names) or names[j + 1] != ".":
                break
            j += 2
        for path in host_paths:
            if len(chain) >= len(path) and all(p == "*" or p == c for p, c in zip(path, chain)):
                hit(i, "accesses setting path " + ".".join(chain[:len(path)]))

    # Track directly typed Host documents and straightforward local aliases.
    # Scope each binding to its function/block: Session settings named
    # "settings" elsewhere in cli.zig must not become Host settings by spelling.
    braces, parens = [], []
    stack = []
    for index, name in enumerate(names):
        if name in ("{", "("):
            stack.append((name, index))
        elif name in ("}", ")") and stack:
            kind, start = stack.pop()
            if (kind, name) in (("{", "}"), ("(", ")")):
                (braces if kind == "{" else parens).append((start, index))
    roots = []
    for i, name in enumerate(names):
        is_type = name == "HostSettings" or names[i:i + 3] == ["host_settings", ".", "Settings"]
        if not is_type:
            continue
        colon = next((j for j in range(i - 1, max(-1, i - 5), -1)
                      if names[j] == ":"), None)
        if colon is not None and colon > 0:
            binding = names[colon - 1]
            enclosing_parens = sorted((a, b) for a, b in parens if a < colon < b)
            if enclosing_parens:
                _, end = enclosing_parens[-1]
                scope = next(((a, b) for a, b in sorted(braces) if end < a), None)
            else:
                enclosing = sorted((a, b) for a, b in braces if a < colon < b)
                scope = enclosing[-1] if enclosing else (0, len(names))
            if scope:
                roots.append((binding, *scope))
        # A typed literal constructor also names fields without reading them.
        declaration = next((j for j in range(i - 1, -1, -1)
                            if names[j] in ("const", "let", "var", ";", "{", "(")), None)
        if declaration is not None and names[declaration] in ("const", "let", "var"):
            end = next((j for j in range(i + 1, len(names)) if names[j] == ";"), len(names))
            if "=" in names[i + 1:end]:
                equals = names.index("=", i + 1, end)
                for j in range(equals + 1, end - 1):
                    key = unquote(names[j]) or names[j]
                    if key in keys and names[j + 1] in (":", "="):
                        hit(j, "constructs HostSettings key " + key)
        # Allocator.create(host_settings.Settings), or a typed initializer.
        begin = max((j for j in range(i) if names[j] in (";", "{")), default=-1) + 1
        if begin + 2 < i and names[begin] in ("const", "let", "var") and "=" in names[begin:i]:
            enclosing = sorted((a, b) for a, b in braces if a < begin < b)
            scope = enclosing[-1] if enclosing else (0, len(names))
            roots.append((names[begin + 1], *scope))
    # A direct alias (including &root and canonical normalization) retains its
    # meaning; no hand-maintained names like settings/document are required.
    changed = True
    while changed:
        changed = False
        for i in range(len(names) - 3):
            if names[i] not in ("const", "let", "var"):
                continue
            end = next((j for j in range(i + 2, len(names)) if names[j] == ";"), len(names))
            if "=" not in names[i + 2:end]:
                continue
            equals = names.index("=", i + 2, end)
            rhs = names[equals + 1:end]
            for binding, start, stop in tuple(roots):
                if not start < i < stop or binding not in rhs:
                    continue
                # Do not taint arbitrary function results (a writer/boolean
                # may consume a document without returning one).
                direct = rhs[:1] == [binding] or rhs[:2] == ["&", binding]
                normalized = rhs[:2] == ["pipeSettings", "("]
                if not (direct or normalized):
                    continue
                if names[i + 1] == "{":
                    destructured_end = close_brace(tokens, i + 1)
                    for j in range(i + 2, destructured_end):
                        key = unquote(names[j]) or names[j]
                        if key in keys and names[j + 1] in (":", ",", "}"):
                            hit(j, "destructures HostSettings key " + key)
                    continue
                root = (names[i + 1], i, stop)
                if root not in roots:
                    roots.append(root)
                    changed = True
    for binding, start, stop in roots:
        for i in range(start, min(stop, len(names))):
            if names[i] != binding or i + 2 >= len(names):
                continue
            if names[i + 1] == "." and names[i + 2] in keys:
                hit(i + 2, "reads HostSettings key " + names[i + 2])
            if names[i + 1] == "[" and unquote(names[i + 2]) in keys:
                hit(i + 2, "indexes HostSettings key " + str(unquote(names[i + 2])))
            if names[i + 1:i + 4] in ([".", "get", "("], [".", "has", "("]) and i + 4 < len(names):
                key = unquote(names[i + 4])
                if key in keys:
                    hit(i + 4, "looks up HostSettings key " + key)
            if i > 1 and names[i - 1] == "(" and names[i - 2] in ("hasOwn", "hasOwnProperty"):
                key = unquote(names[i + 2]) if names[i + 1] == "," else None
                if key in keys:
                    hit(i + 2, "looks up HostSettings key " + key)

    # HostSettings indexed types are semantic references, including otherwise
    # shared keys. Bare opaque document types/transport are deliberately legal.
    for i, name in enumerate(names):
        if name == "HostSettings" or name == "host_settings":
            j = i + 1
            while j < len(names) and names[j] in ('"', "'", "]"):
                j += 1
            if j + 1 < len(names) and names[j] == "[":
                key = unquote(names[j + 1])
                if key in keys:
                    hit(j + 1, "indexes HostSettings key " + key)
            if name == "host_settings" and names[i + 1:i + 2] == ["."] and i + 2 < len(names):
                group = names[i + 2]
                if group[:1].lower() + group[1:] in keys:
                    hit(i + 2, "names HostSettings group type " + group)
    return sorted(found)


def violations(root=ROOT):
    derived = facts(root)
    return [hit for path in surfaces(root)
            for hit in scan(path.read_text(), path.relative_to(root).as_posix(), derived)]


if __name__ == "__main__":
    found = violations()
    if found:
        print("\n".join(found))
    sys.exit(bool(found))
