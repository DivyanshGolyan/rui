
from dataclasses import dataclass
import re

from docs_only import ChangeKind
from qualification import shards, split_build


_UNSET = object()
from select_tests import live_mysql_suites, normalize


@dataclass(frozen=True)
class Plan:
    outputs: dict
    selection: dict


def plan(selection: dict, *, event_name: str, draft: bool, promotion: bool,
         change_kind: ChangeKind, compile_only: bool = False, native_targets=_UNSET) -> Plan:
    if promotion and compile_only:
        raise ValueError('A promotion runs its suites; a compile-only build runs none')
    p = dict(selection)
    kind = change_kind if event_name == 'pull_request' else ChangeKind.NORMAL
    if any(p[key] for key in ('targets', 'native_targets', 'native_required', 'mac_required', 'upgrade_required',
                              'server_targets', 'cache_execution_checks', 'typecheck_macos', 'linux_memory_checks',
                              'manual_checks')) or p.get('unit_compile_required', False):
        kind = ChangeKind.NORMAL
    p['change_kind'] = kind.value
    draft_run = event_name == 'pull_request' and draft
    p['draft_run'] = draft_run
    ready_pr = event_name == 'pull_request' and not draft_run
    quarantine = ('promotion' if promotion
                  else 'admission' if p['retry'] else 'off')
    if draft_run or kind == ChangeKind.DOCUMENTATION:
        p['targets'] = []
        p['native_targets'] = []
        p['server_targets'] = []
        p['cache_execution_checks'] = False
        p['typecheck_macos'] = False
        p['linux_memory_checks'] = False
        p['retry'] = False
        quarantine = 'off' if draft_run else quarantine
    elif compile_only:
        p['targets'] = ['check', 'test-logic']
        p['native_targets'] = []
        p['server_targets'] = []
        p['cache_execution_checks'] = False
        p['typecheck_macos'] = True
        p['linux_memory_checks'] = False
        p['retry'] = False
        quarantine = 'off'
    elif promotion:
        core = {'check-full', 'test-logic', 'admission-debug-integration'}
        # Every check the PR tier skips runs here whatever the batch touched: the LLVM frame
        # gate and the live MySQL wire client, as well as native macOS below.
        p['targets'] = sorted(normalize(set(p['targets']) | core) | {'stack-frames', 'mysql-wire-integration'})
        p['targets'] = sorted(set(p['targets']) | live_mysql_suites(p['targets'], p['mysql_suites']))
        p['native_targets'] = sorted(normalize(set(p['native_targets']) | core))
        p['retry'] = False
    elif ready_pr:
        # The PR tier: select_tests.fast_tier's Linux targets, on SQLite only. Promotion owns
        # every other fixture, whole-suite gates, live engines, macOS, the LLVM frame gate,
        # the upgrade, cache-execution and Linux memory checks.
        p['targets'] = list(p['fast_targets'])
        p['native_targets'] = []
        p['cache_execution_checks'] = False
        p['typecheck_macos'] = False
        p['linux_memory_checks'] = False
        p['retry'] = False
    else:
        p['native_targets'] = []
    if native_targets is not _UNSET:
        if event_name != 'workflow_dispatch' or promotion or compile_only:
            raise ValueError('Native diagnostic targets require a manual acceptance run')
        if (not isinstance(native_targets, list) or not native_targets
                or any(not isinstance(target, str) or not re.fullmatch(r'[a-z][a-z0-9-]*', target)
                       for target in native_targets)
                or len(set(native_targets)) != len(native_targets)):
            raise ValueError('Native diagnostic targets must be a nonempty array of distinct target names')
        p['native_targets'] = list(native_targets)
        p['retry'] = False
        quarantine = 'off'
    p['native_required'] = bool(p['native_targets'])
    compile_targets = list(p['targets'])
    if ready_pr and kind == ChangeKind.NORMAL and p.get('unit_compile_required', False):
        if not {'test', 'check', 'check-full'} & set(compile_targets):
            compile_targets = sorted(set(compile_targets) | {'test'})
    p['linux_compile_targets'] = compile_targets
    # A ready normal PR runs as one job: policy, one compile and its tier's targets on one runner.
    pr_job = ready_pr and kind == ChangeKind.NORMAL
    outputs = dict(
        pr_job=pr_job,
        pr_setup_targets=sorted(set(p['targets']) | set(compile_targets)) if pr_job else [],
        change_kind=kind.value,
        draft_run=draft_run,
        targets=p['targets'],
        linux_compile_targets=compile_targets,
        native_targets=p['native_targets'],
        linux_matrix=shards([] if pr_job else p['targets'], mysql_suites=p['mysql_suites']),
        linux_split=not pr_job and split_build(compile_targets),
        macos_split=split_build(p['native_targets']),
        macos_matrix=shards(p['native_targets'], 'macos', mysql_suites=p['mysql_suites']),
        native=p['native_required'],
        retry=p['retry'],
        quarantine=quarantine,
        linux_memory=p['linux_memory_checks'],
        cache_execution=p['cache_execution_checks'],
        typecheck_macos=p['typecheck_macos'],
        policy_skips=p['policy_skips'],
        compile_only=compile_only,
    )
    return Plan(outputs, p)
