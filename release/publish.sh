# Replace PREFIX/bin/rui with a complete build, then say what the replacement
# changed. POSIX sh; defines functions only. install.sh sources this file, and
# tests/ci/release.py inlines it into the published installer.
# rui_publish is the only entry point. _rui_* names are private, except
# _rui_selected, which tests/integration/host_status_integration.py runs
# against the real build.

rui_publish() {
    _rui_link=$1/bin/rui
    _rui_had=0
    if [ -e "$_rui_link" ] || [ -L "$_rui_link" ]; then _rui_had=1; fi
    _rui_old_bin=$(_rui_target "$_rui_link")
    _rui_old=$(_rui_label "$_rui_link" "${_rui_old_bin%/bin/rui}")
    _rui_receipt=$("$2/bin/rui" --publish-install "$HOME" "$2" "${4:-intentional-source}") || return 1
    _rui_publication=unknown
    case $_rui_receipt in
        *'"outcome":"installed"'*) _rui_publication=installed ;;
        *'"outcome":"unchanged"'*) _rui_publication=unchanged ;;
    esac
    (
        set +eu
        _rui_after=$(_rui_target "$_rui_link")
        if [ -n "$_rui_after" ]; then
            _rui_observe "$1" "${_rui_after%/bin/rui}" "$3"
            _rui_render "$1"
            "$2/bin/rui" --installation-path </dev/null || :
        else
            printf 'Publication completed, but the selected command could not be inspected. Check %s.\n' "$_rui_link" >&2
        fi
    ) || :
}

