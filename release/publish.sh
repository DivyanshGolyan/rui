# Replace PREFIX/bin/rui with a complete build, then say what the replacement
# changed. POSIX sh; defines functions only. install.sh sources this file, and
# tests/ci/release.py inlines it into the published installer.
# rui_publish is the only entry point. _rui_* names are private, except
# _rui_selected, which tests/integration/host_status_integration.py runs
# against the real build.

# rui_publish PREFIX BUILD FORMAT
#   PREFIX  the install prefix, $HOME/.local; the command is PREFIX/bin/rui.
#   BUILD   a complete, checked build with an executable BUILD/bin/rui.
#   FORMAT  the Store format BUILD opens (its schema_version).
# Renames a symlink to BUILD/bin/rui over PREFIX/bin/rui, so no executable a
# running process uses is ever modified. Then prints the report on stdout, with
# one stderr line when the Host cannot be checked. Returns nonzero only when the
# replacement fails: nothing after the rename can fail the installation. The
# report never opens SQLite, starts, stops or signals a Host, edits a profile
# or prints command output.
rui_publish() {
    _rui_link=$1/bin/rui
    _rui_had=0
    if [ -e "$_rui_link" ] || [ -L "$_rui_link" ]; then _rui_had=1; fi
    _rui_old_bin=$(_rui_target "$_rui_link")
    _rui_old=$(_rui_label "$_rui_link" "${_rui_old_bin%/bin/rui}")
    _rui_tmp=$(mktemp -d "$1/bin/.rui-install.XXXXXX") || return 1
    if ln -s "$2/bin/rui" "$_rui_tmp/rui" && mv -f "$_rui_tmp/rui" "$_rui_link"; then
        rmdir "$_rui_tmp"
    else
        rm -rf "$_rui_tmp"
        return 1
    fi
    # set +eu: no probe can fail a published install, and no fact leaks out.
    ( set +eu; _rui_observe "$1" "$2" "$3"; _rui_render "$1" ) || :
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

# _rui_release_format LABEL -> S when LABEL is a release 0.S.N, else nothing.
_rui_release_format() {
    case $1 in 0.*.*) ;; *) return 0 ;; esac
    _rui_s=${1#0.}
    _rui_s=${_rui_s%%.*}
    case $_rui_s in ''|*[!0-9]*) return 0 ;; esac
    printf '%s' "$_rui_s"
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

# _rui_ready BIN -> success when `BIN host status` reports a ready Host.
_rui_ready() {
    case $("$1" host status </dev/null 2>/dev/null) in *'"status":"ready"'*) return 0 ;; esac
    return 1
}

# _rui_physical FILE -> FILE with its directory's symlinks and dots resolved.
_rui_physical() {
    ( CDPATH= cd -P "${1%/*}" >/dev/null 2>&1 && printf '%s/%s' "$(pwd -P)" "${1##*/}" )
}

# _rui_scan_path LINK -> sets _rui_path to ours (PATH finds LINK first),
# shadowed (another rui comes first) or missing (PATH never reaches LINK), and
# _rui_path_rui to the other rui PATH finds first. Walks PATH as the shell
# does, comparing physical paths, so a ./ or ../ step, a symlinked directory or
# a repeated entry is not a false shadow (cargo-dist #2529).
_rui_scan_path() {
    _rui_ours=$(_rui_physical "$1")
    _rui_path=missing
    _rui_path_rui=
    _rui_rest=$PATH:
    while [ -n "$_rui_rest" ]; do
        _rui_dir=${_rui_rest%%:*}
        _rui_rest=${_rui_rest#*:}
        _rui_c=${_rui_dir:-.}/rui
        [ -f "$_rui_c" ] && [ -x "$_rui_c" ] || continue
        if [ "$(_rui_physical "$_rui_c")" = "$_rui_ours" ]; then
            if [ -n "$_rui_path_rui" ]; then _rui_path=shadowed; else _rui_path=ours; fi
            return 0
        fi
        [ -n "$_rui_path_rui" ] || _rui_path_rui=$_rui_c
    done
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

# _rui_observe PREFIX BUILD FORMAT -> sets every fact _rui_render reads.
_rui_observe() {
    _rui_new=$(_rui_label "$2/bin/rui" "$2")
    _rui_format=$3
    if [ "$_rui_had" = 0 ]; then
        _rui_kind=first
    elif [ -n "$_rui_old" ] && [ "$_rui_old" = "$_rui_new" ]; then
        _rui_kind=reinstall
    else
        _rui_kind=update
    fi
    _rui_old_format=$(_rui_release_format "$_rui_old")
    _rui_scan_path "$1/bin/rui"
    _rui_sel=$(_rui_selected "$2/bin/rui")
    _rui_store=${_rui_sel%%"
"*}
    _rui_status=${_rui_sel#*"
"}
    _rui_saved=$(_rui_saved_format "$_rui_store" "$_rui_old_format")
    case $_rui_status in
        unavailable|store_unavailable) _rui_host=none ;;
        ready) _rui_host=ready ;;
        owned_unavailable) _rui_host=busy ;;
        incompatible)
            # The new build cannot reach the Host. If the replaced build can,
            # the Host is its own, and only it can stop the Host.
            if [ -n "$_rui_old_bin" ] && _rui_ready "$_rui_old_bin"; then _rui_host=old; else _rui_host=foreign; fi ;;
        *) _rui_host=unknown ;;
    esac
}

