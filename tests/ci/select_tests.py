#!/usr/bin/env python3
"""Select existing build targets for fresh execution.

A changed file selects the unit roots and process fixtures that reach it
through literal imports (`Graph`), plus the targets its path rules name and
fixtures that assert text found in the changed production source.
"""
import argparse
import ast
import difflib
from functools import cache
import fnmatch
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tokenize

import build_files
from import_architecture import scoped_imports
from platform_boundary import mac_path
from qualification import RESOURCES
from strict_paths import strict
from release_numbers import SCHEMA as STORE_SCHEMA, digest_rows, migration_steps, schema_version


ROOT = Path(__file__).resolve().parents[2]
RUI = "src/cli.zig"
HOST = "src/server.zig"
CALLER = "src/client.zig"
FUNCTIONAL_CORES = "src/logic_tests.zig"
STACK_FRAMES_GATE = "tests/ci/stack_frames.json"

MODULES = {
    "url": "src/url.zig", "os": "src/os/os.zig",
    "test_poll": "src/testing/poll.zig", "h2": "src/h2/h2.zig", "tls_client": "src/tls_client/tls_client.zig", "rui_client": CALLER, "client": CALLER,
    "mysql_connection": "src/store/wire/mysql_connection.zig", "preferences": "src/preferences.zig",
    "codex_credentials": "src/codex_credentials.zig", "AnswerRenderer": "src/AnswerRenderer.zig",
    "openapi.json": "openapi.json",
}
PACKAGES = {"std", "builtin", "vaxis", "terminal_width", "terminal_unicode", "h2_c", "openssl_c", "posix",
            "transport_options", "build_options", "yaml", "sqlite", "unit_test_options", "unit_test_partition"}

UNIT_ROOTS = {
    "test-native": ("src/tests.zig", "src/unit_test_partition.zig", "src/signal_stack_probe.zig",
                    "tests/integration/answer_renderer_allocation.zig"),
    "test-store": ("src/store.zig", "src/unit_test_partition.zig"),
    "test-logic": (FUNCTIONAL_CORES, "tests/integration/answer_renderer_allocation.zig"),
    "test-h2": ("src/h2/h2.zig",),
    "test-pg": ("src/store/wire/pg.zig",),
    "mysql-wire-integration": ("tests/integration/mysql_wire_test.zig",),
}

I = "tests/integration/"
BASH = ("src/bash.zig", "src/BashLifecycle.zig", "src/deadline.zig")
MODEL = ("src/provider.zig", "src/transport_policy.zig", "src/output_decode.zig", "src/history_memo.zig",
         "src/model_capability.zig", "src/failed_responses.zig")
CREDENTIALS = ("src/codex_credential_policy.zig", "src/codex_token_wire.zig")
UPGRADE = "src/[Uu]pgrade*.zig"
FIXTURES = {
    "admission-integration": ((I + "admission_integration.sh",), (), (CALLER, HOST)),
    "admission-debug-integration": ((I + "admission_integration.sh",), (), ()),
    "dispatch-integration": ((I + "dispatch_integration.py",), (), ("src/model_adapter.zig", *MODEL)),
    "dispatch-debug-integration": ((I + "dispatch_integration.py",), (), ()),
    "cli-image-integration": ((I + "cli_image_integration.py",), (),
                              (CALLER, HOST, "src/InputCapture.zig", "src/image_intake.zig")),
    "public-parts-integration": ((I + "public_parts_integration.py",), ("src/store/tests/public_parts.zig",),
                                 ("src/store/domain/public_parts.zig", "src/protocol.zig", "src/protocol_reply.zig",
                                  "src/cli_args.zig", RUI, HOST)),
    "read-image-integration": ((I + "read_image_integration.py",), (),
                               ("src/server_read_image.zig", "src/os/read_image_file.zig", "src/input_media.zig",
                                "src/session_reads.zig", "src/part_text.zig")),
    "bash-integration": ((I + "bash_integration.py",), (), BASH),
    "bash-owner-integration": ((I + "bash_owner_integration.py",), (), BASH),
    "bash-lifecycle-integration": ((I + "bash_lifecycle_integration.py",), (), BASH),
    "bash-recovery-integration": ((I + "bash_recovery_integration.py",), (), BASH),
    "bash-environment-integration": ((I + "bash_environment_integration.py",), (),
                                     ("src/bash.zig", "src/SessionEnvironments.zig")),
    "peer-integration": ((I + "peer_integration.py",), (), ("src/bash.zig", "src/peer_message.txt")),
    "sender-identity-integration": ((I + "sender_identity_integration.py",), (), ("src/bash.zig",)),
    "codex-integration": ((I + "codex_integration.py",), (), ("src/providers.zig", *CREDENTIALS)),
    "codex-h2-integration": ((I + "codex_h2_integration.py",), (), ("src/providers.zig", *CREDENTIALS)),
    "chatgpt-plan-integration": ((I + "chatgpt_plan_integration.py",), (),
                                 ("src/providers.zig", "src/codex_auth.zig", "src/chatgpt_plan_wire.zig", *CREDENTIALS)),
    "chatgpt-login-integration": ((I + "chatgpt_login_integration.py",), (),
                                  ("src/chatgpt_plan_login.zig", "src/chatgpt_plan_wire.zig", "src/codex_auth.zig",
                                   "src/codex_credentials.zig", *CREDENTIALS)),
    "transport-h2-integration": ((I + "transport_h2_integration.py", I + "transport_h2_integration_test.py"), (),
                                 ("src/providers.zig", "src/model_adapter.zig", *MODEL)),
    "login-signal-integration": ((I + "login_signal_integration.py",), (), ()),
    "codex-credential-integration": ((I + "codex_credential_integration.py",), (I + "codex_credential_actor.zig",),
                                     ("src/providers.zig", "src/api_key.zig", "src/codex_auth.zig", *CREDENTIALS)),
    "preference-policy-integration": ((I + "preference_policy_integration.py",), (I + "preference_policy.zig",), ()),
    "mysql-wire-integration": ((I + "mysql_wire_integration.py",), (), ()),
    "skills-integration": ((I + "skills_integration.py",), (), ("src/session_skills.zig",)),
    "settings-integration": ((I + "settings_integration.py", I + "settings_mysql_integration.py",
                                  I + "settings_fixture.py", I + "store_rounds_cases.py", I + "attached_creation_cases.py"),
                                 (I + "mysql_launch_admin.zig",),
                                 ("src/host_settings.zig", "src/host_start.zig", "src/server_mcp_settings.zig", "src/mysql_url.zig", "src/mcp/Running.zig", "src/mcp/servers.zig")),
    "ts-client": ((I + "host_process.py", "clients/ts/test/settings-host.test.ts"), (), ("src/host_settings.zig",)),
    "pause-socket-test": ((I + "pause_socket_test.py", I + "pause_client.py"), ("src/pause_socket_fixture.zig",),
                          ("src/testing/pause.zig", "src/testing/pause_socket.zig")),
    "request-wait-integration": ((I + "request_wait_integration.py", I + "attached_creation_cases.py"), (),
                                 (CALLER, "src/request_wait.zig", "src/server_host.zig", "src/cli_args.zig", "src/serve_grammar.zig",
                                  "src/caller_error.zig", "src/caller_exit.zig")),
    "current-facts-integration": ((I + "current_facts_integration.py",), (), ()),
    "server-delivery-integration": ((I + "server_delivery_integration.py",), (), ()),
    "control-integration": ((I + "control_integration.py",), (), (CALLER, HOST)),
    "conversation-page-integration": ((I + "conversation_page_integration.py",), (), (CALLER, HOST)),
    "session-list-integration": ((I + "session_list_integration.py",), (I + "session_list_client.zig",), (CALLER, HOST)),
    "activity-integration": ((I + "activity_integration.py",), (I + "activity_client.zig",), (CALLER, HOST)),
    "host-status-integration": ((I + "host_status_integration.py",), (I + "host_status_actor.zig",), (CALLER, HOST)),
    "host-stop-integration": ((I + "host_stop_integration.py",), (I + "host_status_actor.zig",),
                              (CALLER, "src/HostLifecycle.zig", "src/host_activation.zig", "src/server_host.zig")),
    "host-launch-integration": ((I + "host_launch_integration.py",), (),
                                ("src/HostLifecycle.zig", "src/host_activation.zig", "src/descriptor_capacity.zig", "src/os/descriptor_limit.zig",
                                 "src/serve_grammar.zig")),
    "descriptor-capacity-integration": ((I + "descriptor_capacity_integration.py",), (),
                                        ("src/descriptor_capacity.zig", "src/os/descriptor_limit.zig")),
    "host-allocator-integration": ((I + "host_allocator_test.py",), (), ("src/os/process.zig",)),
    "host-process-test": ((I + "host_process_test.py",), (), ()),
    "installer-integration": ((I + "installer_integration.py",), (),
                              ("src/Installation.zig", "src/installation_path.zig", "src/release_candidate.zig")),
    "upgrade-integration": ((I + "upgrade_integration.py",), (), (UPGRADE, "src/HostLifecycle.zig", "src/host_activation.zig", "src/Installation.zig")),
    "terminal-restoration-integration": ((I + "terminal_restoration_integration.py",), ("src/terminal_notice_test.zig",),
                                         ("src/SessionFrontend.zig", "src/TerminalApp.zig", "src/TerminalEditor.zig")),
    "canonical-failure-integration": ((I + "canonical_failure_integration.py",), (),
                                      (CALLER, "src/SessionFrontend.zig", "src/failure_class.zig", "src/model_adapter.zig")),
    "overview-integration": ((I + "overview_integration.py", I + "overview_fixture.py", I + "overview_groups_cases.py", I + "overview_counts_cases.py",
                              I + "overview_clicks_cases.py"), (),
                             ("src/Overview.zig", "src/overview_view.zig", "src/OverviewLines.zig", "src/GroupedList.zig",
                              "src/process_memory.zig", "src/host_identity.zig", "src/host_identity.c")),
    "model-picker-integration": ((I + "model_picker_integration.py", I + "model_picker_signin_integration.py",
                                  I + "model_picker_failure_integration.py"), (),
                                 ("src/Overview.zig", "src/SessionFrontend.zig", "src/model_picker_view.zig")),
    "human-cli-integration": ((I + "human_cli_integration.py",), ("src/terminal_notice_test.zig",),
                              (CALLER, "src/SessionFrontend.zig", "src/Overview.zig", "src/request_wait.zig",
                               "src/cli_invocation.zig", "src/cli_args.zig", "src/slash_commands.zig")),
}
FIXTURE_COVERS = {"human-cli-integration": {"canonical-failure-integration", "terminal-restoration-integration"}}
TEST_CODE = ("src/*tests.zig", "src/*tests/*", "src/*_test.zig", "src/*testing.zig", "src/*testing/*", "src/mcp/test_server.zig", "src/store/engine_contract.zig",
             "src/socket_fixture.zig", "src/store/mysql_dialect_check.zig")
