#!/bin/bash
# Run as the administrator whose gh login owns this repository.
set -euo pipefail
umask 077
REPOSITORY=DivyanshGolyan/rui
RUNNER_HOME=/Users/ruici
RUNNER_DIR=$RUNNER_HOME/actions-runner
REGISTRATION=$RUNNER_HOME/.rui-runner-registration.json
PLIST=/Library/LaunchDaemons/com.rui.actions-runner.plist
LABEL=com.rui.actions-runner
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd -P)
fail() { printf '%s\n' "$*" >&2; exit 1; }

removal_decision() {
    local stage=$1 credentials=false
    if [[ -e $REGISTRATION || -L $REGISTRATION ]]; then
        [[ -f $REGISTRATION && ! -L $REGISTRATION \
            && $(/usr/bin/stat -f '%u' "$REGISTRATION") == 0 \
            && $(/usr/bin/stat -f '%Lp' "$REGISTRATION") == 600 ]] \
            || fail 'Registration record must be a root-owned regular file with mode 600.'

    fi
    if [[ -s $RUNNER_DIR/.credentials && ! -L $RUNNER_DIR/.credentials ]]; then
        credentials=true
    fi
    "$(cat "$stage/python-path")" -I -S - "$stage/mac_runner.py" "$REGISTRATION" "$RUNNER_DIR/.runner" "$stage/runners.json" "$credentials" <<'PY'
import json
from pathlib import Path
import sys

source, record_path, local_path, runners_path, credentials = sys.argv[1:]
policy = {"__name__": "rui_mac_runner_policy"}
# Execute only the staged source file, ignoring adjacent packages and pyc files.
exec(compile(Path(source).read_bytes(), source, "exec"), policy)
record_path, local_path = Path(record_path), Path(local_path)


def read_json(path):
    try:
        if not path.is_symlink() and path.is_file():
            return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        pass
    return None


record, local = read_json(record_path), read_json(local_path)
action, reason = policy["removal_action"](record, read_json(Path(runners_path)), local, credentials == "true")
print(reason, file=sys.stderr)
print(action)
PY
}