# _rui_render PREFIX -> the report. Reads only facts and runs nothing but printf.
_rui_render() {
    _rui_cmd=rui
    [ "$_rui_path" = ours ] || _rui_cmd=$(_rui_word "$1/bin/rui")
    _rui_bin=$(_rui_show "$1/bin")
    _rui_builds=$(_rui_show "$1/lib/rui")
    _rui_host_is="Rui's background Host (the process that runs your Sessions)"
    printf '\n'
    case $_rui_kind in
        first) printf 'Installed Rui %s at %s.\n' "$_rui_new" "$(_rui_show "$1/bin/rui")" ;;
        reinstall) printf 'Reinstalled Rui %s. Saved work and sign-in were kept.\n' "$_rui_new" ;;
        *)
            if [ -n "$_rui_old" ]; then
                printf 'Updated Rui from %s to %s. Saved work and sign-in were kept.\n' "$_rui_old" "$_rui_new"
            else
                printf 'Updated Rui to %s. Saved work and sign-in were kept.\n' "$_rui_new"
            fi ;;
    esac
    case $_rui_path in
        missing)
            if [ -n "$_rui_path_rui" ]; then
                printf '%s is not on your PATH, which finds another rui at %s. Add this line to your shell profile, then open a new terminal:\n' \
                    "$_rui_bin" "$(_rui_show "$_rui_path_rui")"
            else
                printf '%s is not on your PATH. Add this line to your shell profile, then open a new terminal:\n' "$_rui_bin"
            fi
            case $_rui_bin in
                '~/'*) printf '  export PATH="$HOME/%s:$PATH"\n' "${_rui_bin#'~/'}" ;;
                *) printf '  export PATH="%s:$PATH"\n' "$_rui_bin" ;;
            esac ;;
        shadowed)
            printf 'Your PATH finds another rui first, at %s. Put %s before it in your PATH, then run hash -r (Bash) or rehash (Zsh).\n' \
                "$(_rui_show "$_rui_path_rui")" "$_rui_bin" ;;
    esac
    case $_rui_saved in
        ''|unknown|"$_rui_format") ;;
        *)
            printf 'Rui %s cannot open your saved work in %s: that Store uses format %s, and this version uses format %s. Nothing was changed or deleted. Choose one:\n' \
                "$_rui_new" "$(_rui_show "$_rui_store")" "$_rui_saved" "$_rui_format"
            if [ -n "$_rui_old_bin" ] && [ "$_rui_old_format" = "$_rui_saved" ]; then
                printf '  Keep using it with your previous build, Rui %s: %s\n' "$_rui_old" "$(_rui_word "$_rui_old_bin")"
            else
                printf '  Keep using it with a Rui build that opens format %s. Earlier builds stay in %s.\n' "$_rui_saved" "$_rui_builds"
            fi
            printf '%s\n' '  Or start fresh: https://github.com/DivyanshGolyan/rui/blob/main/docs/store-reset.md' ;;
    esac
    case $_rui_host in
        ready)
            # A reinstall's Host runs this version, or the update before it said so.
            case $_rui_kind in
                first) printf '%s is already running another Rui build. When its work finishes, run: %s host stop\n' "$_rui_host_is" "$_rui_cmd" ;;
                update) printf '%s is still running an earlier build. When its work finishes, run: %s host stop\n' "$_rui_host_is" "$_rui_cmd" ;;
            esac ;;
        old)
            if [ -n "$_rui_old" ]; then _rui_running="Rui $_rui_old"; else _rui_running='your previous build'; fi
            printf '%s is still running %s, and this version cannot stop it. When its work finishes, run: %s host stop\n' \
                "$_rui_host_is" "$_rui_running" "$(_rui_word "$_rui_old_bin")" ;;
        foreign)
            printf '%s is still running an older build, and this version cannot stop it. Stop it with the build that started it. Earlier builds stay in %s.\n' \
                "$_rui_host_is" "$_rui_builds" ;;
        busy)
            printf '%s holds your saved work but did not answer. Before you start work, check it with: %s host status\n' "$_rui_host_is" "$_rui_cmd" ;;
        unknown)
            printf 'Could not check whether %s is running. The installation succeeded.\n' "$_rui_host_is" >&2 ;;
    esac
    if [ "$_rui_kind" = first ]; then
        printf 'Next: %s auth login codex (setup steps: https://github.com/DivyanshGolyan/rui#start-a-conversation)\n' "$_rui_cmd"
    fi
}