LINUX_ONLY = {"login-signal-integration", "mysql-wire-integration"}

EMBED = re.compile(r'@embedFile\(\s*"([^"]+)"\s*\)')
PYTHON_IMPORT = re.compile(r"^\s*(?:from\s+([A-Za-z_]\w*)\S*\s+import\b|import\s+([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*))", re.M)
SOURCE_READ = re.compile(r"\b(src/[\w./-]+)")
SOURCE_JOIN = re.compile(r'/\s*"src"\s*/\s*"([\w./-]+)"')


def uses_live_mysql(source, *, entry):
    if "MYSQL_" not in source:
        return False
    tree = ast.parse(source)
    if not entry:
        tree.body = [node for node in tree.body if not (
            isinstance(node, ast.If) and any(isinstance(part, ast.Constant) and part.value == "__main__"
                                            for part in ast.walk(node.test)))]
    nodes = list(ast.walk(tree))
    modules = {alias.asname or alias.name for node in nodes if isinstance(node, ast.Import)
               for alias in node.names if alias.name == "live_engines"}
    names = {alias.asname or alias.name for node in nodes
             if isinstance(node, ast.ImportFrom) and node.module == "live_engines"
             for alias in node.names if alias.name.startswith("MYSQL_")}
    pending = [(tree, False)]
    while pending:
        node, in_input = pending.pop()
        if (isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name)
            and node.value.id in modules and node.attr.startswith("MYSQL_")) or (
                isinstance(node, ast.Name) and node.id in names):
            return True
        if (in_input and isinstance(node, ast.Constant) and isinstance(node.value, str)
            and node.value.startswith("RUI_TEST_MYSQL_")):
            return True
        in_input = in_input or isinstance(node, (ast.Call, ast.Subscript))
        pending.extend((child, in_input) for child in ast.iter_child_nodes(node))
    return False