# _rui_target LINK -> LINK's target when LINK is a symlink to an executable
# file, else nothing. A relative target resolves against LINK's directory.
_rui_target() {
    [ -L "$1" ] || return 0
    _rui_t=$(readlink "$1") || return 0
    case $_rui_t in /*) ;; *) _rui_t=${1%/*}/$_rui_t ;; esac
    if [ -f "$_rui_t" ] && [ -x "$_rui_t" ]; then printf '%s' "$_rui_t"; fi
}

# _rui_label BIN BUILD -> the name a person knows the build by: the release
# version from `BIN --version` ("0.40.0"), else BUILD/revision ("1a2b3c4",
# "1a2b3c4 (local changes)"), else nothing. Builds from before 2026-10-24
# lack --version; without a terminal they refuse it.
_rui_label() {
    _rui_v=
    if [ -n "$1" ] && [ -x "$1" ]; then
        # </dev/null: under curl | sh, a probe must never read the script.
        _rui_v=$("$1" --version </dev/null 2>/dev/null) || _rui_v=
    fi
    case $_rui_v in
        "rui unreleased ("*) _rui_v= ;;
        "rui "*" ("*")") _rui_v=${_rui_v#rui }; _rui_v=${_rui_v%% (*} ;;
        *) _rui_v= ;;
    esac
    if [ -z "$_rui_v" ] && [ -n "$2" ] && [ -f "$2/revision" ]; then
        _rui_v=$(cat "$2/revision" 2>/dev/null) || _rui_v=
    fi
    printf '%s' "$_rui_v"
}

# _rui_selected BIN -> two lines from one `BIN defaults inspect`:
#   1. the selected Store ("store"), or an empty line when it is absent, null
#      or holds a JSON escape;
#   2. the Host status tag ("host":{"status":...}), or "unknown".
# The build owns Store selection; this never re-derives it.
_rui_selected() {
    _rui_j=$("$1" defaults inspect </dev/null 2>/dev/null) || _rui_j=
    case $_rui_j in
        *'"store":"'*) _rui_s=${_rui_j#*'"store":"'}; _rui_s=${_rui_s%%\"*} ;;
        *) _rui_s= ;;
    esac
    case $_rui_s in *\\*) _rui_s= ;; esac
    case $_rui_j in
        *'"host":{"status":"'*) _rui_h=${_rui_j#*'"host":{"status":"'}; _rui_h=${_rui_h%%\"*} ;;
        *) _rui_h=unknown ;;
    esac
    printf '%s\n%s\n' "$_rui_s" "$_rui_h"
}

# _rui_saved_format STORE FALLBACK -> the format of the saved work in STORE:
# nothing when STORE/rui.sqlite3 does not exist; the user_version in its
# header (bytes 60-63, big-endian) when that is set; FALLBACK, else "unknown",
# while the header is unwritten (an empty file, or user_version 0: a Host made
# the Store and has not checkpointed it); "unknown" for any other file.
_rui_saved_format() {
    [ -n "$1" ] && [ -f "$1/rui.sqlite3" ] || return 0
    _rui_fallback=${2:-unknown}
    if [ ! -s "$1/rui.sqlite3" ]; then printf '%s' "$_rui_fallback"; return 0; fi
    # od -v: never collapse repeated lines into "*"; set -f: the split never globs.
    set -f
    set -- $(od -v -An -tu1 -N64 "$1/rui.sqlite3" 2>/dev/null)
    set +f
    if [ $# != 64 ] || [ "$1 $2 $3 $4 $5 $6" != "83 81 76 105 116 101" ]; then
        printf unknown
        return 0
    fi
    _rui_n=$(( (${61} << 24) + (${62} << 16) + (${63} << 8) + ${64} ))
    if [ "$_rui_n" = 0 ]; then printf '%s' "$_rui_fallback"; else printf '%s' "$_rui_n"; fi
}

# _rui_ready BIN STORE -> success when that controller reaches a ready Host.
_rui_ready() {
    case $("$1" host status --store "$2" </dev/null 2>/dev/null) in *'"status":"ready"'*) return 0 ;; esac
    return 1
}

# _rui_pause BIN -> the Host shutdown command BIN knows: builds before the
# rename call it host stop.
_rui_pause() {
    if "$1" host pause --help </dev/null >/dev/null 2>&1; then printf 'host pause'; else printf 'host stop'; fi
}

# _rui_show PATH -> "~/rest" when PATH is under HOME, else PATH (display only).
# _rui_word PATH -> the same, but single-quoted outside HOME, for a path inside
# a command the user will paste.
_rui_show() {
    case $1 in
        "$HOME"/*) [ -n "$HOME" ] && printf '~/%s' "${1#"$HOME"/}" && return 0 ;;
    esac
    printf '%s' "$1"
}
_rui_word() {
    case $1 in
        "$HOME"/*) [ -n "$HOME" ] && printf '~/%s' "${1#"$HOME"/}" && return 0 ;;
    esac
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# _rui_observe PREFIX BUILD -> sets every fact _rui_render reads.
_rui_observe() {
    _rui_new_bin=$2/bin/rui
    _rui_new=$(_rui_label "$_rui_new_bin" "$2")
    if [ "$_rui_publication" = unchanged ]; then
        _rui_kind=current
    elif [ "$_rui_had" = 0 ]; then
        _rui_kind=first
    elif [ -n "$_rui_old" ] && [ "$_rui_old" = "$_rui_new" ]; then
        _rui_kind=reinstall
    else
        _rui_kind=update
    fi
    _rui_facts=$("$2/bin/rui" --installation-facts </dev/null 2>/dev/null) || _rui_facts=
    _rui_minimum=$(printf '%s' "$_rui_facts" | sed -n 's/.*"minimum_schema_version":\([0-9][0-9]*\).*/\1/p')
    _rui_target_format=$(printf '%s' "$_rui_facts" | sed -n 's/.*"schema_version":\([0-9][0-9]*\).*/\1/p')
    _rui_compat=unknown
    _rui_sel=$(_rui_selected "$2/bin/rui")
    _rui_store=${_rui_sel%%"
"*}
    _rui_status=${_rui_sel#*"
"}
    _rui_saved=$(_rui_saved_format "$_rui_store" unknown)
    case $_rui_saved:$_rui_minimum:$_rui_target_format in
        *[!0-9:]*|:*|*:|*::*) ;;
        *)
            if [ "$_rui_minimum" -gt "$_rui_target_format" ]; then _rui_compat=unknown
            elif [ "$_rui_saved" = "$_rui_target_format" ]; then _rui_compat=unchanged
            elif [ "$_rui_saved" -ge "$_rui_minimum" ] && [ "$_rui_saved" -lt "$_rui_target_format" ]; then _rui_compat=migration
            else _rui_compat=unsupported
            fi ;;
    esac
    _rui_controller=
    _rui_pause_words=
    case $_rui_status in
        unavailable|store_unavailable) _rui_host=none ;;
        ready) _rui_host=ready; _rui_controller=$_rui_new_bin ;;
        owned_unavailable) _rui_host=busy ;;
        incompatible)
            if [ -n "$_rui_store" ] && [ -n "$_rui_old_bin" ] && _rui_ready "$_rui_old_bin" "$_rui_store"; then
                _rui_host=retained_compatible
                _rui_controller=$_rui_old_bin
            else
                _rui_host=incompatible
            fi ;;
        *) _rui_host=unknown ;;
    esac
    if [ "$_rui_host" != none ] && [ -z "$_rui_store" ]; then _rui_host=unknown; fi
    if [ -n "$_rui_controller" ]; then _rui_pause_words=$(_rui_pause "$_rui_controller"); fi
}

