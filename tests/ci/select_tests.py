#!/usr/bin/env python3
"""Select existing build targets for fresh execution.

A changed file selects the unit roots and process fixtures that reach it
through literal imports (`Graph`), plus the targets its path rules name.
"""
import argparse
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

# build.zig's named modules that are repository files. Every other named
# import must be a package or generated module, or the graph refuses it.
MODULES = {
    "test_poll": "src/testing/poll.zig", "h2": "src/h2/h2.zig", "tls_client": "src/tls_client/tls_client.zig", "rui_client": CALLER, "client": CALLER,
    "mysql_connection": "src/store/wire/mysql_connection.zig", "preferences": "src/preferences.zig",
    "codex_credentials": "src/codex_credentials.zig", "AnswerRenderer": "src/AnswerRenderer.zig",
    "openapi.json": "openapi.json",
}
PACKAGES = {"std", "builtin", "vaxis", "terminal_width", "terminal_unicode", "h2_c", "openssl_c", "posix",
            "transport_options", "yaml", "sqlite", "unit_test_options", "unit_test_partition"}

# Unit test executables: a change runs each one whose build compiles it.
UNIT_ROOTS = {
    "test-native": ("src/tests.zig", "src/unit_test_partition.zig", "src/signal_stack_probe.zig",
                    "tests/integration/answer_renderer_allocation.zig"),
    "test-store": ("src/store.zig", "src/unit_test_partition.zig"),
    "test-logic": (FUNCTIONAL_CORES, "tests/integration/answer_renderer_allocation.zig"),
    "test-h2": ("src/h2/h2.zig",),
    "test-pg": ("src/store/wire/pg.zig",),
    "mysql-wire-integration": ("tests/integration/mysql_wire_test.zig",),
}

# Process fixtures: build target -> (its scripts, the test executables it runs
# besides Rui, and the Rui owners whose behavior it asserts). Only fixtures
# that assert caller behavior name the caller (`CALLER`); admission owns the
# common caller-to-Host path every other fixture also takes. A Rui file
# reaches a fixture when an owner imports it, or when it is Host code (or
# Rui's root) that imports an owner: the Host's dispatch into the driven
# path. Registered functional cores reach only unit roots: their value tests
# own their decisions. Promotion runs every fixture, so an owner missing here
# surfaces there; add it. Long witnesses and Debug twins outside check name no
# owners: RULES map the files they qualify, and promotion runs them.
I = "tests/integration/"
BASH = ("src/bash.zig", "src/BashLifecycle.zig", "src/deadline.zig")
# Model admission: what dispatch and the managed H2 transport assert about a request.
MODEL = ("src/provider.zig", "src/transport_policy.zig", "src/output_decode.zig", "src/history_memo.zig",
         "src/model_capability.zig", "src/failed_responses.zig")
