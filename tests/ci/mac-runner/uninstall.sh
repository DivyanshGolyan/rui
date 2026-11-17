#!/bin/bash
# Run as the administrator whose gh login owns this repository.
set -euo pipefail
umask 077
REPOSITORY=DivyanshGolyan/rui
RUNNER_HOME=/Users/ruici
RUNNER_DIR=$RUNNER_HOME/actions-runner
PLIST=/Library/LaunchDaemons/com.rui.actions-runner.plist
LABEL=com.rui.actions-runner
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd -P)
fail() { printf '%s\n' "$*" >&2; exit 1; }

root_uninstall() {
    local stage=$1 account_home
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
    elif [[ -f $RUNNER_DIR/.runner ]]; then
        fail 'The runner account is missing but registration remains; restore the account before removing it.'
    fi
    if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
        /bin/launchctl bootout "system/$LABEL"
    fi
    /bin/rm -f "$PLIST"
    # Keep all account and runner state on deregistration failure, so retry can finish.
    if [[ -f $RUNNER_DIR/.runner ]]; then
        # config.sh silently skips remote removal when .credentials is missing.
        # Preserve the local installation so a repair can restore its credentials.
        [[ -s $RUNNER_DIR/.credentials && ! -L $RUNNER_DIR/.credentials ]] \
            || fail 'Runner credentials are missing; run install.sh to repair before uninstalling.'
        [[ -d $RUNNER_HOME/.rui-runner-hooks && ! -L $RUNNER_HOME/.rui-runner-hooks ]] \
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
        # Persist successful deregistration before the remaining local cleanup.
        /usr/bin/touch "$RUNNER_HOME/.rui-runner-deregistered"
        /usr/sbin/chown root:wheel "$RUNNER_HOME/.rui-runner-deregistered"
        /bin/chmod 600 "$RUNNER_HOME/.rui-runner-deregistered"
    elif [[ ! -f $RUNNER_HOME/.rui-runner-deregistered ]]; then
        # A never-configured or already-removed installation is safe only when the
        # API confirms that this machine's runner name is absent.
        "$(cat "$stage/python-path")" -I -S - "$stage/runners.json" "$(cat "$stage/runner-name")" <<'PY'
import json, sys
pages = json.load(open(sys.argv[1]))
if not isinstance(pages, list) or not pages:
    raise SystemExit("Cannot confirm remote runner absence; preserving local state")
for page in pages:
    for runner in page["runners"]:
        if runner["name"] == sys.argv[2]:
            raise SystemExit("Remote runner exists but local configuration is missing; restore the installation before uninstalling")
PY
    fi
    if /usr/bin/dscl . -read /Users/ruici >/dev/null 2>&1; then
        /usr/bin/dscl . -delete /Users/ruici
    fi
    /bin/rm -rf "$RUNNER_HOME"
    printf '%s\n' 'Rui Mac runner deregistered; LaunchDaemon, ruici account and home removed.'
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
/bin/cp "$SCRIPT_DIR/uninstall.sh" "$stage/"
command -v python3 > "$stage/python-path"
/usr/sbin/scutil --get LocalHostName | python3 -c 'import sys; name=sys.stdin.read().strip(); assert name and "\n" not in name; print(name + "-rui")' > "$stage/runner-name"
gh api "repos/$REPOSITORY/actions/runners" --paginate --slurp > "$stage/runners.json"
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