root_uninstall() {
    local stage=$1 account_home action home_mode child
    [[ $EUID == 0 && -d $stage ]] || fail 'Internal removal requires root and a staging directory.'
    [[ ! -L $RUNNER_HOME && ! -L $RUNNER_DIR ]] || fail 'Refusing a symlinked runner home or directory.'
    if /usr/bin/dscl . -read /Users/ruici >/dev/null 2>&1; then
        account_home=$(/usr/bin/dscl . -read /Users/ruici NFSHomeDirectory 2>/dev/null || true)
        if [[ $account_home != 'NFSHomeDirectory: /Users/ruici' ]]; then
            [[ -f $RUNNER_HOME/.rui-runner-account && ! -L $RUNNER_HOME/.rui-runner-account \
                && $(/usr/bin/stat -f '%u' "$RUNNER_HOME/.rui-runner-account") == 0 \
                && -z $account_home ]] || fail 'The ruici account has an unexpected home; refusing removal.'
        fi
        /usr/bin/id -Gn ruici | /usr/bin/tr ' ' '\n' | /usr/bin/grep -qx admin \
            && fail 'The ruici account is an administrator; refusing removal.'
    elif [[ ! -e $RUNNER_HOME ]]; then
        if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
            /bin/launchctl bootout "system/$LABEL"
        fi
        /bin/rm -f "$PLIST"
        printf '%s\n' 'No local ruici account or home exists; no remote deregistration was attempted.'
        return
    fi
    [[ -d $RUNNER_HOME && $(/usr/bin/stat -f '%u' "$RUNNER_HOME") == 0 ]] \
        || fail 'The runner home must remain a root-owned directory; repair installation before removal.'
    home_mode=$(/usr/bin/stat -f '%Lp' "$RUNNER_HOME")
    (( (8#$home_mode & 022) == 0 )) || fail 'The runner home is writable by other users; repair installation before removal.'
    # Decide against this invocation's fresh API snapshot before releasing state.
    action=$(removal_decision "$stage")
    case $action in
        repair) fail 'Preserving runner account and home. Resolve the identity error above; repair missing local configuration with install.sh, then retry uninstall.sh.' ;;
        cleanup|deregister) ;;
        *) fail 'Unknown removal decision; preserving the installation.' ;;
    esac
    if [[ $action == deregister ]] && ! /usr/bin/dscl . -read /Users/ruici >/dev/null 2>&1; then
        fail 'The runner account is missing while its remote registration remains; run install.sh to repair before removing it.'
    fi
    if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
        /bin/launchctl bootout "system/$LABEL"
    fi
    /bin/rm -f "$PLIST"
    if [[ $action == deregister ]]; then
        # A finishing job may have changed local files while bootout was running.
        # Reuse the same policy before SDK removal, which can silently skip them.
        action=$(removal_decision "$stage")
        [[ $action == deregister ]] || fail 'Runner state changed while stopping; preserving account and home for repair.'
        [[ -d $RUNNER_HOME/.rui-runner-hooks && ! -L $RUNNER_HOME/.rui-runner-hooks \
            && $(/usr/bin/stat -f '%u' "$RUNNER_HOME/.rui-runner-hooks") == 0 ]] \
            || fail 'The protected hook directory is missing; repair the installation first.'
        /bin/rm -f "$RUNNER_HOME/.rui-runner-hooks/removal-token"
        /usr/bin/install -o ruici -g staff -m 600 "$stage/token" "$RUNNER_HOME/.rui-runner-hooks/removal-token"
        trap '/bin/rm -f "$RUNNER_HOME/.rui-runner-hooks/removal-token"' EXIT
        /usr/bin/sudo -H -u ruici /usr/bin/env -i HOME="$RUNNER_HOME" USER=ruici LOGNAME=ruici \
            PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
            /bin/bash -c 'cd "$1"; token=$(cat "$2"); exec ./config.sh remove --unattended --token "$token"' \
            bash "$RUNNER_DIR" "$RUNNER_HOME/.rui-runner-hooks/removal-token"
        [[ ! -e $RUNNER_DIR/.runner ]] || fail 'Runner configuration remains after deregistration; preserving account and home.'
        /bin/rm -f "$RUNNER_HOME/.rui-runner-hooks/removal-token"
        trap - EXIT
    fi
    # No receipt bypasses a later API read: keep the identity until cleanup ends.
    if /usr/bin/dscl . -read /Users/ruici >/dev/null 2>&1; then
        /usr/bin/dscl . -delete /Users/ruici
    fi
    # Keep the identity if deleting any child fails; a retry can confirm absence again.
    shopt -s dotglob nullglob
    for child in "$RUNNER_HOME"/*; do
        [[ $child == "$REGISTRATION" ]] && continue
        /bin/rm -rf "$child"
    done
    /bin/rm -f "$REGISTRATION"
    /bin/rmdir "$RUNNER_HOME"
    printf '%s\n' 'Installed Rui Mac runner registration is absent; LaunchDaemon, ruici account and home removed.'
}

if [[ ${1-} == --root-uninstall ]]; then
    [[ $# == 2 ]] || fail 'Invalid internal removal arguments.'
    root_uninstall "$2"
    exit
fi
[[ $# == 0 ]] || fail 'Usage: uninstall.sh'
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || fail 'This uninstaller requires an Apple Silicon Mac.'
[[ $EUID != 0 ]] || fail 'Run without sudo so gh uses your administrator login.'
command -v gh >/dev/null || fail 'Install GitHub CLI first: brew install gh'
command -v python3 >/dev/null || fail 'Python 3.11 or newer is required.'
python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))' || fail 'Python 3.11 or newer is required.'
gh auth status --hostname github.com
[[ $(gh api user --jq .login) == DivyanshGolyan ]] || fail 'Authenticate gh as DivyanshGolyan.'
[[ $(gh api "repos/$REPOSITORY" --jq .permissions.admin) == true ]] || fail 'Repository admin access is required.'
stage=$(/usr/bin/mktemp -d /private/tmp/rui-mac-runner-remove.XXXXXXXX)
trap '/bin/rm -rf "$stage"' EXIT
/bin/cp "$SCRIPT_DIR/uninstall.sh" "$SCRIPT_DIR/../mac_runner.py" "$stage/"
command -v python3 > "$stage/python-path"
gh api "repos/$REPOSITORY/actions/runners" --paginate --slurp > "$stage/runner-pages.json"
python3 - "$stage" <<'PY'
import json
from pathlib import Path
import sys
stage = Path(sys.argv[1])
pages = json.loads((stage / "runner-pages.json").read_text())
if not isinstance(pages, list) or not pages or any(not isinstance(page, dict) or not isinstance(page.get("runners"), list) for page in pages):
    raise SystemExit("Cannot read the repository runner list; preserving local installation")
(stage / "runners.json").write_text(json.dumps([runner for page in pages for runner in page["runners"]]))
PY
gh api --method POST "repos/$REPOSITORY/actions/runners/remove-token" --jq .token > "$stage/token"
/bin/chmod 600 "$stage/token"
[[ -s $stage/token ]] || fail 'No runner removal token was returned.'
if [[ -t 0 && -t 1 ]]; then
    /usr/bin/sudo /bin/bash "$stage/uninstall.sh" --root-uninstall "$stage"
else
    printf -v command '/bin/bash %q --root-uninstall %q' "$stage/uninstall.sh" "$stage"
    /usr/bin/osascript - "$command" <<'APPLESCRIPT'
on run argv
    do shell script (item 1 of argv) with administrator privileges
end run
APPLESCRIPT
fi