# _rui_render PREFIX -> the report from the observed facts.
_rui_render() {
    _rui_cmd=$(_rui_word "$1/bin/rui")
    _rui_builds=$(_rui_show "$1/lib/rui")
    _rui_host_is="Rui's background Host (the process that runs your Sessions)"
    printf '\n'
    case $_rui_kind in
        current) printf 'Rui %s is already selected. No installation changed.\n' "$_rui_new" ;;
        first) printf 'Installed Rui %s at %s.\n' "$_rui_new" "$(_rui_show "$1/bin/rui")" ;;
        reinstall) printf 'Reinstalled Rui %s. Saved work and sign-in were kept.\n' "$_rui_new" ;;
        *)
            if [ -n "$_rui_old" ]; then
                printf 'Updated Rui from %s to %s. Saved work and sign-in were kept.\n' "$_rui_old" "$_rui_new"
            else
                printf 'Updated Rui to %s. Saved work and sign-in were kept.\n' "$_rui_new"
            fi ;;
    esac
    case $_rui_compat in
        migration)
            printf 'Your defaults-selected SQLite Store uses format %s. Host startup can back it up and migrate it to format %s; installing alone does not migrate it. MySQL schema changes remain operator-owned.\n' "$_rui_saved" "$_rui_target_format" ;;
        unsupported)
            printf 'Your defaults-selected Store uses format %s; this build supports SQLite formats %s through %s. Installing did not change the Store. Use a compatible build or follow the Store recovery guidance.\n' "$_rui_saved" "$_rui_minimum" "$_rui_target_format" ;;
        unknown)
            if [ -n "$_rui_saved" ]; then
                printf 'Could not establish compatibility for the defaults-selected Store. Host startup performs the authoritative check; installing did not migrate or reset saved work. MySQL schema changes remain operator-owned.\n'
            fi ;;
    esac
    case $_rui_host in
        ready)
            printf 'For the defaults-selected Store %s, %s is ready. Its running build was not identified; installation did not restart it. When its work finishes, pause it with: %s %s --store %s\n' \
                "$(_rui_show "$_rui_store")" "$_rui_host_is" "$(_rui_word "$_rui_controller")" "$_rui_pause_words" "$(_rui_word "$_rui_store")" ;;
        retained_compatible)
            printf 'For the defaults-selected Store %s, the selected command reported an incompatible Host; the retained command can reach a ready Host. Its running build was not identified; installation did not restart it. When its work finishes, pause it with: %s %s --store %s\n' \
                "$(_rui_show "$_rui_store")" "$(_rui_word "$_rui_controller")" "$_rui_pause_words" "$(_rui_word "$_rui_store")" ;;
        incompatible)
            printf 'For the defaults-selected Store %s, the selected command reports an incompatible Host; its running build was not identified. Installation did not restart it. Use a compatible Rui command to inspect and pause it manually. Retained builds stay in %s.\n' \
                "$(_rui_show "$_rui_store")" "$_rui_builds" ;;
        busy)
            printf 'For the defaults-selected Store %s, Host ownership was reported, but readiness was not confirmed. Its running build was not identified; installation did not restart it. Inspect it with: %s host status --store %s\n' \
                "$(_rui_show "$_rui_store")" "$_rui_cmd" "$(_rui_word "$_rui_store")" ;;
        unknown)
            printf 'Could not inspect the Host for the defaults-selected Store. Its identity and status are unknown; installation did not restart it. The installation succeeded.\n' >&2 ;;
    esac
    if [ "$_rui_kind" = first ]; then
        printf 'Next: %s auth login codex (setup steps: https://github.com/DivyanshGolyan/rui#start-a-conversation)\n' "$_rui_cmd"
    fi
}