class Graph:

    def __init__(self, names, read):
        names = set(names)
        self.production, self.every, self.python = {}, {}, {}
        entries = {script for scripts, _, _ in FIXTURES.values() for script in scripts}
        mysql_cases = set()
        for name in sorted(names):
            if name.endswith(".zig") and name.startswith(("src/", I)):
                self.zig(name, read(name))
            elif name.startswith(I) and name.endswith((".py", ".sh")):
                source = read(name)
                if (uses_live_mysql(source, entry=name in entries) if name.endswith(".py")
                    else "RUI_TEST_MYSQL_" in source):
                    mysql_cases.add(name)
                strings = (" ".join(token.string for token in tokenize.generate_tokens(io.StringIO(source).readline)
                                    if token.type == tokenize.STRING) if name.endswith(".py") else source)
                self.python[name] = ({f"{I}{module}.py" for match in PYTHON_IMPORT.finditer(source)
                                      for module in (match[1] and [match[1]] or re.split(r"\s*,\s*", match[2]))}
                                     | set(SOURCE_READ.findall(strings))
                                     | {"src/" + joined for joined in SOURCE_JOIN.findall(source)}) & names - {name}
            elif name in entries and name.endswith(".ts"):
                self.python[name] = set()
                if "RUI_TEST_MYSQL_" in read(name):
                    mysql_cases.add(name)
        self.compiled = set(self.every).union(*self.every.values())
        self.cores = {"src/" + core for core in re.findall(
            r'\.\{ "([^"]+\.zig)", @import', read(FUNCTIONAL_CORES).split("const cores = .{", 1)[1].split("\n};", 1)[0])}
        self.tests = {name for name in self.production if matches(name, TEST_CODE)}
        product = {source: targets - self.tests for source, targets in self.production.items() if source not in self.tests}
        modules = json.loads(read(STACK_FRAMES_GATE))["host_modules"] if STACK_FRAMES_GATE in names else []
        host = [HOST, *(name for module in modules for name in self.production
                        if f"/{name}".endswith("/" + module.replace(".", "/") + ".zig"))]
        self.host = self.closure(product, host)
        rui = self.closure(product, [RUI])
        callers = {}
        for source, targets in product.items():
            for target in targets:
                callers.setdefault(target, set()).add(source)
        self.reached = {target: self.closure(self.every, roots) for target, roots in UNIT_ROOTS.items()}
        conformance = [name for name in self.reached["test-native"]
                       if name.startswith("src/") and not name.startswith("src/store/")
                       and name.endswith(".zig") and name in names
                       and re.search(r'\b\w+\.forEachEngine\s*\(', read(name))]
        self.live_conformance = self.closure(self.every, conformance)
        self.driven, self.owners, self.live_mysql = {}, {}, set()
        for target, (scripts, executables, owners) in FIXTURES.items():
            if self.scripts(scripts) & mysql_cases:
                self.live_mysql.add(target)
            self.owners[target] = {name for name in names if matches(name, owners)}
            owners = [*self.owners[target], *(host if HOST in owners else ())]
            self.reached[target] = self.reached.get(target, set()) | self.scripts(scripts)
            dispatch = self.closure(callers, owners) & (self.host | {RUI})
            self.driven[target] = ((self.closure(product, owners) | dispatch) & rui
                                   | self.closure(self.production, executables))

    def zig(self, name, source):
        production, tested, _ = scoped_imports(source)
        directory = Path(name).parent

        def resolve(imported):
            if imported in MODULES:
                return {MODULES[imported]}
            if imported in PACKAGES:
                return set()
            if not imported.endswith(".zig"):
                raise ValueError(f"{name} imports module {imported!r}: name its file in select_tests.MODULES "
                                 "or list it in PACKAGES")
            return {os.path.normpath(directory / imported)}

        embedded = {MODULES.get(path) or os.path.normpath(directory / path) for path in EMBED.findall(source)}
        self.production[name] = embedded.union(*map(resolve, production))
        self.every[name] = self.production[name].union(*map(resolve, tested))

    def scripts(self, scripts):
        return self.closure(self.python, scripts)

    @staticmethod
    def closure(edges, roots):
        reached, pending = set(), list(roots)
        while pending:
            name = pending.pop()
            if name not in reached:
                reached.add(name)
                pending.extend(edges.get(name, ()))
        return reached

    def targets(self, path):
        if not (path in self.production or path in self.python
                or any(path in edges for graph in (self.every, self.python) for edges in graph.values())):
            return None
        return ({target for target, reached in self.reached.items() if path in reached}
                | {target for target, driven in self.driven.items()
                   if path in driven and (path not in self.cores or path in self.owners[target])})


@cache
def tree_graph():
    tracked = subprocess.check_output(["git", "-C", str(ROOT), "ls-files", "-z"]).decode().split("\0")
    return Graph([name for name in tracked if name and (ROOT / name).is_file()], lambda name: (ROOT / name).read_text())


def script_literals(source, suffix):
    if suffix == ".py":
        return {node.value for node in ast.walk(ast.parse(source))
                if isinstance(node, ast.Constant) and isinstance(node.value, str)}
    return {single or double for single, double in re.findall(
        r''''((?:\\.|[^'\\])*)'|"((?:\\.|[^"\\])*)"''', source)}


def fixture_text(literal):
    text = literal.strip()
    return text if len(text) >= 12 and " " in text else ""


def source_strings(source):
    tokens = re.finditer(r'//[^\n]*|"(?:\\.|[^"\\])*"|\\\\[^\n]*', source)
    return "\n".join(token[1:-1] if token.startswith('"') else token[2:]
                     for match in tokens if not (token := match.group()).startswith("//"))


@cache
def tree_fixture_literals():
    return {target: {text for script in tree_graph().scripts(scripts)
                     if Path(script).suffix in {".py", ".sh"} and (ROOT / script).is_file()
                     for literal in script_literals((ROOT / script).read_text(), Path(script).suffix)
                     if (text := fixture_text(literal))}
            for target, (scripts, _, _) in FIXTURES.items()}


@cache
def tree_uncommon_texts(candidates):
    if not candidates:
        return frozenset()
    counts = dict.fromkeys(candidates, 0)
    tracked = subprocess.check_output(["git", "-C", str(ROOT), "ls-files", "-z", "src/"]).decode().split("\0")
    for name in tracked:
        if not name or matches(name, TEST_CODE) or not (ROOT / name).is_file():
            continue
        source = source_strings((ROOT / name).read_text(encoding="utf-8", errors="surrogateescape"))
        for text, count in counts.items():
            if count < 3 and text in source:
                counts[text] += 1
    return frozenset(text for text, count in counts.items() if count < 3)


CLI_GRAMMAR = ("src/cli_grammar.zig", "src/cli_option_names.zig", "src/serve_grammar.zig")

UPGRADE_PATHS = (UPGRADE, "src/installation_path.zig", "src/TerminalEditor.zig", "src/Installation.zig", "src/release_candidate.zig",
                 "src/HostLifecycle.zig", "src/host_activation.zig", "src/host_identity.zig",
                 "src/host_identity.c", "src/stderr.zig", "src/host_launch.c",
                 "src/cli.zig", "src/cli_args.zig", *CLI_GRAMMAR, "src/client.zig", "src/slash_commands.zig",
                 "src/Overview.zig", "src/overview_view.zig", "src/SessionFrontend.zig",
                 "tests/integration/upgrade_integration.py", "release/*", "install.sh", "build.zig")

INSTALLER_PATHS = ("tests/integration/installer_integration.py", "tests/ci/fake_rui.py",
                   "tests/ci/test_install.py", "tests/ci/test_installer_boundary.py", "tests/ci/test_release.py",
                   "tests/ci/release.py", "tests/ci/release_publication.py", "tests/ci/git_command.py", "tests/ci/test_release_publication.py", "tests/ci/release_numbers.py", "tests/ci/qualification.py",
                   "src/Installation.zig", "src/installation_path.zig", "src/release_candidate.zig",
                   "src/cli.zig", "src/cli_args.zig", *CLI_GRAMMAR, "src/store/schema.zig",
                   "src/fetch_dependencies.sh", "release/*", "install.sh", "build.zig", "build.zig.zon")