CREDENTIALS = ("src/codex_credential_policy.zig", "src/codex_token_wire.zig")
FIXTURES = {
    "admission-integration": ((I + "admission_integration.sh",), (), (CALLER, HOST)),
    "admission-debug-integration": ((I + "admission_integration.sh",), (), ()),
    "dispatch-integration": ((I + "dispatch_integration.py",), (), ("src/model_adapter.zig", *MODEL)),
    "dispatch-debug-integration": ((I + "dispatch_integration.py",), (), ()),
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
    "transport-h2-integration": ((I + "transport_h2_integration.py", I + "transport_h2_integration_test.py"), (),
                                 ("src/providers.zig", "src/model_adapter.zig", *MODEL)),
    "login-signal-integration": ((I + "login_signal_integration.py",), (), ()),
    "codex-credential-integration": ((I + "codex_credential_integration.py",), (I + "codex_credential_actor.zig",),
                                     ("src/providers.zig", "src/api_key.zig", "src/codex_auth.zig", *CREDENTIALS)),
    "preference-policy-integration": ((I + "preference_policy_integration.py",), (I + "preference_policy.zig",), ()),
    "mysql-wire-integration": ((I + "mysql_wire_integration.py",), (), ()),
    "skills-integration": ((I + "skills_integration.py",), (), ("src/session_skills.zig",)),
    "launch-frame-integration": ((I + "launch_frame_integration.py", I + "launch_frame_mysql_integration.py",
                                  I + "store_rounds_cases.py"),
                                 (I + "mysql_launch_admin.zig",),
                                 ("src/launch_frame.zig", "src/mysql_url.zig", "src/mcp/Running.zig", "src/mcp/servers.zig")),
    "ts-client": ((I + "host_process.py",), (), ("src/launch_frame.zig",)),
    "request-wait-integration": ((I + "request_wait_integration.py",), (),
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
                              (CALLER, "src/HostLifecycle.zig", "src/server_host.zig")),
    "host-launch-integration": ((I + "host_launch_integration.py",), (),
                                ("src/HostLifecycle.zig", "src/descriptor_capacity.zig", "src/os/descriptor_limit.zig", "src/serve_grammar.zig")),
    "descriptor-capacity-integration": ((I + "descriptor_capacity_integration.py",), (),
                                        ("src/descriptor_capacity.zig", "src/os/descriptor_limit.zig")),
    "host-allocator-integration": ((I + "host_allocator_test.py",), (), ("src/os/process.zig",)),
    "host-process-test": ((I + "host_process_test.py",), (), ()),
    "installer-integration": ((I + "installer_integration.py",), (),
                              ("src/Installation.zig", "src/installation_path.zig", "src/release_candidate.zig")),
    "upgrade-integration": ((I + "upgrade_integration.py",), (),
                            ("src/upgrade.zig", "src/upgrade_process.zig", "src/UpgradePanel.zig",
                             "src/HostLifecycle.zig", "src/Installation.zig")),
    "terminal-restoration-integration": ((I + "terminal_restoration_integration.py",), ("src/terminal_notice_test.zig",),
                                         ("src/SessionFrontend.zig", "src/SessionTerminal.zig", "src/TerminalEditor.zig")),
    "canonical-failure-integration": ((I + "canonical_failure_integration.py",), (),
                                      (CALLER, "src/SessionFrontend.zig", "src/failure_class.zig", "src/model_adapter.zig")),
    "model-picker-integration": ((I + "model_picker_integration.py", I + "model_picker_signin_integration.py",
                                  I + "model_picker_failure_integration.py"), (),
                                 ("src/Overview.zig", "src/SessionFrontend.zig", "src/model_picker_view.zig")),
    "human-cli-integration": ((I + "human_cli_integration.py",), ("src/terminal_notice_test.zig",),
                              (CALLER, "src/SessionFrontend.zig", "src/Overview.zig", "src/request_wait.zig",
                               "src/cli_args.zig", "src/slash_commands.zig")),
}
# Fixtures a broader target runs in full.
FIXTURE_COVERS = {"human-cli-integration": {"canonical-failure-integration", "terminal-restoration-integration"}}
# Test code under src/: it reaches the unit roots and test executables that
# compile it, never Rui's behavior.
TEST_CODE = ("src/*tests.zig", "src/*_test.zig", "src/*testing.zig", "src/*testing/*", "src/mcp/test_server.zig",
             "src/socket_fixture.zig", "src/store/mysql_dialect_check.zig")
# Targets that need a Linux runner; Mac Selected never runs them.
LINUX_ONLY = {"login-signal-integration", "mysql-wire-integration"}

EMBED = re.compile(r'@embedFile\(\s*"([^"]+)"\s*\)')
PYTHON_IMPORT = re.compile(r"^\s*(?:from\s+([A-Za-z_]\w*)\S*\s+import\b|import\s+([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*))", re.M)
# A fixture that reads a source file names it relative to the repository,
# or joins it under the repository's "src" path.
SOURCE_READ = re.compile(r"\b(src/[\w./-]+)")
SOURCE_JOIN = re.compile(r'/\s*"src"\s*/\s*"([\w./-]+)"')


