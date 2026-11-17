#!/bin/bash
# Run as the Mac's administrator, not with sudo. Only the local setup phase elevates.
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

as_runner() {
    /usr/bin/sudo -H -u ruici /usr/bin/env -i HOME="$RUNNER_HOME" USER=ruici LOGNAME=ruici \
        PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
        LANG=en_US.UTF-8 TMPDIR="$RUNNER_HOME/tmp/" "$@"
}

validate_registration_file() {
    if [[ -e $REGISTRATION || -L $REGISTRATION ]]; then
        [[ -f $REGISTRATION && ! -L $REGISTRATION \
            && $(/usr/bin/stat -f '%u' "$REGISTRATION") == 0 \
            && $(/usr/bin/stat -f '%Lp' "$REGISTRATION") == 600 ]] \
            || fail 'Registration record must be a root-owned regular file with mode 600.'
    fi
}

registration_state() {
    local stage=$1 operation=$2 allow_new=$3 proposed_name=$4
    validate_registration_file
    if [[ ! -e $REGISTRATION && ( -e $RUNNER_DIR/.runner || -L $RUNNER_DIR/.runner ) ]]; then
        [[ -f $RUNNER_HOME/.rui-runner-account && ! -L $RUNNER_HOME/.rui-runner-account \
            && $(/usr/bin/stat -f '%u' "$RUNNER_HOME/.rui-runner-account") == 0 \
            && $(/usr/bin/stat -f '%Lp' "$RUNNER_HOME/.rui-runner-account") == 600 ]] \
            || fail 'Cannot adopt local runner configuration without its protected account marker.'
    fi
    "$(cat "$stage/python-path")" -I -S - "$stage/mac_runner.py" "$REGISTRATION" "$RUNNER_DIR/.runner" "$operation" "$allow_new" "$proposed_name" "$stage/runners.json" <<'PY'
import json
import os
from pathlib import Path
import sys
import tempfile

source, record_path, local_path, operation, allow_new, proposed, runners_path = sys.argv[1:]
policy = {"__name__": "rui_mac_runner_policy"}
# Execute these exact staged source bytes; never search adjacent packages or pyc.
exec(compile(Path(source).read_bytes(), source, "exec"), policy)
record_path, local_path = Path(record_path), Path(local_path)


def save(record):
    fd, temporary = tempfile.mkstemp(prefix=".rui-runner-registration.", dir=record_path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(record, stream)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, record_path)
        directory = os.open(record_path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def local_registration():
    if local_path.is_symlink() or not local_path.is_file():
        raise ValueError("Missing regular local runner configuration")
    local = json.loads(local_path.read_text(encoding="utf-8-sig"))
    if local.get("gitHubUrl", "").rstrip("/") != "https://github.com/DivyanshGolyan/rui":
        raise ValueError("Local runner configuration belongs to a different repository")
    return policy["registration_record"](local.get("agentName"), local.get("agentId"))


try:
    if record_path.exists():
        record = json.loads(record_path.read_text())
        name, runner_id = policy["registration_identity"](record)
    elif local_path.exists() or local_path.is_symlink():
        record = local_registration()
        name, runner_id = policy["registration_identity"](record)
        if runner_id is None:
            raise ValueError("Local runner configuration has no registration ID")
        save(record)
    elif operation == "prepare" and allow_new == "true":
        record = policy["registration_record"](proposed)
        name, runner_id = policy["registration_identity"](record)
        save(record)
    else:
        raise ValueError("Installed registration identity is missing; restore its record or local .runner before repair")
    if operation in ("prepare", "intent"):
        local_id = None
        if local_path.exists() or local_path.is_symlink():
            local_name, local_id = policy["registration_identity"](local_registration())
            if local_name != name or local_id is None:
                raise ValueError("Local configuration differs from the installed registration name")
        # Keep the prior ID until its exact remote identity is confirmed. A renamed
        # or replaced registration must not be forgotten by name-based --replace.
        try:
            policy["registration_candidate"](record, json.loads(Path(runners_path).read_text()), local_id)
        except ValueError as error:
            raise ValueError(f"{error}; restore the exact GitHub runner identity before repair") from error
    if operation == "intent":
        save(policy["registration_record"](name))
    elif operation == "complete":
        installed = local_registration()
        installed_name, installed_id = policy["registration_identity"](installed)
        if installed_name != name or installed_id is None:
            raise ValueError("Configured runner does not match the installation intent")
        save(installed)
    elif operation != "prepare":
        raise ValueError("Unknown registration operation")
    print(name)
except (OSError, ValueError, TypeError, AttributeError, KeyError) as error:
    raise SystemExit(f"Registration identity unavailable: {error}. Preserve this installation and restore its exact recorded identity before retrying.")
PY
}

root_install() {
    local stage=$1 uid password directory runner_name python_path account_home new_install=false
    [[ $EUID == 0 && -d $stage ]] || fail 'Internal setup requires root and a staging directory.'
    runner_name=$(cat "$stage/runner-name")
    python_path=$(cat "$stage/python-path")
    # Refuse symlinked policy parents: ownership of the leaf alone cannot protect a hook.
    [[ ! -L $RUNNER_HOME && ! -L $RUNNER_DIR ]] || fail 'Runner home or runner directory is a symlink.'
    # Record ownership before creating the directory-service record. An interrupted
    # creation can then be repaired without adopting an unrelated partial account.
    if /usr/bin/dscl . -read /Users/ruici >/dev/null 2>&1; then
        account_home=$(/usr/bin/dscl . -read /Users/ruici NFSHomeDirectory 2>/dev/null || true)
        if [[ $account_home != 'NFSHomeDirectory: /Users/ruici' ]]; then
            [[ -f $RUNNER_HOME/.rui-runner-account && ! -L $RUNNER_HOME/.rui-runner-account \
                && $(/usr/bin/stat -f '%u' "$RUNNER_HOME/.rui-runner-account") == 0 \
                && -z $account_home ]] || fail 'The ruici account has an unexpected home; refusing setup.'
        fi
        ! /usr/bin/id -Gn ruici | /usr/bin/tr ' ' '\n' | /usr/bin/grep -qx admin || fail 'Existing ruici must not be an administrator.'
    else
        [[ -e $RUNNER_HOME ]] || new_install=true
        /bin/mkdir -p "$RUNNER_HOME"
        /usr/sbin/chown root:wheel "$RUNNER_HOME"
        /bin/chmod -N "$RUNNER_HOME"
        /bin/chmod 755 "$RUNNER_HOME"
        # Persist new-install intent before creating even a partial account record.
        runner_name=$(registration_state "$stage" prepare "$new_install" "$runner_name")
        [[ ! -L $RUNNER_HOME/.rui-runner-account ]] || fail 'Account marker is a symlink.'
        uid=499
        while [[ -n $(/usr/bin/dscl . -search /Users UniqueID "$uid") ]]; do
            uid=$((uid - 1))
            (( uid >= 400 )) || fail 'No unused hidden account UID in 400..499.'
        done
        printf '%s\n' "$uid" > "$RUNNER_HOME/.rui-runner-account"
        /usr/sbin/chown root:wheel "$RUNNER_HOME/.rui-runner-account"
        /bin/chmod 600 "$RUNNER_HOME/.rui-runner-account"
        /usr/bin/dscl . -create /Users/ruici
    fi
    /bin/mkdir -p "$RUNNER_HOME"
    /usr/sbin/chown root:wheel "$RUNNER_HOME"
    /bin/chmod -N "$RUNNER_HOME"
    /bin/chmod 755 "$RUNNER_HOME"
    # Repairs preserve the installed name even after LocalHostName changes.
    runner_name=$(registration_state "$stage" prepare "$new_install" "$runner_name")
    # dscl exits 0 for a missing key ("No such key: UniqueID"), so check its output.
    if [[ $(/usr/bin/dscl . -read /Users/ruici UniqueID 2>/dev/null) != 'UniqueID: '* ]]; then
        [[ -f $RUNNER_HOME/.rui-runner-account && ! -L $RUNNER_HOME/.rui-runner-account \
            && $(/usr/bin/stat -f '%u' "$RUNNER_HOME/.rui-runner-account") == 0 ]] \
            || fail 'Cannot repair ruici without its root-owned account marker.'
        uid=$(cat "$RUNNER_HOME/.rui-runner-account")
        [[ $uid =~ ^[0-9]+$ && $uid -ge 400 && $uid -le 499 ]] || fail 'Invalid account UID marker.'
        [[ -z $(/usr/bin/dscl . -search /Users UniqueID "$uid") ]] || fail 'The reserved account UID is now in use.'
        /usr/bin/dscl . -create /Users/ruici UniqueID "$uid"
    fi
    /usr/bin/dscl . -create /Users/ruici PrimaryGroupID 20
    /usr/bin/dscl . -create /Users/ruici NFSHomeDirectory "$RUNNER_HOME"
    /usr/bin/dscl . -create /Users/ruici UserShell /bin/bash
    /usr/bin/dscl . -create /Users/ruici RealName 'Rui CI runner'
    password=$(/usr/bin/openssl rand -base64 48)
    /usr/bin/dscl . -passwd /Users/ruici "$password"
    unset password
    /usr/bin/dscl . -create /Users/ruici IsHidden 1
    /bin/mkdir -p "$RUNNER_HOME"
    /usr/sbin/chown root:wheel "$RUNNER_HOME"
    /bin/chmod -N "$RUNNER_HOME"
    /bin/chmod 755 "$RUNNER_HOME"
    # Only these children are writable by jobs. The policy's parents stay root-owned.
    for directory in actions-runner .cache .config .local .npm .cargo .rustup Library tmp go tool-cache; do
        [[ ! -L $RUNNER_HOME/$directory ]] || fail "Runner directory is a symlink: $directory"
        /bin/mkdir -p "$RUNNER_HOME/$directory"
        /usr/sbin/chown ruici:staff "$RUNNER_HOME/$directory"
        /bin/chmod 700 "$RUNNER_HOME/$directory"
    done
    [[ ! -L $RUNNER_HOME/.rui-runner-hooks ]] || fail 'Policy directory is a symlink.'
    /bin/mkdir -p "$RUNNER_HOME/.rui-runner-hooks"
    /usr/sbin/chown root:wheel "$RUNNER_HOME/.rui-runner-hooks"
    /bin/chmod -N "$RUNNER_HOME/.rui-runner-hooks"
    /bin/chmod 755 "$RUNNER_HOME/.rui-runner-hooks"
    # Validate service access before interrupting an existing runner.
    as_runner "$python_path" -I -S -c 'import sys; assert sys.version_info >= (3, 11)'
    # The inner bash expands these variables after switching to ruici.
    # shellcheck disable=SC2016
    as_runner /bin/bash -c 'for tool in python3 git curl tmux go node npm screen openssl tar gzip unzip zip rsync zstd perl xz cc make; do command -v "$tool" >/dev/null || exit; done'
    # A failed update leaves the old registration available for repair or uninstall.
    if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
        /bin/launchctl bootout "system/$LABEL"
    fi
    /bin/rm -f "$RUNNER_HOME/.rui-runner-hooks/job-started.sh" "$RUNNER_HOME/.rui-runner-hooks/allowlist" "$RUNNER_HOME/.rui-runner-hooks/mac_runner.py"
    /usr/bin/install -o root -g wheel -m 755 "$stage/job-started.sh" "$RUNNER_HOME/.rui-runner-hooks/job-started.sh"
    /usr/bin/install -o root -g wheel -m 644 "$stage/mac_runner.py" "$RUNNER_HOME/.rui-runner-hooks/mac_runner.py"
    /usr/bin/install -o root -g wheel -m 644 "$stage/allowlist" "$RUNNER_HOME/.rui-runner-hooks/allowlist"
    /bin/rm -f "$RUNNER_HOME/.rui-runner-hooks/runner.tar.gz"
    /usr/bin/install -o root -g wheel -m 644 "$stage/runner.tar.gz" "$RUNNER_HOME/.rui-runner-hooks/runner.tar.gz"
    as_runner /usr/bin/tar -xzf "$RUNNER_HOME/.rui-runner-hooks/runner.tar.gz" -C "$RUNNER_DIR"
    /bin/rm -f "$RUNNER_HOME/.rui-runner-hooks/runner.tar.gz"
    /bin/rm -f "$RUNNER_HOME/.rui-runner-hooks/registration-token"
    /usr/bin/install -o ruici -g staff -m 600 "$stage/token" "$RUNNER_HOME/.rui-runner-hooks/registration-token"
    trap '/bin/rm -f "$RUNNER_HOME/.rui-runner-hooks/registration-token"' EXIT
    /bin/rm -f "$RUNNER_HOME/.rui-runner-deregistered"
    runner_name=$(registration_state "$stage" intent false "$runner_name")
    if [[ -e $RUNNER_DIR/.runner || -L $RUNNER_DIR/.runner ]]; then
        # Runner-owned removal resets local credentials. --replace repairs the same
        # remote name even when an old local registration was deleted on GitHub.
        # The inner bash expands these variables after switching to ruici.
        # shellcheck disable=SC2016
        as_runner /bin/bash -c 'cd "$1"; exec ./config.sh remove --local' bash "$RUNNER_DIR"
    fi
    # The token crosses sudo only as a private filename, never in privilege argv.
    # The inner bash expands these variables after switching to ruici.
    # shellcheck disable=SC2016
    as_runner /bin/bash -c 'cd "$1"; token=$(cat "$2"); exec ./config.sh --unattended --url https://github.com/DivyanshGolyan/rui --token "$token" --name "$3" --labels rui-mac --work _work --replace' \
        bash "$RUNNER_DIR" "$RUNNER_HOME/.rui-runner-hooks/registration-token" "$runner_name"
    runner_name=$(registration_state "$stage" complete false "$runner_name")
    /bin/rm -f "$RUNNER_HOME/.rui-runner-hooks/registration-token"
    trap - EXIT
    # Preserve runner-managed environment entries while repairing this one hook setting.
    as_runner "$python_path" -I -S - "$RUNNER_DIR/.env" "$RUNNER_HOME/.rui-runner-hooks/job-started.sh" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
lines = path.read_text().splitlines() if path.exists() else []
lines = [line for line in lines if not line.startswith("ACTIONS_RUNNER_HOOK_JOB_STARTED=")]
path.write_text("\n".join(lines + ["ACTIONS_RUNNER_HOOK_JOB_STARTED=" + sys.argv[2]]) + "\n")
PY
    "$python_path" -I -S - "$PLIST" "$RUNNER_DIR" "$RUNNER_HOME" <<'PY'
import plistlib, sys
path, runner, home = sys.argv[1:]
with open(path, "wb") as stream:
    plistlib.dump({
        "Label": "com.rui.actions-runner",
        "ProgramArguments": ["/bin/bash", runner + "/run.sh"],
        "WorkingDirectory": runner,
        "UserName": "ruici", "GroupName": "staff",
        "RunAtLoad": True, "KeepAlive": True, "Nice": 10,
        "StandardOutPath": runner + "/launchd.stdout.log",
        "StandardErrorPath": runner + "/launchd.stderr.log",
        "EnvironmentVariables": {
            "HOME": home, "USER": "ruici", "LOGNAME": "ruici", "LANG": "en_US.UTF-8",
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": home + "/tmp/",
            "RUNNER_TOOL_CACHE": home + "/tool-cache",
            "AGENT_TOOLSDIRECTORY": home + "/tool-cache",
            "ACTIONS_RUNNER_HOOK_JOB_STARTED": home + "/.rui-runner-hooks/job-started.sh",
        },
    }, stream)
PY
    /usr/sbin/chown root:wheel "$PLIST"
    /bin/chmod 644 "$PLIST"
    /usr/bin/plutil -lint "$PLIST"
    /bin/launchctl enable "system/$LABEL"
    /bin/launchctl bootstrap system "$PLIST"
}

privileged_install() {
    local stage=$1 command
    if [[ -t 0 && -t 1 ]]; then
        /usr/bin/sudo /bin/bash "$stage/install.sh" --root-install "$stage"
    else
        printf -v command '/bin/bash %q --root-install %q' "$stage/install.sh" "$stage"
        /usr/bin/osascript - "$command" <<'APPLESCRIPT'
on run argv
    do shell script (item 1 of argv) with administrator privileges
end run
APPLESCRIPT
    fi
}

check_github() {
    gh auth status --hostname github.com
    [[ $(gh api user --jq .login) == DivyanshGolyan ]] || fail 'Authenticate gh as DivyanshGolyan.'
    [[ $(gh api "repos/$REPOSITORY" --jq .permissions.admin) == true ]] || fail 'Repository admin access is required.'
}

status_token() {
    local token=
    check_github
    /usr/bin/open 'https://github.com/settings/personal-access-tokens/new?name=Rui%20Mac%20runner%20status&description=Read%20DivyanshGolyan%2Frui%20self-hosted%20runner%20availability&target_name=DivyanshGolyan&administration=read'
    printf '%s\n' 'Select only DivyanshGolyan/rui, with Administration: Read-only, then generate the token.'
    printf '%s' 'Paste the token (hidden), then press Enter: ' >&2
    IFS= read -r -s token || [[ -n $token ]]
    printf '\n' >&2
    [[ -n $token ]] || fail 'No token was supplied.'
    printf '%s' "$token" | gh secret set MAC_RUNNER_STATUS_TOKEN --repo "$REPOSITORY"
    unset token
}

if [[ ${1-} == --root-install ]]; then
    [[ $# == 2 ]] || fail 'Invalid internal setup arguments.'
    root_install "$2"
    exit
fi
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || fail 'This installer requires an Apple Silicon Mac.'
[[ $EUID != 0 ]] || fail 'Run as your administrator account without sudo; GitHub authentication stays non-root.'
case ${1-} in
    status-token) [[ $# == 1 ]] || fail 'Usage: install.sh status-token'; status_token; exit ;;
    --lock-home|'') ;;
    *) fail 'Usage: install.sh [--lock-home | status-token]' ;;
esac
[[ $# -le 1 ]] || fail 'Usage: install.sh [--lock-home | status-token]'
/usr/bin/id -Gn | /usr/bin/tr ' ' '\n' | /usr/bin/grep -qx admin || fail 'Use a macOS administrator account.'
missing=()
for tool in python3 git curl gh tmux go node npm screen openssl tar gzip unzip zip rsync zstd perl xz cc make; do
    PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
[[ ${#missing[@]} == 0 ]] || fail "Missing tools: ${missing[*]}. Install Homebrew prerequisites: brew install python git curl gh tmux go node screen openssl zstd rsync xz"
python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))' || fail 'Python 3.11 or newer is required.'
runner_python=$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin python3 -I -S -c 'import sys; assert sys.version_info >= (3, 11); print(sys.executable)') \
    || fail 'Install Python 3.11 or newer on the runner PATH: brew install python'
[[ $(/usr/bin/xcode-select -p) == */Xcode*.app/Contents/Developer ]] || fail 'Select full Xcode with sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer.'
/usr/bin/xcodebuild -version
/usr/bin/xcodebuild -checkFirstLaunchStatus || fail 'Complete Xcode first launch and accept its license.'
/usr/bin/xcrun --find clang >/dev/null
/usr/bin/xcrun --sdk macosx --show-sdk-path >/dev/null
if [[ ${1-} == --lock-home ]]; then
    /bin/chmod 700 "$HOME"
fi
home_mode=$(/usr/bin/stat -f '%Lp' "$HOME")
if (( (8#$home_mode & 077) != 0 )); then
    printf '%s\n' "Warning: $HOME is accessible by group/other users. Re-run with --lock-home to chmod 700 it." >&2
fi
check_github
# These settings and token requests intentionally run under the administrator's gh identity.
gh api --method PUT "repos/$REPOSITORY/actions/permissions/fork-pr-contributor-approval" \
    -f approval_policy=all_external_contributors >/dev/null
secrets=$(gh api "repos/$REPOSITORY/actions/secrets" --paginate --jq '.secrets[].name')
if printf '%s\n' "$secrets" | /usr/bin/grep -qx MAC_RUNNER_STATUS_TOKEN; then
    printf '%s\n' 'Repository secret MAC_RUNNER_STATUS_TOKEN exists.'
else
    printf '%s\n' 'Repository secret MAC_RUNNER_STATUS_TOKEN is missing. Run install.sh status-token after setup.'
fi
stage=$(/usr/bin/mktemp -d /private/tmp/rui-mac-runner.XXXXXXXX)
trap '/bin/rm -rf "$stage"' EXIT
/bin/cp "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/job-started.sh" "$SCRIPT_DIR/../mac_runner.py" "$stage/"
python3 "$SCRIPT_DIR/../mac_runner.py" allowlist > "$stage/allowlist"
[[ -s $stage/allowlist ]] || fail 'The runner allowlist is empty.'
printf '%s\n' "$runner_python" > "$stage/python-path"
/usr/sbin/scutil --get LocalHostName | python3 -c 'import sys; name=sys.stdin.read().strip(); assert name and "\n" not in name; print(name + "-rui")' > "$stage/runner-name"
# Public release metadata supplies both the exact asset URL and release-note checksum.
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    https://api.github.com/repos/actions/runner/releases/latest -o "$stage/release.json"
python3 - "$stage" <<'PY'
import json, re, sys
from pathlib import Path
stage = Path(sys.argv[1])
release = json.loads((stage / "release.json").read_text())
tag = release["tag_name"]
if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag) or release.get("draft") or release.get("prerelease"):
    raise SystemExit("Expected the latest stable actions/runner release")
asset = "actions-runner-osx-arm64-" + tag[1:] + ".tar.gz"
url = "https://github.com/actions/runner/releases/download/" + tag + "/" + asset
if sum(item.get("name") == asset and item.get("browser_download_url") == url for item in release["assets"]) != 1:
    raise SystemExit("Expected exactly one osx-arm64 asset")
notes = release["body"]
hashes = re.findall(r"<!--\s*BEGIN SHA osx-arm64\s*-->\s*([a-fA-F0-9]{64})\s*<!--\s*END SHA osx-arm64\s*-->", notes)
for line in notes.splitlines():
    if asset in line:
        hashes.extend(re.findall(r"\b[a-fA-F0-9]{64}\b", line))
hashes = {value.lower() for value in hashes}
if len(hashes) != 1:
    raise SystemExit("Missing or ambiguous osx-arm64 SHA256 in release notes")
(stage / "download-url").write_text(url + "\n")
(stage / "expected-sha256").write_text(hashes.pop() + "\n")
print("Installing actions/runner " + tag + " (osx-arm64)")
PY
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    "$(cat "$stage/download-url")" -o "$stage/runner.tar.gz"
actual=$(/usr/bin/shasum -a 256 "$stage/runner.tar.gz")
[[ ${actual%% *} == "$(cat "$stage/expected-sha256")" ]] || fail 'Runner archive SHA256 mismatch.'
# Preserve any prior ID whose remote name changed instead of replacing its evidence.
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
gh api --method POST "repos/$REPOSITORY/actions/runners/registration-token" --jq .token > "$stage/token"
/bin/chmod 600 "$stage/token"
[[ -s $stage/token ]] || fail 'No runner registration token was returned.'
privileged_install "$stage"
printf '%s\n' 'GitHub runner status (registration may take a moment to become online):'
gh api "repos/$REPOSITORY/actions/runners" --paginate --jq '.runners[] | select(any(.labels[]; .name == "rui-mac")) | {name,status,busy,labels: [.labels[].name]}'
printf '%s\n' \
    'Pause locally: sudo launchctl bootout system/com.rui.actions-runner' \
    'Resume locally: sudo launchctl bootstrap system /Library/LaunchDaemons/com.rui.actions-runner.plist' \
    'Disable routing: gh variable set RUI_MAC_RUNNER --repo DivyanshGolyan/rui --body off' \
    "Uninstall: /bin/bash '$SCRIPT_DIR/uninstall.sh'"