UPGRADE_CHECK_PATHS = (UPGRADE, "src/Installation.zig", "src/installation_path.zig", "src/release_candidate.zig",
                       "src/HostLifecycle.zig", "src/host_activation.zig", "src/host_identity.*", "src/host_launch.c",
                       "src/store/migration_*", "install.sh", "release/*", "build.zig", "build.zig.zon",
                       "tests/integration/previous_release_upgrade.py", ".github/workflows/previous-release-upgrade.yml")


def store_format(source):
    return schema_version(source), digest_rows(source), migration_steps(source)


def store_format_changed(path, before, after):
    return before is None or after is None or store_format(before) != store_format(after)


CACHE_CONFIG = ("build.zig", "build/*.zig", ".github/actions/*", ".github/workflows/*.yml")
SETUP_CACHE_LINE = re.compile(r"cache", re.IGNORECASE)
CACHE_LINE = re.compile(r"zig[-_ ]?cache|\.cache/zig|cache[-_]dir|cache_root|has_side_effects|ci-compiled|build-cache"
                        r"|publish-caches|cache-execution", re.IGNORECASE)
CACHE_POLICY = (".github/actions/setup/caches/save-keys.cjs", ".github/scripts/prune-caches.cjs", "tests/ci/cache_execution.py", "tests/ci/zig_cache_restat.c",
                "tests/ci/run_selected.py", "tests/ci/cache_snapshot.py")
ACCEPTANCE_INPUTS = ("build.zig", "build/ci.zig", "build/darwin.zig", "tests/ci/native_acceptance_test.py")


def code_lines(source):
    return [line for line in (source or "").splitlines() if line.strip() and not line.lstrip().startswith(("#", "//"))]


def workflow_job(source, name):
    match = re.search(rf"(?ms)^  {re.escape(name)}:\n.*?(?=^  [A-Za-z_][\w-]*:\n|\Z)", source or "")
    return code_lines(match[0]) if match else None


def yaml_context(lines, index):
    def indent(line):
        return len(line) - len(line.lstrip())
    context, level, item = [lines[index]], indent(lines[index]), index if lines[index].lstrip().startswith("- ") else None
    for above in range(index - 1, -1, -1):
        if indent(lines[above]) < level:
            context.append(lines[above])
            level = indent(lines[above])
            if item is None and lines[above].lstrip().startswith("- "):
                item = above
    if item is not None:
        end = item + 1
        while end < len(lines) and indent(lines[end]) > indent(lines[item]):
            end += 1
        context += lines[item:end]
    return context


def sqlite_pin(source):
    match = re.search(r'\.sqlite\s*=\s*\.\{[^}]*\}', source or "")
    return match.group(0) if match else None


def sqlite_pin_changed(path, before, after):
    return sqlite_pin(before) != sqlite_pin(after)


def cache_policy_changed(path, before, after):
    pattern = SETUP_CACHE_LINE if path.startswith(".github/actions/") else CACHE_LINE
    old, new = code_lines(before), code_lines(after)
    changed = []
    for tag, old_start, old_end, new_start, new_end in difflib.SequenceMatcher(None, old, new, autojunk=False).get_opcodes():
        if tag != "equal":
            changed += [(old, index) for index in range(old_start, old_end)] + [(new, index) for index in range(new_start, new_end)]
    context = (yaml_context if path.endswith(".yml") else lambda lines, index: [lines[index]])
    return (any(pattern.search(line) for lines, index in changed for line in context(lines, index))
            or workflow_job(before, "cache_execution") != workflow_job(after, "cache_execution"))


CONTENT_RULES = {
    "store_format": ((STORE_SCHEMA,), store_format_changed),
    "cache_policy": (CACHE_CONFIG, cache_policy_changed),
    "sqlite_pin": (("build.zig.zon",), sqlite_pin_changed),
}

RENDERER_HARNESSES = ("tests/integration/input_equivalence.py",)

# What the build itself reads beyond the import graph: the build scripts, dependency pins and
# fetch, the compiler and cache setup, and the CI producer that writes the zig command.
BOOTSTRAP_INPUTS = ("build.zig", "build.zig.zon", "install.sh", "src/fetch_dependencies.sh", "src/build_*",
                    "src/*.patch", ".agents/setup", ".github/actions/setup/action.yml", "screen-emulator/*",
                    "tests/ci/build_artifact.py", "tests/ci/cache_snapshot.py")