class Graph:
    """Literal import edges of one source tree and the targets each file reaches.

    Zig edges are `@import` and `@embedFile`; `production` leaves out imports
    only test declarations use. Python edges join tests/integration modules,
    including those a shell script runs, and the source files they read.
    """

    def __init__(self, names, read):
        names = set(names)
        self.production, self.every, self.python = {}, {}, {}
        for name in sorted(names):
            if name.endswith(".zig") and name.startswith(("src/", I)):
                self.zig(name, read(name))
            elif name.startswith(I) and name.endswith((".py", ".sh")):
                source = read(name)
                # Python names a file it reads in a string; shell, anywhere.
                strings = (" ".join(token.string for token in tokenize.generate_tokens(io.StringIO(source).readline)
                                    if token.type == tokenize.STRING) if name.endswith(".py") else source)
                self.python[name] = ({f"{I}{module}.py" for match in PYTHON_IMPORT.finditer(source)
                                      for module in (match[1] and [match[1]] or re.split(r"\s*,\s*", match[2]))}
                                     | set(SOURCE_READ.findall(strings))
                                     | {"src/" + joined for joined in SOURCE_JOIN.findall(source)}) & names - {name}
        # Every file a Zig compilation reads: sources, and what they import
        # or embed that is not Zig (openapi.json, SQL baselines, prompt text).
        self.compiled = set(self.every).union(*self.every.values())
        self.cores = {"src/" + core for core in re.findall(
            r'\.\{ "([^"]+\.zig)", @import', read(FUNCTIONAL_CORES).split("const cores = .{", 1)[1].split("\n};", 1)[0])}
        # Rui's code: its production imports, less test code that a
        # top-level alias names but only tests use.
        self.tests = {name for name in self.production if matches(name, TEST_CODE)}
        product = {source: targets - self.tests for source, targets in self.production.items() if source not in self.tests}
        # The Host is what stack_frames.py walks: server.zig and the modules
        # it names, which the Host also reaches through function pointers.
        modules = json.loads(read(STACK_FRAMES_GATE))["host_modules"] if STACK_FRAMES_GATE in names else []
        host = [HOST, *(name for module in modules for name in self.production
                        if f"/{name}".endswith("/" + module.replace(".", "/") + ".zig"))]
        self.host = self.closure(product, host)
        rui = self.closure(product, [RUI])
        callers = {}
        for source, targets in product.items():
            for target in targets:
                callers.setdefault(target, set()).add(source)
        # Each target's files: those its unit roots compile and its scripts
        # use or read, and those it reaches only through the code it runs (the
        # owners it drives and its test executables), which cores do not reach.
        self.reached = {target: self.closure(self.every, roots) for target, roots in UNIT_ROOTS.items()}
        # Native tests outside Store can exercise every Store engine too. A
        # change they reach must retain the composed run and its live MySQL.
        conformance = [name for name in self.reached["test-native"]
                       if name.startswith("src/") and not name.startswith("src/store/")
                       and name.endswith(".zig") and name in names
                       and re.search(r'\b\w+\.forEachEngine\s*\(', read(name))]
        self.live_conformance = self.closure(self.every, conformance)
        self.driven, self.owners = {}, {}
        for target, (scripts, executables, owners) in FIXTURES.items():
            self.owners[target] = set(owners)
            owners = [*owners, *(host if HOST in owners else ())]
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

        # An embed names a file, or a module build.zig adds (`MODULES`).
        embedded = {MODULES.get(path) or os.path.normpath(directory / path) for path in EMBED.findall(source)}
        self.production[name] = embedded.union(*map(resolve, production))
        self.every[name] = self.production[name].union(*map(resolve, tested))

    def scripts(self, scripts):
        """The modules and source files fixture scripts use, transitively: a
        library a fixture imports may import other libraries. No fixture
        imports another (test_harness_contracts.FixtureImportTest), so a
        change to one fixture's script selects only the targets that run it."""
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
        """The unit roots and fixtures that reach `path`, None when no graph
        edge names it. A functional core or test code reaches fixtures only
        through their scripts and test executables, or as a named owner."""
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


# The option grammar cli_args.zig used to hold: rules that name cli_args.zig
# name these too. Path rules, not fixture owners, so the Host importing them
# does not dispatch into the human CLI.
CLI_GRAMMAR = ("src/cli_grammar.zig", "src/cli_option_names.zig", "src/serve_grammar.zig")

# The upgrade fixture is standalone, including when a composed gate is selected.
UPGRADE_PATHS = ("src/upgrade.zig", "src/installation_path.zig", "src/TerminalEditor.zig", "src/Installation.zig", "src/release_candidate.zig",
                 "src/upgrade_process.zig", "src/HostLifecycle.zig", "src/host_identity.zig",
                 "src/host_identity.c", "src/UpgradePanel.zig", "src/host_launch.c",
                 "src/cli.zig", "src/cli_args.zig", *CLI_GRAMMAR, "src/client.zig", "src/slash_commands.zig",
                 "src/Overview.zig", "src/overview_view.zig", "src/SessionFrontend.zig",
                 "tests/integration/upgrade_integration.py", "tests/ci/test_upgrade_fixture.py", "release/*", "install.sh", "build.zig")

