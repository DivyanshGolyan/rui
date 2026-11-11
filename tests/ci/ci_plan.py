"""Value-only routing from selector obligations and candidate facts to CI plans."""

from dataclasses import dataclass

from docs_only import ChangeKind
from qualification import shards, split_build
from select_tests import CHECK_COVERS, live_mysql_suites


@dataclass(frozen=True)
class Plan:
    outputs: dict
    selection: dict  # Transformed selector details for the step summary.


def plan(selection: dict, *, event_name: str, draft: bool, promotion: bool,
         change_kind: ChangeKind) -> Plan:
    """Derive output values and summary without I/O or changing the input."""
    p = dict(selection)
    kind = change_kind if event_name == 'pull_request' else ChangeKind.NORMAL
    # Future selector obligations must not be erased by the path allowlist.
    if any(p[key] for key in ('targets', 'native_targets', 'native_required', 'mac_required', 'upgrade_required',
                              'server_targets', 'cache_execution_checks', 'typecheck_macos', 'linux_memory_checks',
                              'manual_checks')):
        kind = ChangeKind.NORMAL
    p['change_kind'] = kind.value
    draft_run = event_name == 'pull_request' and draft
    p['draft_run'] = draft_run
    ready_pr = event_name == 'pull_request' and not draft_run
    # Listed flakes (quarantine.json) never excuse a strict change; promotion
    # still blocks on a listed flake's second consecutive failure.
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
    elif promotion:
        # The batch's full suite on both systems, plus the selected
        # standalone targets. check-full omits the portable logic root,
        # the frame gate and the Debug recovery, so they run beside it.
        core = {'check-full', 'test-logic', 'admission-debug-integration'}
        p['targets'] = sorted((set(p['targets']) - CHECK_COVERS - {'check'}) | core | {'stack-frames'})
        p['targets'] = sorted(set(p['targets']) | live_mysql_suites(p['targets'], p['mysql_suites']))
        p['native_targets'] = sorted((set(p['native_targets']) - CHECK_COVERS - {'check'}) | core)
        p['retry'] = False
    elif ready_pr:
        # Qualify the tested source tree, not the later final squash SHA.
        # Linux predicts Mac except where code may differ by platform;
        # promotion runs Mac for every batch.
        p['native_targets'] = (p['native_targets'] or ['check']) if p['mac_required'] else []
        p['retry'] = False
    else:
        # Manual non-promotion runs retain Linux-only feedback.
        p['native_targets'] = []
    # PR integration codegen is fast; the LLVM stack oracle remains a
    # required, independent job rather than a dependency of every shard.
    p['linux_codegen'] = (event_name == 'pull_request'
                          and bool({'check', 'stack-frames'} & set(p['targets'])))
    if p['linux_codegen']:
        p['targets'] = [t for t in p['targets'] if t != 'stack-frames']
    p['native_required'] = bool(p['native_targets'])
    p['upgrade_required'] = ready_pr and kind == ChangeKind.NORMAL and p['upgrade_required']
    outputs = dict(
        change_kind=kind.value,
        draft_run=draft_run,
        targets=p['targets'],
        native_targets=p['native_targets'],
        linux_matrix=shards(p['targets'], mysql_suites=p['mysql_suites']),
        linux_split=split_build(p['targets']),
        macos_split=split_build(p['native_targets']),
        linux_codegen=p['linux_codegen'],
        macos_matrix=shards(p['native_targets'], 'macos', mysql_suites=p['mysql_suites']),
        native=p['native_required'],
        upgrade=p['upgrade_required'],
        retry=p['retry'],
        quarantine=quarantine,
        linux_memory=p['linux_memory_checks'],
        cache_execution=p['cache_execution_checks'],
        typecheck_macos=p['typecheck_macos'],
        policy_skips=p['policy_skips'],
    )
    return Plan(outputs, p)