RULES = (
    (INSTALLER_PATHS, ("installer-integration",), ("installer-integration",),
     "Installer: real publication and PATH boundary"),
    (UPGRADE_PATHS, ("upgrade-integration",), ("upgrade-integration",),
     "Stable upgrade: installed binary, lifecycle and installer boundary"),
    (CLI_GRAMMAR[:2], ("human-cli-integration", "request-wait-integration"), ("human-cli-integration", "request-wait-integration"),
     "The option grammar engine every human CLI command and request wait parse with"),
    (("src/models_dev.zig", "src/model_catalog*.zig"), ("test-logic",), ("test-logic",),
     "Shipped model facts and the models.dev token-walk parser, without production callers"),
    (("src/model_list.zig",), ("codex-h2-integration",), ("codex-h2-integration",),
     "Provider model lists: the Host's fetch and the wire reply follow"),
    (RENDERER_HARNESSES, (), (), "Renderer harnesses: only the promotion renderer contracts run them"),
    (("src/openapi*.zig", "openapi.json"), ("test",), ("test",),
     "WIR-4 published request schemas and generated wire contract"),
    (("clients/ts/*",), ("ts-client",), ("ts-client",), "The TypeScript client and its launch of a real Host"),
    (("clients/ts/test/fixtures/empty-creation.ts", "clients/ts/test/fixtures/preferences-bridge.ts"),
     ("settings-integration",), ("settings-integration",),
     "Three-client creation parity uses the TypeScript helper against both Store engines"),
    (("tests/integration/mcp_sdk/*",), ("settings-integration", "ts-client"), ("settings-integration", "ts-client"),
     "The MCP SDK servers a settings document starts"),
    (("src/mcp/*", "src/http1/*"), ("settings-integration",), ("settings-integration",),
     "The MCP and HTTP/1.1 clients, value cores included, against the real MCP SDK servers"),
    (("src/environment.zig",), ("bash-integration", "bash-environment-integration"),
     ("bash-integration", "bash-environment-integration"),
     "The Bash child environment core; Bash and peer calls read what it builds"),
    (("src/bash_platform.c",),
     ("test", "bash-owner-integration", "bash-lifecycle-integration", "bash-recovery-integration", "bash-integration"),
     ("test", "bash-owner-integration", "bash-lifecycle-integration", "bash-recovery-integration", "bash-integration"),
     "Bash's native platform adapter, linked into the unit roots and Rui"),
    (("src/host_launch.c", "src/host_identity.c"),
     ("test", "host-launch-integration", "descriptor-capacity-integration", "codex-h2-integration", "transport-h2-integration"),
     ("test", "host-launch-integration", "descriptor-capacity-integration", "codex-h2-integration", "transport-h2-integration"),
     "Host launch adapters: every startup refusal boundary and managed transport"),
    (("src/os/*",), ("codex-credential-integration", "codex-h2-integration", "transport-h2-integration"),
     ("codex-credential-integration", "codex-h2-integration", "transport-h2-integration"),
     "Platform boundary: the managed transport and credential store it serves on each OS"),
    (("src/descriptor*", "src/os/descriptor_limit.zig", "src/server*.zig", "src/platform.zig", "src/cli.zig",
      "tests/integration/descriptor*", "tests/integration/host_launch*", "src/product_defaults.zig",
      "tests/integration/product_defaults.py"),
     ("test", "host-launch-integration", "descriptor-capacity-integration", "codex-h2-integration", "transport-h2-integration"),
     ("test", "host-launch-integration", "descriptor-capacity-integration", "codex-h2-integration", "transport-h2-integration"),
     "Startup capacity: every refusal boundary, managed transport and its companion oracle"),
    (("src/model_instructions.txt", "src/model_instructions/*.txt"),
     ("transport-h2-integration", "codex-h2-integration", "current-facts-integration",
      "server-delivery-integration", "measurement-check"),
     ("transport-h2-integration", "codex-h2-integration", "current-facts-integration",
      "server-delivery-integration", "measurement-check"),
     "Shared model context prose: fixture consumers and Go request oracles"),
    (("src/server*.zig", "src/cli.zig", "src/cli_args.zig", *CLI_GRAMMAR, "src/client.zig", "src/caller_*.zig", "src/cli_value.zig",
      "src/slash_commands.zig", "src/protocol_reply.zig", "src/ResponseTiming.zig", "src/preferences.zig", "src/preference_document.zig",
      "src/defaults_report.zig",
      "src/provider_selection.zig", "src/client_defaults.zig", "src/configure_input.zig", "src/new_session_selection.zig",
      "src/preference_values.zig", "src/product_defaults.zig", "tests/integration/product_defaults.py"),
     ("admission-debug-integration",), ("admission-debug-integration",),
     "Admission, capture and CLI selection: the complete Debug recovery matrix"),
    (("src/cli.zig", "src/cli_args.zig", *CLI_GRAMMAR, "src/cli_value.zig", "src/client.zig", "src/client_defaults.zig",
      "src/configure_input.zig", "src/product_defaults.zig", "src/protocol.zig", "src/store/domain/configuration.zig", "openapi.json"),
     ("measurement-check",), ("measurement-check",),
     "CLI configuration surface: the measurement runners' configure call against the current CLI"),
    (("src/store.zig", "src/store/*", "!src/store/wire/*"), ("dispatch-debug-integration",), ("dispatch-debug-integration",),
     "Store SQL owners: Debug failure provenance through SQLite"),
    (("tests/integration/check.sh",), ("check-full",), ("check-full",),
     "Shared process inventory: native cases once, scheduling modes checked by driver tests"),
    (("tests/integration/login_signal_integration.py", "build.zig"), ("login-signal-integration",), (),
     "Linux-only native login signal loader witness"),
    (("tests/integration/current_facts_integration.py", "build.zig"),
     ("current-facts-integration",), ("current-facts-integration",), "Current producer/consumer oracle"),
    (("tests/integration/server_delivery_integration.py", "build.zig"),
     ("server-delivery-integration",), ("server-delivery-integration",), "Real reply inactivity and Host drain"),
    (("tests/integration/canonical_failure_integration.py", "build.zig"),
     ("canonical-failure-integration",), ("canonical-failure-integration",), "Canonical failure caller oracle"),
    (BOOTSTRAP_INPUTS,
     ("check-full", "admission-debug-integration", "test-full"),
     ("check-full", "admission-debug-integration", "test-full"),
     "Build, dependency or bootstrap inputs"),
    (("build.zig", "build.zig.zon", "install.sh", "src/fetch_dependencies.sh", "src/build_transport.sh", ".agents/setup",
      ".github/actions/setup/action.yml"),
     ("transport-h2-integration", "codex-h2-integration"),
     ("transport-h2-integration", "codex-h2-integration"), "Transport build and managed TLS/H2 bootstrap"),
    (("release/publish.sh",), ("host-status-integration",), ("host-status-integration",),
     "Installer report reads the CLI's defaults and Host status JSON"),
)

RULES += ((('src/host_reply.zig', 'src/command_reply.zig', 'src/command_spec.zig',
            'src/store/domain/command.zig', 'src/session_skills.zig'),
           ('request-wait-integration', 'skills-integration'), (),
           'Message input identity and skill binding remain valid through admission and recovery'),)

RULES += ((("src/InputCapture.zig", "src/client.zig", "src/mutation_answer.zig", "src/cli_args.zig", "src/cli_grammar.zig"),
           ("test-native", "cli-image-integration", "human-cli-integration", "request-wait-integration", "read-image-integration",
            "session-list-integration", "dispatch-integration", "codex-integration"),
           ("test-native", "cli-image-integration", "human-cli-integration", "request-wait-integration", "read-image-integration",
            "session-list-integration", "dispatch-integration", "codex-integration"),
           "Ordered message capture, recovery and provider delivery invariants"),)

LIVE_MYSQL_DIALECT_TARGETS = frozenset({"test", "test-store", "check", "check-full"})
LIVE_POSTGRES_TARGETS = frozenset({"test-pg", "check", "check-full"})

LIVE_RULES = (
    (("src/host_settings.zig", "src/host_start.zig", "src/server_mcp_settings.zig", "src/mysql_url.zig", "tests/integration/settings*", "tests/integration/mysql_launch_admin.zig", "tests/integration/attached_creation_cases.py"),
     ("test", "settings-integration"), ("settings-integration",),
     "The settings-document Host opens a live MySQL Store on Linux; macOS skips the live server",
     frozenset({"settings-integration", "check", "check-full"})),
    (("src/store/wire/pg*.zig", "src/store/wire/scram.zig", "src/store/wire/tls.zig", "src/tls_client/*",
      "tests/integration/live_engines.py", "tests/ci/live_engine_step.py"),
     ("test-pg",), ("test-pg",), "The Postgres wire client's own tests, live against postgres:15 on Linux",
     LIVE_POSTGRES_TARGETS),
    (("src/store/wire/mysql.zig", "src/store/wire/mysql_connection.zig", "src/store/wire/tls.zig", "tests/integration/mysql_wire*",
      "tests/integration/mysql_server.py", "build.zig"),
     ("test-logic", "mysql-wire-integration"), ("test-logic",),
     "MySQL wire client: replayed exchanges and a real MySQL 8.4 server (Docker, Linux only)",
     frozenset({"mysql-wire-integration"})),
    (("src/store.zig", "src/store/*", "!src/store/wire/pg*.zig", "!src/store/wire/scram.zig",
      "!src/store/wire/tls.zig", "tests/integration/mysql_server.py",
      "tests/integration/live_engines.py", "tests/ci/live_engine_step.py"),
     ("test-store",), (),
     "The Store's live MySQL dialect check drives MySQL 8.4 through the wire client; macOS skips it",
     LIVE_MYSQL_DIALECT_TARGETS),
)
RULES += tuple(rule[:4] for rule in LIVE_RULES)
RULES += ((("src/store.zig", "src/store/*", "!src/store/wire/*", "src/server_execution.zig", "src/execution_turn.zig",
            "src/model_adapter.zig", "tests/integration/store_rounds_cases.py"),
           ("settings-integration",), (),
           "The Store's MySQL round trips per model operation and while idle stay within their budget"),)