# The source and release installers exercise real publication and PATH decisions.
# Keep this standalone even beside check, which does not run the installer driver.
INSTALLER_PATHS = ("tests/integration/installer_integration.py", "tests/ci/fake_rui.py",
                   "tests/ci/test_install.py", "tests/ci/test_installer_boundary.py", "tests/ci/test_release.py",
                   "tests/ci/release.py", "tests/ci/release_publication.py", "tests/ci/test_release_publication.py", "tests/ci/release_numbers.py", "tests/ci/qualification.py",
                   "src/Installation.zig", "src/installation_path.zig", "src/release_candidate.zig",
                   "src/cli.zig", "src/cli_args.zig", *CLI_GRAMMAR, "src/store/schema.zig",
                   "src/fetch_dependencies.sh", "release/*", "install.sh", "build.zig", "build.zig.zon")

# Ready PRs run the previous installed-release upgrade only when they change
# what it exercises: installation, the upgrade and Host lifecycle owners, the
# Store format (`store_format`), the build or the check itself. Its own unit
# test runs in policy. Promotion runs it for every batch.
UPGRADE_CHECK_PATHS = ("src/upgrade*.zig", "src/Installation.zig", "src/installation_path.zig", "src/release_candidate.zig",
                       "src/HostLifecycle.zig", "src/host_identity.*", "src/host_launch.c",
                       "src/store/migration_*", "install.sh", "release/*", "build.zig", "build.zig.zon",
                       "tests/integration/previous_release_upgrade.py", ".github/workflows/previous-release-upgrade.yml")


def store_format(source):
    """What an installed release's Store meets in schema.zig: the version, each
    version's digest and the forward steps. Imports and comments are not it."""
    return schema_version(source), digest_rows(source), migration_steps(source)


def store_format_changed(path, before, after):
    return before is None or after is None or store_format(before) != store_format(after)


# Build and workflow files whose changed lines can alter what a warm cache
# replays: Zig cache paths, keys and steps, and the build's has_side_effects
# runs. Every cache the setup action restores is a build cache; elsewhere
# only Zig build-cache lines count, not other tools' caches (actionlint).
# The cache_execution job's own definition counts too (`cache_policy_changed`).
CACHE_CONFIG = ("build.zig", "build/*.zig", ".github/actions/*", ".github/workflows/*.yml")
SETUP_CACHE_LINE = re.compile(r"cache", re.IGNORECASE)
CACHE_LINE = re.compile(r"zig[-_ ]?cache|\.cache/zig|cache[-_]dir|cache_root|has_side_effects|ci-compiled|build-cache"
                        r"|publish-caches|cache-execution", re.IGNORECASE)
# Files that are cache policy, or the proof that it never caches acceptance.
CACHE_POLICY = (".github/scripts/prune-caches.cjs", "tests/ci/cache_execution.py", "tests/ci/zig_cache_restat.c",
                "tests/ci/run_selected.py")


def code_lines(source):
    """Lines that are not blank or comments (YAML `#`, Zig `//`)."""
    return [line for line in (source or "").splitlines() if line.strip() and not line.lstrip().startswith(("#", "//"))]


def workflow_job(source, name):
    match = re.search(rf"(?ms)^  {re.escape(name)}:\n.*?(?=^  [A-Za-z_][\w-]*:\n|\Z)", source or "")
    return code_lines(match[0]) if match else None


def yaml_context(lines, index):
    """A YAML line with what gives it meaning: each less-indented line above
    it (its keys) and the whole list item (workflow step) it sits in."""
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


def cache_policy_changed(path, before, after):
    """Whether a changed line, or for YAML its keys and step, names a build
    cache. An added or removed file counts by its own lines."""
    pattern = SETUP_CACHE_LINE if path.startswith(".github/actions/") else CACHE_LINE
    old, new = code_lines(before), code_lines(after)
    changed = []
    for tag, old_start, old_end, new_start, new_end in difflib.SequenceMatcher(None, old, new, autojunk=False).get_opcodes():
        if tag != "equal":
            changed += [(old, index) for index in range(old_start, old_end)] + [(new, index) for index in range(new_start, new_end)]
    context = (yaml_context if path.endswith(".yml") else lambda lines, index: [lines[index]])
    return (any(pattern.search(line) for lines, index in changed for line in context(lines, index))
            or workflow_job(before, "cache_execution") != workflow_job(after, "cache_execution"))