BUILD_HUB = "build.zig"
SETUP_PARTS = ".github/actions/setup/*/action.yml"
FIXTURE_TABLE = "build/fixtures.zig"
FIXTURE_ROW = re.compile(r'^ *\.\{ \.step = "([a-z0-9-]+)",.*\},\n', re.M)


def fixture_rows(before, after):
    before, after = before or "", after or ""
    if FIXTURE_ROW.sub("", before) != FIXTURE_ROW.sub("", after):
        return None
    rows = {match[1]: match[0] for match in FIXTURE_ROW.finditer(before)}
    return {match[1] for match in FIXTURE_ROW.finditer(after) if rows.get(match[1]) != match[0]}


BUILD_MODULES = {
    "build/product.zig": BUILD_HUB,
    "build/ci.zig": BUILD_HUB,
    "build/screen.zig": ("check-full", "skills-integration", "upgrade-integration"),
    "build/unit.zig": ("test", "test-full", "test-logic", "test-h2", "test-pg", "mysql-wire-integration"),
    "build/measurement.zig": ("measurement-check",),
    FIXTURE_TABLE: tuple(sorted(step for step, owner in build_files.steps().items() if owner == FIXTURE_TABLE)),
    "build/cross.zig": (),
    "build/darwin.zig": ("test", "host-launch-integration"),
    ".github/actions/setup/caches/action.yml": ("test-logic",),
    ".github/actions/setup/caches/save-keys.cjs": ("test-logic",),
    ".github/actions/setup/fixtures/action.yml":
        ("dispatch-integration", "measurement-check", "ts-client", "upgrade-integration"),
}
RULES += tuple(((module,), targets, tuple(target for target in targets if target not in LINUX_ONLY),
                "Build module: the targets it defines or builds for")
               for module, targets in BUILD_MODULES.items() if targets != BUILD_HUB)


STACK_FRAMES = ("src/*", "build.zig", "build.zig.zon", "tests/ci/stack_frames.py", "tests/ci/stack_frames.json")

CHECK_COVERS = {
    "test", "test-native", "test-store", "test-h2", "test-pg", "admission-integration", "dispatch-integration",
    "read-image-integration", "bash-owner-integration", "bash-lifecycle-integration", "bash-recovery-integration",
    "bash-integration", "bash-environment-integration", "codex-integration", "control-integration",
    "host-status-integration", "host-launch-integration", "host-stop-integration",
    "descriptor-capacity-integration", "request-wait-integration", "pause-socket-test",
    "activity-integration", "preference-policy-integration", "session-list-integration",
    "peer-integration", "sender-identity-integration", "conversation-page-integration",
    "host-allocator-integration", "host-process-test", "human-cli-integration", "model-picker-integration",
    "canonical-failure-integration",
    "terminal-restoration-integration",
}



TYPECHECK_INPUTS = ("*.zig", "*.zon", "*.c", "*.h", "src/*.patch", "src/*.sh", ".github/actions/setup/action.yml")


CLIENT_LOCALITY_INPUTS = ("src/*.zig", "clients/ts/src/*", "tests/ci/client_locality.py",
                          "tests/ci/test_client_locality.py", "tests/ci/caller_errors.py", "tests/ci/host_settings_locality.py",
                          "tests/ci/select_tests.py", "tests/ci/import_architecture.py", STACK_FRAMES_GATE)


# The CI-code inputs every module declared with the table reads: a change to CI code or to a workflow reruns it.
CI_CODE_INPUTS = ("tests/ci/*", ".github/*")

# Each module's inputs. Rule: a module is declared only if every repo file it reads is named by a path literal or
# glob in its own test file. A module that reads through a helper (a tests/ci or tests/integration module that
# scans the tree, git over the tree, a fixture the module or the script it runs imports, or the build graph) is
# not declared, so it always runs. test_store_engine_boundary and test_promotion meet the rule: their reads are
# src/store and their own tests/ci helpers, which CI_CODE_INPUTS covers. test_docs_only is not declared: its path
# literals are fixture names in temporary repositories, which the literal guard in test_selection.py would require
# to be repo inputs.
POLICY_SELF_CHECKS = (
    ("test_selection.FullCheckPartitionTest",
     ("tests/ci/*", "build.zig", "tests/integration/check.sh", "tests/integration/host_process.py",
      "tests/integration/live_engines.py", "tests/integration/requirements.txt", "src/wire_version.zig")),
    ("test_admission", ("tests/ci/*", ".github/*", "build.zig")),
    ("test_release_publication", ("tests/ci/*",)),
    ("test_build_artifact", ("tests/ci/*",)),
    ("test_client_locality", CLIENT_LOCALITY_INPUTS),
    # TLC runs only when a model, its runner or its CI wrapper changes.
    ("test_formal_models", ("tests/formal/*", "tests/ci/test_formal_models.py")),
    # Runs only in-process fake repositories and fake steps; reads no repo file outside tests/ci.
    ("test_promotion", CI_CODE_INPUTS),
    # Reads src/store/** only.
    ("test_store_engine_boundary", (*CI_CODE_INPUTS, "src/store*")),
)


SCREEN_TARGETS = frozenset({"check", "check-full", "terminal-restoration-integration", "canonical-failure-integration",
                            "host-launch-integration", "upgrade-integration", "human-cli-integration", "overview-integration",
                            "model-picker-integration", "read-image-integration", "settings-integration",
                            "skills-integration", "bash-recovery-integration", "renderer-contracts-selftest",
                            "direct-pty", "direct-pty-controls", "input-equivalence", "screen-emulator",
                            "peer-integration"})


def setup_requirements(targets):
    return {"go": bool(({"measurement-check"} | set(RESOURCES)).intersection(targets)), "node": bool({"ts-client", "settings-integration", "check", "check-full"}.intersection(targets)), "python": bool(targets), "screen": bool(SCREEN_TARGETS.intersection(targets)), "tmux": "upgrade-integration" in targets}


def execution_batches(targets, check_part="all"):
    if check_part != "all" and "check-full" not in targets:
        raise ValueError("A full-check part requires check-full in the selection")
    if check_part == "execution":
        return [["check-full", "-Dcheck-part=execution"],
                *execution_batches([target for target in targets if target != "check-full"])]
    if check_part not in {"all", "callers"}:
        raise ValueError(f"Unknown full-check part: {check_part}")
    isolated = {"check", "check-full", "admission-debug-integration", "test-full",
                "host-launch-integration", "server-delivery-integration",
                "transport-h2-integration", "codex-h2-integration", "upgrade-integration"}
    shared = [target for target in targets if target not in isolated]
    return (([shared] if shared else [])
            + [[target, "-Dcheck-part=callers"] if target == "check-full" and check_part == "callers"
               else [target] for target in targets if target in isolated])


def matches(path, patterns):
    included = any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns if not pattern.startswith("!"))
    return included and not any(fnmatch.fnmatchcase(path, pattern[1:]) for pattern in patterns if pattern.startswith("!"))


def mysql_provisioning(targets, part, platform, mysql_suites):
    """Which live engine servers a Linux shard starts."""
    targets = set(targets)
    linux = platform == "linux"
    dialect = linux and bool(
        targets & (LIVE_MYSQL_DIALECT_TARGETS - {"check-full"})
        or "check-full" in targets and part != "callers")
    return {"live_mysql": linux and (dialect or bool(targets & mysql_suites)),
            "mysql_dialect": dialect,
            "live_postgres": linux and bool(targets & (LIVE_POSTGRES_TARGETS - {"check-full"})
                                            or "check-full" in targets and part != "callers")}


def live_mysql_suites(targets, mysql_suites):
    targets = set(targets)
    selected = targets | (CHECK_COVERS if "check-full" in targets else set())
    suites = selected & set(mysql_suites)
    return suites


def covers(target, targets) -> bool:
    """Whether a selected target executes target's checks.

    check-full deliberately excludes stack-frames and rsql-table; promotion adds them separately.
    """
    broader = {"test": {"test-native", "test-store"},
               "check": CHECK_COVERS | {"stack-frames", "rsql-table"},
               "check-full": CHECK_COVERS | {"check"}, **FIXTURE_COVERS}
    return target in targets or any(target in broader.get(selected, ()) for selected in targets)


def normalize(targets: set) -> set:
    """Return a fresh selection with checks covered by broader targets removed."""
    checks = set(targets)
    if {"test-native", "test-store"} <= checks:
        checks.add("test")
    covered = {case for cases in FIXTURE_COVERS.values() for case in cases if covers(case, checks)}
    if CHECK_COVERS - UNIT_ROOTS.keys() - {"test"} <= checks | covered:
        checks.add("check")
    if "check-full" in checks:
        checks.discard("check")
    return {target for target in checks if not covers(target, checks - {target})}


# The PR tier runs unit roots and the fixtures whose own sources changed; everything else,
# including every whole-suite gate and live-server suite, runs on main and in promotion.
WHOLE_SUITE_GATES = frozenset({"check", "check-full", "test", "test-full"})
PR_UNIT_ROOTS = frozenset({"test-native", "test-store", "test-logic", "test-h2", "test-pg"})
# Store unit tests run on a PR only for a change to the Store itself.
STORE_PATHS = ("src/store.zig", "src/store/*")


def own_fixture(target, paths):
    """Whether the diff touches the fixture's own script, executable or FIXTURES owner."""
    scripts, executables, owners = FIXTURES[target]
    return any(matches(path, (*scripts, *executables, *owners)) for path in paths)


def fast_tier(targets, paths, bootstrap_only=False, store=False):
    """The PR tier of a raw (unnormalized) selection.

    It keeps the unit roots the diff reaches (a whole-suite gate becomes
    `test-native` and `test-logic`, or only `test-logic` when bootstrap inputs
    alone selected it; `test-store` only for Store paths or a SQLite pin change) and the fixtures
    whose own sources the diff touches. A fixture the diff reaches only
    through imports runs on main and in promotion, never on the PR.
    """
    targets = set(targets)
    fast = targets & PR_UNIT_ROOTS
    if targets & WHOLE_SUITE_GATES:
        # A bootstrap-only change still compiles and runs one Store-free root through the
        # changed setup and producer; the other Store-reaching binaries run on main.
        fast |= {"test-logic"} if bootstrap_only else {"test-native", "test-logic"}
    # A SQLite pin change keeps test-store: the Store suite is the engine's test.
    if not (store or any(matches(path, STORE_PATHS) for path in paths)):
        fast.discard("test-store")
    fast |= {target for target in targets & FIXTURES.keys() - PR_UNIT_ROOTS - {"mysql-wire-integration"}
             if own_fixture(target, paths)}
    for broad, covered in FIXTURE_COVERS.items():
        if broad in fast:
            fast -= covered
    return sorted(fast)