# Paths selection judges by content: rule -> (its paths, whether a
# (before, after) text pair changes what the rule's check exercises).
# `main` reads both sides of each matching path.
CONTENT_RULES = {
    "store_format": ((STORE_SCHEMA,), store_format_changed),
    "cache_policy": (CACHE_CONFIG, cache_policy_changed),
}

# Nonblocking renderer harnesses; renderer-contracts.yml filters on these paths.
RENDERER_HARNESSES = ("tests/integration/session_sequence_model*", "tests/integration/input_equivalence.py")

# What the import graph cannot see: inputs no literal import names (C
# sources, generators, non-Zig consumers) and owners whose checks a test
# reaches by other means. The graph selects everything else; a source file
# neither names selects check.
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
    (RENDERER_HARNESSES, (), (), "Renderer harnesses: only the nonblocking renderer contracts run them"),
    (("src/session_sequence_model_test.zig",), ("test-logic",), ("test-logic",),
     "Sequence-model oracle: no gate compiles it; nonblocking renderer contracts run it"),
    (("src/openapi*.zig", "openapi.json"), ("test",), ("test",),
     "The wire contract: openapi.json must equal what the wire types emit"),
    (("clients/ts/*",), ("ts-client",), ("ts-client",), "The TypeScript client and its launch of a real Host"),
    (("tests/integration/mcp_sdk/*",), ("launch-frame-integration", "ts-client"), ("launch-frame-integration", "ts-client"),
     "The MCP SDK servers a launch frame starts"),
    (("src/mcp/*", "src/http1/*"), ("launch-frame-integration",), ("launch-frame-integration",),
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
    # The managed H2 fixtures probe the Host's descriptor refusal without
    # importing its owners (08b23a01).
    (("src/descriptor*", "src/os/descriptor_limit.zig", "src/server*.zig", "src/platform.zig", "src/cli.zig",
      "tests/integration/descriptor*", "tests/integration/host_launch*", "src/product_defaults.zig",
      "tests/integration/product_defaults.py"),
     ("test", "host-launch-integration", "descriptor-capacity-integration", "codex-h2-integration", "transport-h2-integration"),
     ("test", "host-launch-integration", "descriptor-capacity-integration", "codex-h2-integration", "transport-h2-integration"),
     "Startup capacity: every refusal boundary, managed transport and its companion oracle"),
    (("src/model_instructions.txt",),
     ("transport-h2-integration", "codex-h2-integration", "current-facts-integration",
      "server-delivery-integration", "measurement-check"),
     ("transport-h2-integration", "codex-h2-integration", "current-facts-integration",
      "server-delivery-integration", "measurement-check"),
     "Shared model context prose: fixture consumers and Go request oracles"),
    (("src/server*.zig", "src/cli.zig", "src/cli_args.zig", *CLI_GRAMMAR, "src/client.zig", "src/caller_*.zig", "src/cli_value.zig",
      "src/slash_commands.zig", "src/protocol_reply.zig", "src/ResponseTiming.zig", "src/preferences.zig",
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
    (("build.zig", "build.zig.zon", "install.sh", "src/fetch_dependencies.sh", "src/build_*", "src/*.patch", ".agents/setup",
      ".github/actions/setup/action.yml", "screen-emulator/*"),
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

# check.yml's LIVE_MYSQL: Linux shards for the unit dialect check
# (src/store/mysql_dialect_check.zig) and the launch-frame Host fixture.
LIVE_MYSQL_DIALECT_TARGETS = frozenset({"test", "test-store", "check", "check-full"})
LIVE_MYSQL_TARGETS = LIVE_MYSQL_DIALECT_TARGETS | {"launch-frame-integration"}
# check.yml's Postgres step condition: the Linux targets whose shards start
# postgres:15 for test-pg's live rounds.
LIVE_POSTGRES_TARGETS = frozenset({"test-pg", "check", "check-full"})

# Rules whose reason names a live server, each with the targets that start
# it in CI. A matched rule must leave one of those targets selected, in
# development too, or its green would say nothing about that server.
# Development keeps the rule's own targets among them.
LIVE_RULES = (
    (("src/launch_frame.zig", "src/mysql_url.zig", "tests/integration/launch_frame*", "tests/integration/mysql_launch_admin.zig"),
     ("test", "launch-frame-integration"), ("launch-frame-integration",),
     "The launch-frame Host opens a live MySQL Store on Linux; macOS skips the live server",
     frozenset({"launch-frame-integration", "check", "check-full"})),
    (("src/store/wire/pg*.zig", "src/store/wire/scram.zig", "src/store/wire/tls.zig", "src/tls_client/*",
      "tests/integration/live_engines.py", "tests/ci/live_engine_step.py"),
     ("test-pg",), ("test-pg",), "The Postgres wire client's own tests, live against postgres:15 on Linux",
     LIVE_POSTGRES_TARGETS),
    (("src/store/wire/mysql.zig", "src/store/wire/mysql_connection.zig", "src/store/wire/tls.zig", "tests/integration/mysql_wire*",
      "tests/integration/mysql_server.py", "build.zig"),
     ("test-logic", "mysql-wire-integration"), ("test-logic",),
     "MySQL wire client: replayed exchanges and a real MySQL 8.4 server (Docker, Linux only)",
     frozenset({"mysql-wire-integration"})),
    # Every Store statement, the schema, the fixtures and the wire client
    # can change what MySQL refuses.
    (("src/store.zig", "src/store/*", "!src/store/wire/pg*.zig", "!src/store/wire/scram.zig",
      "!src/store/wire/tls.zig", "tests/integration/mysql_server.py",
      "tests/integration/live_engines.py", "tests/ci/live_engine_step.py"),
     ("test-store",), (),
     "The Store's live MySQL dialect check drives MySQL 8.4 through the wire client; macOS skips it",
     LIVE_MYSQL_DIALECT_TARGETS),
)
RULES += tuple(rule[:4] for rule in LIVE_RULES)
# The Store's MySQL round-trip budget runs against the live MySQL that
# launch-frame-integration starts (LIVE_MYSQL_TARGETS); development skips it.
RULES += ((("src/store.zig", "src/store/*", "!src/store/wire/*", "src/server_execution.zig", "src/execution_turn.zig",
            "src/model_adapter.zig", "tests/integration/store_rounds_cases.py"),
           ("launch-frame-integration",), (),
           "The Store's MySQL round trips per model operation and while idle stay within their budget"),)

# build.zig wires every target, so an edit to it selects the full gate (RULES
# above). A hub module is build.zig's code split out for size, and an edit to
# it selects what a build.zig edit does. Any other module under build/ selects
# only what it can change: the targets it defines and those that use what it
# builds. test_selection.BuildModuleTest holds every module and every target a
# module defines to this map.
BUILD_HUB = "build.zig"
BUILD_MODULES = {
    # The Rui every target builds or runs, and the libraries it links.
    "build/product.zig": BUILD_HUB,
    # How every CI producer hands executables to the shards that run them.
    "build/ci.zig": BUILD_HUB,
    # The PTY screen observer: what check-full and these fixtures load to read
    # the terminal. Its renderer harnesses are nonblocking (renderer-contracts.yml).
    "build/screen.zig": ("check-full", "skills-integration", "upgrade-integration"),
    # Darwin linking, the screen library's name and the Mac unit-root limits.
    # The unit roots and one screen fixture link and load what it names; it is
    # a Mac path, so ready PRs run these on Mac too.
    "build/darwin.zig": ("test", "host-launch-integration"),
}
RULES += tuple(((module,), targets, targets, "Build module: the targets it defines or builds for")
               for module, targets in BUILD_MODULES.items() if targets != BUILD_HUB)


# Inputs to the Host's ReleaseSafe frames or to their gate: Zig source the
# Host imports (`Graph.host`), and anything else under src/. check runs
# stack-frames; check-full does not.
STACK_FRAMES = ("src/*", "build.zig", "build.zig.zon", "tests/ci/stack_frames.py", "tests/ci/stack_frames.json")

CHECK_COVERS = {
    "test", "test-native", "test-store", "test-h2", "test-pg", "admission-integration", "dispatch-integration",
    "bash-owner-integration", "bash-lifecycle-integration", "bash-recovery-integration",
    "bash-integration", "bash-environment-integration", "codex-integration", "control-integration",
    "host-status-integration", "host-launch-integration", "host-stop-integration",
    "descriptor-capacity-integration", "request-wait-integration",
    "activity-integration", "preference-policy-integration", "session-list-integration",
    "peer-integration", "sender-identity-integration", "conversation-page-integration",
    "host-allocator-integration", "host-process-test", "human-cli-integration", "model-picker-integration",
    "canonical-failure-integration",  # human_cli_integration.main executes all cases.
    "terminal-restoration-integration",  # Same full fixture in the human CLI gate.
}



# What `zig build typecheck-macos` compiles: Zig and C sources, the build
# and its pinned packages, and the patches and scripts that prepare them.
# Files Zig imports or embeds count too (`Graph.compiled`). No other change can alter
# whether Rui type-checks for Apple Silicon.
TYPECHECK_INPUTS = ("*.zig", "*.zon", "*.c", "*.h", "src/*.patch", "src/*.sh", ".github/actions/setup/action.yml")


# tests/ci units that read no repository file outside their inputs (traced).
# The policy job skips a unit whose inputs the diff leaves unchanged; every
# other tests/ci test always runs.
POLICY_SELF_CHECKS = (
    # The check.sh driver tests run the real driver and host_process.py, which
    # imports live_engines.py and h2 and reads the wire version.
    ("test_selection.FullCheckPartitionTest",
     ("tests/ci/*", "build.zig", "tests/integration/check.sh", "tests/integration/host_process.py",
      "tests/integration/live_engines.py", "tests/integration/requirements.txt", "src/wire_version.zig")),
    ("test_admission", ("tests/ci/*", ".github/*", "build.zig")),
    ("test_release_publication", ("tests/ci/*",)),
    ("test_build_artifact", ("tests/ci/*",)),
)


# Steps that run the PTY screen observer, whose libghostty-vt comes from the
# test-only package in screen-emulator: setup fetches its packages for these only.
# A step missing here still builds, fetching them on demand.
SCREEN_TARGETS = frozenset({"check", "check-full", "terminal-restoration-integration", "canonical-failure-integration",
                            "host-launch-integration", "upgrade-integration", "human-cli-integration", "model-picker-integration",
                            "skills-integration", "bash-recovery-integration", "renderer-contracts-selftest",
                            "direct-pty", "direct-pty-controls", "input-equivalence", "screen-emulator"})


def setup_requirements(targets):
    # Every runner installs the same fixture packages (tests/integration/requirements.txt)
    # for any target, so no fixture's import depends on a hand-kept target list.
    return {"go": bool(({"measurement-check"} | set(RESOURCES)).intersection(targets)), "node": bool({"ts-client", "launch-frame-integration", "check", "check-full"}.intersection(targets)), "python": bool(targets), "screen": bool(SCREEN_TARGETS.intersection(targets)), "tmux": "upgrade-integration" in targets}


def execution_batches(targets, check_part="all"):
    # Share compilation and graph execution only among independent owner suites.
    # Composed gates and latency-sensitive/long witnesses keep isolated execution.
    if check_part != "all" and "check-full" not in targets:
        raise ValueError("A full-check part requires check-full in the selection")
    if check_part == "execution":
        return [["check-full", "-Dcheck-part=execution"],
                *execution_batches([target for target in targets if target != "check-full"])]
    if check_part not in {"all", "callers"}:
        raise ValueError(f"Unknown full-check part: {check_part}")
    isolated = {"check", "check-full", "admission-debug-integration", "test-full",
                "host-launch-integration", "server-delivery-integration",
                "transport-h2-integration", "codex-h2-integration"}
    shared = [target for target in targets if target not in isolated]
    return (([shared] if shared else [])
            + [[target, "-Dcheck-part=callers"] if target == "check-full" and check_part == "callers"
               else [target] for target in targets if target in isolated])


def matches(path, patterns):
    """A path matches a rule's patterns unless a "!" pattern excludes it."""
    included = any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns if not pattern.startswith("!"))
    return included and not any(fnmatch.fnmatchcase(path, pattern[1:]) for pattern in patterns if pattern.startswith("!"))


def select(paths, phase, available, graph=None, contents=None):
    """`contents` maps a path a `CONTENT_RULES` entry matches to its
    (before, after) text; a path it leaves out counts as changed."""
    graph = graph or tree_graph()
    paths = [BUILD_HUB if BUILD_MODULES.get(path) == BUILD_HUB else path for path in paths]
    contents = contents or {}
    content_changed = {rule for rule, (patterns, changed) in CONTENT_RULES.items()
                       if any(matches(path, patterns) and (path not in contents or changed(path, *contents[path]))
                              for path in paths)}
    targets, native_targets, reasons = set(), set(), set()
    live_targets, live_reasons = set(), set()
    manual_checks = set()
    linux_memory_checks = False
    for path in paths:
        reached = graph.targets(path)
        # A shortcut only adds its reason, and stops the fallbacks below; every
        # rule, LIVE_RULES included, still matches the path.
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
        if path in graph.live_conformance and path not in graph.reached["test-store"]:
            targets.add("test")
            native_targets.add("test")
            live_targets.add("test")
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
            targets.add("test-full")  # Response wait/inactivity owner.
            native_targets.add("test-full")
    for checks in (targets, native_targets):
        if "test" in checks or {"test-native", "test-store"} <= checks:
            checks.difference_update({"test-native", "test-store"})
            checks.add("test")
        covered = {case for broad, cases in FIXTURE_COVERS.items() if broad in checks for case in cases}
        checks -= covered
        # Every case check runs is selected: run them as one gate.
        if CHECK_COVERS - UNIT_ROOTS.keys() - {"test"} <= checks | covered:
            checks.add("check")
        if "check-full" in checks:
            checks.discard("check")
        if checks & {"check", "check-full"}:
            checks -= CHECK_COVERS
        if "check" in checks:
            checks.discard("stack-frames")
    # Linux predicts Mac except where code may differ by platform.
    mac_required = phase == "review" and any(mac_path(path) for path in paths)
    if mac_required:
        reasons.add("Mac-specific path: PR runs Mac Selected (tests/ci/platform_boundary.py)")
    upgrade_required = phase == "review" and (any(matches(path, UPGRADE_CHECK_PATHS) for path in paths)
                                              or "store_format" in content_changed)
    if upgrade_required:
        reasons.add("Upgrade, installer or Store-format path: PR runs the previous installed-release upgrade")
    if phase == "development":
        # Development does not replace final boundary/native acceptance, but
        # keeps each matched live rule's own targets (`LIVE_RULES`).
        targets = ({"test-logic"} | live_targets |
                   ({"upgrade-integration"} if any(matches(path, UPGRADE_PATHS) for path in paths) else set()) |
                   ({"installer-integration"} if any(matches(path, INSTALLER_PATHS) for path in paths) else set())
                   if targets else set())
        native_targets = set()
    if "test" in targets:
        targets.difference_update({"test-native", "test-store"})
    for reason, served_by in live_reasons:
        if not targets & served_by:
            raise ValueError(f"{reason!r} selected none of the targets that start its server: {sorted(served_by)}")
    cache_execution_checks = phase == "review" and (any(path in CACHE_POLICY for path in paths)
                                                    or "cache_policy" in content_changed)
    typecheck_macos = any(matches(path, TYPECHECK_INPUTS) or path in graph.compiled for path in paths)
    missing = (targets | native_targets) - available
    if missing:
        raise ValueError(f"Selected targets absent from the build: {sorted(missing)}")
    return {"phase": phase, "targets": sorted(targets),
            # The selected targets that start a live server in CI (`LIVE_RULES`).
            "server_targets": sorted((targets & live_targets) | ({"test"} if "test" in targets and "test-store" in live_targets else set())),
            "native_targets": sorted(native_targets), "native_required": bool(native_targets),
            "mac_required": mac_required, "upgrade_required": upgrade_required,
            # Store, recovery and upgrade changes fail for real; never rerun them.
            "retry": not strict(paths),
            "cache_execution_checks": cache_execution_checks,
            # Whether the change can alter what `typecheck-macos` compiles.
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
    # No rename inference: both deleted and added owners select their checks.
    raw = subprocess.check_output(["git", "diff", "--no-renames", "--name-only", "-z",
                                   base_commit, head_commit])
    return [p.decode("utf-8", "surrogateescape") for p in raw.split(b"\0") if p], base_commit


def revision_text(commit, path):
    """The path's text at commit, or None where the commit has no such file."""
    shown = subprocess.run(["git", "show", f"{commit}:{path}"], capture_output=True, text=True)
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
                              if any(matches(path, patterns) for patterns, _ in CONTENT_RULES.values())})
    result["base"] = base
    result["head"] = head
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