def select(paths, phase, available, graph=None, contents=None, fixture_literals=None):
    graph = graph or tree_graph()
    changed = list(paths)
    build_paths = [BUILD_HUB if BUILD_MODULES.get(path) == BUILD_HUB else path for path in paths]
    # A core imported by the build still needs its own boundary tests.
    paths = list(dict.fromkeys([*build_paths, *(path for path in paths if path in graph.cores)]))
    contents = contents or {}
    rows = fixture_rows(*contents[FIXTURE_TABLE]) if FIXTURE_TABLE in paths and FIXTURE_TABLE in contents else None
    content_changed = {rule for rule, (patterns, changed) in CONTENT_RULES.items()
                       if any(matches(path, patterns) and (path not in contents or changed(path, *contents[path]))
                              for path in paths)}
    targets, native_targets, reasons = set(), set(), set()
    live_targets, live_reasons = set(), set()
    live_needs = set()
    manual_checks = set()
    linux_memory_checks = False
    for path in paths:
        if path == FIXTURE_TABLE and rows is not None:
            continue
        reached = graph.targets(path)
        shortcut = False
        if path.endswith(".md") or path.startswith(("docs/", "research/")):
            reasons.add("Documentation: references and diff whitespace, no runtime change")
            shortcut = True
        elif (path in graph.host if path.startswith("src/") and path.endswith(".zig")
              else any(fnmatch.fnmatchcase(path, pattern) for pattern in STACK_FRAMES)):
            targets.add("stack-frames")
            reasons.add("Host stack frames: the ReleaseSafe frame gate (tests/ci/stack_frames.py)")
        if (path.startswith((".github/", "tests/ci/")) and path != ".github/actions/setup/action.yml"
                or path == "tests/integration/previous_release_upgrade.py"):
            reasons.add("CI policy: the policy job runs selector and workflow checks")
            shortcut = True
        matched = shortcut
        for patterns, checks, native_checks, reason in RULES:
            if matches(path, patterns):
                targets.update(checks)
                native_targets.update(native_checks)
                reasons.add(reason)
                matched = True
        for patterns, checks, _, reason, served_by in LIVE_RULES:
            if matches(path, patterns):
                live_targets.update(set(checks) & served_by)
                live_reasons.add((reason, served_by))
                live_needs.update((root, reason) for root in set(checks) & served_by)
        if path in graph.live_conformance and path not in graph.reached["test-store"]:
            targets.add("test")
            native_targets.add("test")
            live_targets.add("test")
            live_needs.add((None, "Native Store conformance tests require live MySQL"))
            live_reasons.add(("Native Store conformance tests require live MySQL", LIVE_MYSQL_DIALECT_TARGETS))
            reasons.add("Native Store conformance tests require live MySQL")
            matched = True
        if shortcut:
            continue
        if reached:
            targets.update(reached)
            native_targets.update(reached - LINUX_ONLY)
            reasons.add("Import graph: the unit roots and fixtures that reach the changed file")
            matched = True
        if path.startswith("tests/qualification/"):
            if path.endswith((".go", "go.mod", "go.sum")):
                targets.add("measurement-check")
                native_targets.add("measurement-check")
                reasons.add("Measurement code: pinned Go package checks")
            elif path.endswith((".py", ".c", ".sh", ".zig", ".patch")):
                targets.add("test-logic")
                linux_memory_checks |= path.startswith("tests/qualification/linux-memory/")
                manual_checks.add(f"{path}: syntax/compilation and reviewer-selected affected diagnostic when measurement claims change")
                reasons.add("Qualification executable: cheap checks do not qualify its measurement claims")
            continue
        if not matched and path.startswith("tests/integration/"):
            candidate = Path(path).stem.replace("_", "-")
            targets.add(candidate if candidate in available else "check")
            native_targets.add(candidate if candidate in available else "check")
            reasons.add("Maintained integration target or full fallback")
            matched = True
        if not matched and path.startswith("src/"):
            targets.add("check")
            native_targets.add("check")
            reasons.add("Source no import or rule reaches: full fallback")
        if path in ("src/client.zig", "src/ResponseTiming.zig"):
            targets.add("test-full")
            native_targets.add("test-full")
    if rows:
        targets.update(rows)
        native_targets.update(rows - LINUX_ONLY)
        reasons.add("Fixture table: the fixtures whose rows changed")
    if "sqlite_pin" in content_changed:
        targets.add("test-store")
        reasons.add("SQLite pin: the Store suite runs against the new engine")
    source_changes = [contents[path] for path in paths
                      if path.startswith("src/") and not matches(path, TEST_CODE) and path in contents]
    if source_changes:
        literals = tree_fixture_literals() if fixture_literals is None else fixture_literals
        texts = {text for strings in literals.values() for literal in strings if (text := fixture_text(literal))}
        sources = {source for change in source_changes for source in change if source}
        drawn = "\n".join(source_strings(source) for source in sources)
        present = {text for text in texts if text in drawn}
        if fixture_literals is None:
            present = tree_uncommon_texts(tuple(sorted(present)))
        asserted = {target for target, strings in literals.items()
                    if any(fixture_text(literal) in present for literal in strings)}
        if asserted:
            targets.update(asserted)
            native_targets.update(asserted - LINUX_ONLY)
            reasons.add("Asserted text: a fixture waits for text this file draws")
    unit_roots = targets & ({"test"} | UNIT_ROOTS.keys()) - FIXTURES.keys()
    mac_required = phase == "review" and any(mac_path(path) for path in paths)
    if mac_required:
        reasons.add("Mac-specific path: PR runs Mac Selected (tests/ci/platform_boundary.py)")
    upgrade_required = phase == "review" and (any(matches(path, UPGRADE_CHECK_PATHS) for path in paths)
                                              or "store_format" in content_changed)
    if upgrade_required:
        reasons.add("Upgrade, installer or Store-format path: PR runs the previous installed-release upgrade")
    if phase == "development":
        targets = ({"test-logic"} | unit_roots | live_targets |
                   ({"upgrade-integration"} if any(matches(path, UPGRADE_PATHS) for path in paths) else set()) |
                   ({"installer-integration"} if any(matches(path, INSTALLER_PATHS) for path in paths) else set())
                   if targets else set())
        native_targets = set()
    whole_suite_gates = sorted(targets & WHOLE_SUITE_GATES)
    # A build module that build.zig imports (BUILD_MODULES' hub) is build input like build.zig.
    bootstrap = [path for path in changed
                 if matches(BUILD_HUB if BUILD_MODULES.get(path) == BUILD_HUB else path, BOOTSTRAP_INPUTS)]
    product = [path for path in changed if path not in bootstrap]
    bootstrap_only = bool(whole_suite_gates and bootstrap) and not (
        product and select(product, phase, available, graph, contents, fixture_literals)["whole_suite_gates"])
    fast_targets = fast_tier(targets, paths, bootstrap_only, store="sqlite_pin" in content_changed)
    targets = normalize(targets)
    native_targets = normalize(native_targets)
    mysql_suites = live_mysql_suites(targets, graph.live_mysql)
    targets.update(mysql_suites)
    if mysql_suites:
        reasons.add("Live MySQL fixtures also run in a MySQL-enabled Linux job")
    for reason, served_by in live_reasons:
        if not targets & served_by:
            raise ValueError(f"{reason!r} selected none of the targets that start its server: {sorted(served_by)}")
    cache_execution_checks = phase == "review" and (any(path in CACHE_POLICY or path in ACCEPTANCE_INPUTS for path in paths)
                                                    or "cache_policy" in content_changed)
    typecheck_macos = any(matches(path, TYPECHECK_INPUTS) or path in graph.compiled for path in paths)
    missing = (targets | native_targets) - available
    if missing:
        raise ValueError(f"Selected targets absent from the build: {sorted(missing)}")
    return {"phase": phase, "targets": sorted(targets), "fast_targets": fast_targets,
            "whole_suite_gates": whole_suite_gates,
            "mysql_suites": sorted(graph.live_mysql),
            "server_targets": sorted((targets & live_targets) | ({"test"} if "test" in targets and "test-store" in live_targets else set())),
            "live_needs": sorted(([root, reason] for root, reason in live_needs), key=lambda need: (need[0] or "", need[1])),
            "native_targets": sorted(native_targets), "native_required": bool(native_targets),
            "mac_required": mac_required, "upgrade_required": upgrade_required,
            "unit_compile_required": "src/store/schema.zig" in paths,
            "retry": not strict(paths),
            "cache_execution_checks": cache_execution_checks,
            "typecheck_macos": typecheck_macos,
            "linux_memory_checks": linux_memory_checks, "manual_checks": sorted(manual_checks),
            "policy_skips": [unit for unit, inputs in POLICY_SELF_CHECKS
                             if not any(matches(path, inputs) for path in paths)],
            "reasons": sorted(reasons)}


def changed_paths(base, head):
    def commit(ref):
        return subprocess.check_output(
            ["git", "rev-parse", "--verify", "--end-of-options", f"{ref}^{{commit}}"],
            text=True, stderr=subprocess.PIPE).strip()
    head_commit, base_commit = commit(head), commit(base)
    raw = subprocess.check_output(["git", "diff", "--no-renames", "--name-only", "-z",
                                   base_commit, head_commit])
    return [p.decode("utf-8", "surrogateescape") for p in raw.split(b"\0") if p], base_commit


def revision_text(commit, path):
    shown = subprocess.run(["git", "show", f"{commit}:{path}"], capture_output=True, text=True,
                           encoding="utf-8", errors="surrogateescape")
    return shown.stdout if shown.returncode == 0 else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--phase", choices=("development", "review"), default="review")
    args = parser.parse_args()
    available = set(build_files.steps())
    paths, base = changed_paths(args.base, args.head)
    head = subprocess.check_output(["git", "rev-parse", args.head], text=True).strip()
    result = select(paths, args.phase, available,
                    contents={path: (revision_text(base, path), revision_text(head, path))
                              for path in paths
                              if path.startswith("src/") or path == FIXTURE_TABLE
                              or any(matches(path, patterns) for patterns, _ in CONTENT_RULES.values())})
    result["base"] = base
    result["head"] = head
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
