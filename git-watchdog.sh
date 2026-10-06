#!/usr/bin/env bash
#
# git-watchdog - switch Git remotes to read-only mode while selected processes run.
#
# While a process matching one of the configured names is running, every remote of
# every repository found under the configured source directories is switched to
# read-only mode:
#   * its fetch URL is replaced with an HTTPS URL carrying a read-only token
#     (when a token is configured for the remote's host),
#   * pushing is disabled by pointing pushurl at an unusable URL.
# When the processes are gone, the original configuration is restored.
#
# The daemon is stateless: the original URLs are kept in each repository's own
# config under the [git-watchdog "<remote>"] section, so the current state can be
# derived from Git config at any time and reverted exactly.
#
# Works with bash 3.2+ (macOS) and GNU or BSD userlands.

VERSION="0.1.0"
set -o pipefail

# --------------------------------------------------------------------------- paths

REAL_HOME="${SNAP_REAL_HOME:-$HOME}"
if [ -n "${SNAP:-}" ]; then
    # A strictly confined snap cannot reach ~/.config without the
    # super-privileged personal-files interface; use its own data dir instead.
    CONFIG_DIR="${SNAP_USER_COMMON:-$REAL_HOME/snap/git-watchdog/common}"
elif [ -z "${XDG_CONFIG_HOME:-}" ]; then
    CONFIG_DIR="$REAL_HOME/.config/git-watchdog"
else
    CONFIG_DIR="$XDG_CONFIG_HOME/git-watchdog"
fi
CONFIG_FILE="${GIT_WATCHDOG_CONFIG:-$CONFIG_DIR/config.yaml}"
CONFIG_DIR="$(dirname "$CONFIG_FILE")"
RUN_DIR="${GIT_WATCHDOG_RUN_DIR:-/tmp}"
USER_ID="$(id -u)"
LOG_FILE="$RUN_DIR/git-watchdog-$USER_ID.log"
LOCK_DIR="$RUN_DIR/git-watchdog-$USER_ID.lock"
COMPLETION_DIR="$REAL_HOME/.local/share/bash-completion/completions"
BIN_DIR="$REAL_HOME/.local/bin"
LOG_MAX_BYTES=1048576

# Git config section holding the saved original remote configuration.
STATE_SECTION="git-watchdog"
# Push URL used while in read-only mode. Git fails with
# "unable to find remote helper for 'git-watchdog-read-only'", which names the culprit.
BLOCKED_PUSH_URL="git-watchdog-read-only://push-disabled-while-read-only-mode-is-active"

REQUIRED_TOOLS="git awk sed grep find od pgrep ps sort date sleep mkdir mktemp rm mv chmod ln id tr wc tail cat dirname basename nohup"

# ------------------------------------------------------------------------- globals

DRY_RUN=""
VERBOSE=""
ECHO_LOG=""          # also print log lines to stdout (interactive commands)
LOG_DISABLED=""

# Loaded configuration; see reset_config for the defaults.
CFG_LOADED=""
CFG_SOURCES=""       # newline separated, expanded paths
CFG_MATCHERS=""      # newline separated
CFG_REMOTES=""       # lines: host<TAB>token<TAB>username
CFG_EXCLUDES=""      # lines: host<TAB>pattern
CFG_CHECK_INTERVAL=""
CFG_RESCAN_INTERVAL=""
CFG_MAX_DEPTH=""

TAB="$(printf '\t')"
NL='
'

# ------------------------------------------------------------------------- helpers

have() { command -v "$1" >/dev/null 2>&1; }

die() { printf 'git-watchdog: %s\n' "$*" >&2; exit 1; }

# Resolve the absolute path of this script, following symlinks (no readlink -f on macOS).
resolve_self() {
    local path="$1" dir link
    case "$path" in */*) ;; *) path="$(command -v -- "$path" 2>/dev/null || printf '%s' "$path")" ;; esac
    while [ -L "$path" ]; do
        dir="$(cd -P "$(dirname "$path")" && pwd)"
        link="$(readlink "$path")"
        case "$link" in /*) path="$link" ;; *) path="$dir/$link" ;; esac
    done
    dir="$(cd -P "$(dirname "$path")" && pwd)"
    printf '%s/%s\n' "$dir" "$(basename "$path")"
}
SELF="$(resolve_self "$0")"

# Hide credentials embedded in URLs: scheme://user:secret@host -> scheme://user:***@host
redact() {
    printf '%s' "$1" | sed -E 's#(://[^/:@[:space:]]*):[^/@[:space:]]+@#\1:***@#g'
}

ensure_log_file() {
    [ -n "$LOG_DISABLED" ] && return 1
    if [ -L "$LOG_FILE" ] || { [ -e "$LOG_FILE" ] && [ ! -O "$LOG_FILE" ]; }; then
        LOG_DISABLED=1
        printf 'git-watchdog: refusing to use log file %s (symlink or not owned by you)\n' "$LOG_FILE" >&2
        return 1
    fi
    if [ ! -e "$LOG_FILE" ]; then
        (umask 077 && : >"$LOG_FILE") 2>/dev/null || { LOG_DISABLED=1; return 1; }
    fi
    chmod 600 "$LOG_FILE" 2>/dev/null
    return 0
}

rotate_log() {
    ensure_log_file || return 0
    local size
    size="$(wc -c <"$LOG_FILE" 2>/dev/null | tr -d ' ')"
    if [ -n "$size" ] && [ "$size" -gt "$LOG_MAX_BYTES" ]; then
        mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null
        ensure_log_file
    fi
}

# log LEVEL MESSAGE...
log() {
    local level="$1" line
    shift
    if [ "$level" = DEBUG ] && [ -z "$VERBOSE" ] && [ -z "$ECHO_LOG" ]; then
        return 0
    fi
    line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $(redact "$*")"
    if ensure_log_file; then
        printf '%s\n' "$line" >>"$LOG_FILE"
    fi
    if [ -n "$ECHO_LOG" ]; then
        printf '%s\n' "$line"
    fi
}

# Run a mutating git command (skipped in dry-run mode; see announce).
# Usage: git_write <repo> <description> <git args...>
git_write() {
    local repo="$1" what="$2" out
    shift 2
    [ -n "$DRY_RUN" ] && return 0
    if ! out="$(git -C "$repo" "$@" 2>&1)"; then
        log ERROR "$repo: failed to $what: $out"
        return 1
    fi
    return 0
}

# git config --unset-all returns 5 when the key does not exist; that is fine.
git_unset_all() {
    local repo="$1" key="$2" out rc
    [ -n "$DRY_RUN" ] && return 0
    out="$(git -C "$repo" config --local --unset-all "$key" 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 5 ]; then
        log ERROR "$repo: failed to unset $key: $out"
        return 1
    fi
    return 0
}

urlencode() {
    local LC_ALL=C s="$1" out="" c i
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9._~-]) out="$out$c" ;;
            *) printf -v c '%%%02X' "'$c"; out="$out$c" ;;
        esac
    done
    printf '%s' "$out"
}

expand_path() {
    local p="$1"
    # A literal "~" from the config is matched on purpose.
    # shellcheck disable=SC2088
    case "$p" in
        '~') p="$REAL_HOME" ;;
        '~/'*) p="$REAL_HOME/${p#\~/}" ;;
    esac
    p="${p//\$\{HOME\}/$REAL_HOME}"
    p="${p//\$HOME/$REAL_HOME}"
    printf '%s' "$p"
}

# -------------------------------------------------------------------- tool check

missing_tools() {
    local t missing=""
    for t in $REQUIRED_TOOLS; do
        have "$t" || missing="$missing $t"
    done
    printf '%s' "${missing# }"
}

require_tools() {
    local missing
    missing="$(missing_tools)"
    [ -z "$missing" ] && return 0
    die "missing required tools: $missing (run 'git watchdog check' for details)"
}

cmd_check() {
    local t status=0
    printf 'Required tools:\n'
    for t in $REQUIRED_TOOLS; do
        if have "$t"; then
            printf '  [ok]      %-10s %s\n' "$t" "$(command -v "$t")"
        else
            printf '  [MISSING] %s\n' "$t"
            status=1
        fi
    done
    if [ "$status" -eq 0 ]; then
        printf 'All required tools are installed.\n'
    else
        printf 'Some required tools are missing.\n'
    fi
    return "$status"
}

# ------------------------------------------------------------------------ config

# awk helpers shared by the config parser and the config writer.
AWK_YAML_FUNCS='
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function unq(s) {
        s = trim(s)
        if (s ~ /^".*"$/ || s ~ /^\047.*\047$/) s = substr(s, 2, length(s) - 2)
        return s
    }
    function strip_comment(s) { sub(/[ \t]+#.*$/, "", s); return s }
    function indent_of(s) { match(s, /^ */); return RLENGTH }
    # Split "key: value" / "key:" into K and V; returns 0 for anything else.
    function split_kv(s,   i) {
        K = s; V = ""
        if (s ~ /:$/) { K = substr(s, 1, length(s) - 1); return 1 }
        i = index(s, ": ")
        if (i == 0) return 0
        K = substr(s, 1, i - 1); V = trim(substr(s, i + 2))
        return 1
    }
    function key_of(line) { return split_kv(trim(strip_comment(line))) ? unq(K) : "" }
'

# Print the config as normalized, TAB separated records read from stdin:
#   source  <path>
#   matcher <name>
#   remote  <host> <token> <username>
#   exclude <host> <pattern>
#   option  <key> <value>
# Handles the documented (block style) config shape; no YAML tool is needed.
parse_config() {
    awk "$AWK_YAML_FUNCS"'
    function emit(kind, host, v) {
        v = unq(v)
        if (v == "") return
        if (kind == "source") print "source\t" v
        else if (kind == "matcher") print "matcher\t" v
        else if (kind == "exclude") print "exclude\t" host "\t" v
    }
    function emit_flow(kind, host, v,   n, i, parts) {
        v = trim(v)
        if (v !~ /^\[.*\]$/) { emit(kind, host, v); return }
        v = substr(v, 2, length(v) - 2)
        n = split(v, parts, ",")
        for (i = 1; i <= n; i++) emit(kind, host, parts[i])
    }
    function flush_host() {
        if (host != "") print "remote\t" host "\t" token "\t" user
        host = ""; token = ""; user = ""; sub_key = ""
    }
    function kind_of(section) {
        if (section == "source-directories") return "source"
        if (section == "process-name-matchers") return "matcher"
        return ""
    }
    BEGIN { section = ""; host = ""; host_indent = -1 }
    {
        line = $0
        sub(/\r$/, "", line)
        if (line ~ /^[ \t]*(#|$)/) next
        line = strip_comment(line)
        indent = indent_of(line)
        s = trim(substr(line, indent + 1))

        if (s ~ /^-( |$)/) {                               # list item
            item = substr(s, 2)
            if (section == "remote") { if (host != "" && sub_key == "exclude") emit("exclude", host, item) }
            else if (kind_of(section) != "") emit(kind_of(section), "", item)
            next
        }
        if (!split_kv(s)) next
        key = unq(K)

        if (indent == 0) {                                 # top-level key
            if (section == "remote") flush_host()
            section = key; host_indent = -1
            if (V != "" && kind_of(section) != "") emit_flow(kind_of(section), "", V)
            else if (V != "" && (key == "check-interval" || key == "rescan-interval" || key == "max-depth")) print "option\t" key "\t" unq(V)
            next
        }
        if (section != "remote") next
        if (host_indent < 0 || indent <= host_indent) {   # host entry
            flush_host()
            host_indent = indent; host = key
            next
        }
        sub_key = key                                      # host property
        if (key == "read-only-token") token = unq(V)
        else if (key == "username") user = unq(V)
        else if (key == "exclude" && V != "") emit_flow("exclude", host, V)
    }
    END { if (section == "remote") flush_host() }
    '
}

reset_config() {
    CFG_LOADED="" CFG_SOURCES="" CFG_MATCHERS="" CFG_REMOTES="" CFG_EXCLUDES=""
    CFG_CHECK_INTERVAL=5 CFG_RESCAN_INTERVAL=300 CFG_MAX_DEPTH=6
}

# Load the config into CFG_* variables. Returns 1 when there is no config file.
load_config() {
    local dump kind a b c
    reset_config
    if [ ! -r "$CONFIG_FILE" ]; then
        return 1
    fi
    if ! dump="$(parse_config <"$CONFIG_FILE")"; then
        log ERROR "failed to parse $CONFIG_FILE"
        return 1
    fi
    while IFS="$TAB" read -r kind a b c _; do
        case "$kind" in
            source) CFG_SOURCES="$CFG_SOURCES$(expand_path "$a")$NL" ;;
            matcher) CFG_MATCHERS="$CFG_MATCHERS$a$NL" ;;
            remote) CFG_REMOTES="$CFG_REMOTES$a$TAB$b$TAB$c$NL" ;;
            exclude) CFG_EXCLUDES="$CFG_EXCLUDES$a$TAB$b$NL" ;;
            option)
                case "$b" in *[!0-9]* | '') continue ;; esac
                case "$a" in
                    check-interval) CFG_CHECK_INTERVAL="$b" ;;
                    rescan-interval) CFG_RESCAN_INTERVAL="$b" ;;
                    max-depth) CFG_MAX_DEPTH="$b" ;;
                esac
                ;;
        esac
    done <<EOF
$dump
EOF
    [ "$CFG_CHECK_INTERVAL" -ge 1 ] 2>/dev/null || CFG_CHECK_INTERVAL=1
    CFG_LOADED=1
    return 0
}

default_config() {
    cat <<'EOF'
# git-watchdog configuration

# Base paths to look for Git repositories in.
source-directories:
  - $HOME

# Process names that enable read-only mode while running
# (exact process name match; extended regular expressions are allowed).
process-name-matchers:
  - claude
  - claude-desktop

# Optional tuning.
# check-interval: 5      # seconds between process checks
# rescan-interval: 300   # seconds between repository rescans
# max-depth: 6           # how deep to look for repositories in source-directories

# Hosts whose remotes are switched to read-only mode, keyed by host name
# (add ":port" for HTTP(S) remotes on a custom port). Add hosts with
# "git watchdog init <host>". When no host is listed, all remotes of all
# repositories are processed: pushing is disabled, fetch URLs stay unchanged.
#
# remote:
#   gitlab.com:
#     read-only-token: glpat-xxxxxxxxxxxxxxxxxxxx
#     username: oauth2          # optional, user name for the HTTPS URL
#     exclude:                  # optional, project paths (globs) to leave alone
#       - group/project
remote:
EOF
}

# Set or replace the read-only token of a host in the config file.
# The token is passed through the environment so it never appears in argv.
config_set_token() {
    local host="$1" tmp
    tmp="$(mktemp "$CONFIG_DIR/.config.yaml.XXXXXX")" || return 1
    config_set_token_awk "$host" <"$CONFIG_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" && mv -f "$tmp" "$CONFIG_FILE"
}

config_set_token_awk() {
    GWD_HOST="$1" awk "$AWK_YAML_FUNCS"'
    function token_line(ind,   t) {
        t = ENVIRON["GWD_TOKEN"]; gsub(/\\/, "\\\\", t); gsub(/"/, "\\\"", t)
        return sprintf("%" ind "s", "") "read-only-token: \"" t "\""
    }
    function host_block(ind) {
        print sprintf("%" ind "s", "") host ":"
        print token_line(ind + 2)
    }
    function close_remote() {
        if (in_remote && !done) { host_block(host_indent >= 0 ? host_indent : 2); done = 1 }
        in_remote = 0
    }
    BEGIN { host = ENVIRON["GWD_HOST"]; host_indent = -1 }
    {
        line = $0
        blank = (line ~ /^[ \t]*(#|$)/)
        ind = indent_of(line)

        if (pending && !blank) {                  # first line after the target host
            pending = 0
            if (ind > host_indent && line !~ /^ *- /) {
                if (key_of(line) == "read-only-token") { print token_line(ind); done = 1; next }
                print token_line(ind); done = 1
            } else {
                print token_line(host_indent + 2); done = 1; in_target = 0
            }
        }
        if (!blank && ind == 0 && line !~ /^-/) {  # top-level key
            if (in_remote) { close_remote(); in_target = 0 }
            if (key_of(line) == "remote") {
                seen_remote = 1; in_remote = 1
                if (line !~ /:[ \t]*(#.*)?$/) { print "remote:"; next }   # e.g. "remote: {}"
            }
            print; next
        }
        if (in_remote && !blank && line !~ /^ *- /) {
            if (host_indent < 0) host_indent = ind
            if (ind <= host_indent) {
                in_target = (key_of(line) == host)
                if (in_target) { print; pending = 1; next }
            } else if (in_target && done && key_of(line) == "read-only-token") {
                next                              # drop duplicate token lines
            }
        }
        print
    }
    END {
        if (pending) { print token_line(host_indent + 2); done = 1 }
        if (in_remote) close_remote()
        if (!seen_remote) { print "remote:"; host_block(2) }
    }
    '
}

# --------------------------------------------------------------- remote matching

# parse_url URL -> sets URL_SCHEME URL_HOST URL_PORT URL_PATH; returns 1 for local paths.
parse_url() {
    local url="$1" auth
    local re_std='^([A-Za-z][A-Za-z0-9+.-]*)://([^/]*)(/.*)?$'
    local re_scp='^([^@/:]+@)?([^/:]+):(.+)$'
    URL_SCHEME="" URL_HOST="" URL_PORT="" URL_PATH=""
    if [[ $url =~ $re_std ]]; then
        URL_SCHEME="${BASH_REMATCH[1]}"
        auth="${BASH_REMATCH[2]}"
        URL_PATH="${BASH_REMATCH[3]}"
        case "$URL_SCHEME" in file) return 1 ;; esac
        auth="${auth##*@}"
        case "$auth" in
            *:*) URL_HOST="${auth%%:*}" URL_PORT="${auth#*:}" ;;
            *) URL_HOST="$auth" ;;
        esac
    elif [[ $url =~ $re_scp ]]; then
        URL_SCHEME="ssh"
        URL_HOST="${BASH_REMATCH[2]}"
        URL_PATH="${BASH_REMATCH[3]}"
    else
        return 1
    fi
    URL_PATH="${URL_PATH#/}"
    [ -n "$URL_HOST" ] && [ -n "$URL_PATH" ]
}

# remote_config_for -> uses URL_*; sets RC_KEY RC_TOKEN RC_USER.
# Returns 1 when the host is not configured. With no hosts configured at all,
# every remote matches without a token.
remote_config_for() {
    local key token user
    RC_KEY="" RC_TOKEN="" RC_USER=""
    if [ -z "$CFG_REMOTES" ]; then
        RC_KEY="$URL_HOST"
        return 0
    fi
    while IFS="$TAB" read -r key token user; do
        [ -n "$key" ] || continue
        if [ "$key" = "$URL_HOST" ] || [ "$key" = "$URL_HOST:$URL_PORT" ]; then
            RC_KEY="$key" RC_TOKEN="$token" RC_USER="$user"
            return 0
        fi
    done <<EOF
$CFG_REMOTES
EOF
    return 1
}

# is_excluded -> uses RC_KEY and URL_PATH.
is_excluded() {
    local project="${URL_PATH%/}" host pattern
    project="${project%.git}"
    while IFS="$TAB" read -r host pattern; do
        [ "$host" = "$RC_KEY" ] || continue
        pattern="${pattern#/}"
        pattern="${pattern%/}"
        pattern="${pattern%.git}"
        [ -n "$pattern" ] || continue
        # Unquoted pattern on purpose: allow globs such as group/*.
        # shellcheck disable=SC2053
        if [[ $project == $pattern ]] || [[ $project == $pattern/* ]]; then
            return 0
        fi
    done <<EOF
$CFG_EXCLUDES
EOF
    return 1
}

# Build the read-only URL for the parsed remote (uses URL_* and RC_*).
read_only_url() {
    local scheme="https" authority
    [ "$URL_SCHEME" = "http" ] && scheme="http"
    authority="$URL_HOST"
    case "$URL_SCHEME" in http | https) [ -n "$URL_PORT" ] && authority="$URL_HOST:$URL_PORT" ;; esac
    case "$RC_KEY" in *:*) authority="$RC_KEY" ;; esac
    printf '%s://%s:%s@%s/%s' "$scheme" "$(urlencode "${RC_USER:-oauth2}")" "$(urlencode "$RC_TOKEN")" "$authority" "$URL_PATH"
}

# -------------------------------------------------------------- process matching

# Print "pid name" for every running process matching a configured name.
matching_processes() {
    local m
    [ -n "$CFG_MATCHERS" ] || return 0
    while IFS= read -r m; do
        [ -n "$m" ] || continue
        pgrep -l -x -- "$m" 2>/dev/null
    done <<EOF
$CFG_MATCHERS
EOF
}

matching_processes_sorted() {
    matching_processes | sort -n -u
}

# "pid name" lines -> "name (pid N), name (pid M)"
describe_processes() {
    printf '%s\n' "$1" | awk '{ printf "%s%s (pid %s)", (NR > 1 ? ", " : ""), $2, $1 }'
}

# ------------------------------------------------------------ repository handling

find_repositories() {
    local dir
    while IFS= read -r dir; do
        if [ -z "$dir" ] || [ ! -d "$dir" ]; then continue; fi
        find -H "$dir" -maxdepth "$CFG_MAX_DEPTH" \
            \( -name .git -print -prune \) -o \
            \( -type d \( -name node_modules -o \( -name '.*' ! -path "$dir" \) \) -prune \) 2>/dev/null
    done <<EOF
$CFG_SOURCES
EOF
}

repositories() {
    find_repositories | sed 's#/\.git$##' | sort -u
}

# ------------------------------------------------------------ repository config
# REPO_CFG holds the remote and git-watchdog entries of one repository
# ("key value" lines), read once per repository.

read_repo_config() {
    REPO_CFG="$(git -C "$1" config --local --get-regexp "^(remote|$STATE_SECTION)\\..*\\.(url|pushurl|key)\$" 2>/dev/null)" || REPO_CFG=""
}

# cfg_get VAR KEY - all values of KEY in REPO_CFG, newline separated, into VAR.
cfg_get() {
    local _line _out="" _want="$2"
    while IFS= read -r _line; do
        case "$_line" in
            "$_want "*) _out="$_out${_out:+$NL}${_line#"$_want "}" ;;
        esac
    done <<EOF
$REPO_CFG
EOF
    printf -v "$1" '%s' "$_out"
}

# Names of remotes (and of saved state sections) in REPO_CFG.
cfg_remote_names() {
    local k name
    while IFS= read -r k; do
        k="${k%% *}"
        case "$k" in
            remote.*.url) name="${k#remote.}"; printf '%s\n' "${name%.url}" ;;
            "$STATE_SECTION".*.url) name="${k#"$STATE_SECTION".}"; printf '%s\n' "${name%.url}" ;;
        esac
    done <<EOF
$REPO_CFG
EOF
}

# set_values REPO KEY VALUES - make KEY hold exactly VALUES (newline separated).
set_values() {
    local repo="$1" key="$2" v
    case "$3" in
        "") git_unset_all "$repo" "$key" ;;
        *"$NL"*)
            git_unset_all "$repo" "$key" || return 1
            while IFS= read -r v; do
                [ -n "$v" ] || continue
                git_write "$repo" "add $key" config --local --add "$key" "$v" || return 1
            done <<EOF
$3
EOF
            ;;
        *) git_write "$repo" "set $key" config --local --replace-all "$key" "$3" ;;
    esac
}

# ------------------------------------------------------------------ URL masking
# The original URLs saved in [git-watchdog "<remote>"] are masked so they cannot
# simply be read back from .git/config: each byte is XOR-ed with a random
# per-remote key (stored next to them) and hex encoded, prefixed with "gwd1:".
# This is obfuscation against casual discovery, not strong encryption.
# The helpers assign to the variable named by their first argument to avoid
# a subshell per value.

MASK_PREFIX="gwd1:"

new_key() {
    local key
    key="$(od -An -v -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    [ ${#key} -eq 32 ] || { log ERROR "cannot read /dev/urandom"; return 1; }
    printf '%s' "$key"
}

# xor_hex VAR KEY_HEX DATA_HEX
xor_hex() {
    local _out="" _byte _i=0 _k=0
    while [ "$_i" -lt ${#3} ]; do
        printf -v _byte '%02x' $((16#${3:_i:2} ^ 16#${2:_k:2}))
        _out="$_out$_byte"
        _i=$((_i + 2))
        _k=$(((_k + 2) % ${#2}))
    done
    printf -v "$1" '%s' "$_out"
}

# mask_value VAR KEY TEXT
mask_value() {
    local _hex
    xor_hex _hex "$2" "$(printf '%s' "$3" | od -An -v -tx1 | tr -d ' \n')"
    printf -v "$1" '%s%s' "$MASK_PREFIX" "$_hex"
}

# unmask_value VAR KEY VALUE (values without the prefix are returned as is)
unmask_value() {
    local _hex _esc="" _i=0
    case "$3" in
        "$MASK_PREFIX"*) ;;
        *) printf -v "$1" '%s' "$3"; return 0 ;;
    esac
    xor_hex _hex "$2" "${3#"$MASK_PREFIX"}"
    while [ "$_i" -lt ${#_hex} ]; do
        _esc="$_esc\\x${_hex:_i:2}"
        _i=$((_i + 2))
    done
    printf -v "$1" '%b' "$_esc"
}

# mask_values VAR KEY VALUES - mask every line of VALUES.
mask_values() {
    local _v _m _out=""
    while IFS= read -r _v; do
        [ -n "$_v" ] || continue
        mask_value _m "$2" "$_v"
        _out="$_out${_out:+$NL}$_m"
    done <<EOF
$3
EOF
    printf -v "$1" '%s' "$_out"
}

# saved_get VAR REMOTE url|pushurl - the unmasked original values from REPO_CFG.
saved_get() {
    local _key _vals _v _plain _out=""
    cfg_get _key "$STATE_SECTION.$2.key"
    cfg_get _vals "$STATE_SECTION.$2.$3"
    while IFS= read -r _v; do
        [ -n "$_v" ] || continue
        unmask_value _plain "$_key" "$_v"
        _out="$_out${_out:+$NL}$_plain"
    done <<EOF
$_vals
EOF
    printf -v "$1" '%s' "$_out"
}

# ----------------------------------------------------------------- reconciling

# announce REPO ACTION - log an action, or what would be done in dry-run mode.
announce() {
    if [ -n "$DRY_RUN" ]; then
        log DRY-RUN "$1: would $2"
    else
        log INFO "$1: $2"
    fi
}

# mask_remote REPO NAME URLS PUSHURLS RO_URL
mask_remote() {
    local repo="$1" name="$2" urls="$3" pushes="$4" ro_url="$5" key saved_urls saved_pushes
    cfg_get key "$STATE_SECTION.$name.key"
    [ -n "$key" ] || key="$(new_key)" || return 1
    mask_values saved_urls "$key" "$urls"
    mask_values saved_pushes "$key" "$pushes"
    announce "$repo" "switch remote '$name' to read-only mode${ro_url:+ ($ro_url)}"
    # The saved url marks the remote as read-only, so it is written after the
    # key and the saved pushurl: an interrupted run is simply retried.
    set_values "$repo" "$STATE_SECTION.$name.key" "$key" &&
        set_values "$repo" "$STATE_SECTION.$name.pushurl" "$saved_pushes" &&
        set_values "$repo" "$STATE_SECTION.$name.url" "$saved_urls" &&
        set_values "$repo" "remote.$name.url" "${ro_url:-$urls}" &&
        set_values "$repo" "remote.$name.pushurl" "$BLOCKED_PUSH_URL"
}

# revert_remote REPO NAME
revert_remote() {
    local repo="$1" name="$2" urls pushes
    saved_get urls "$name" url
    saved_get pushes "$name" pushurl
    if [ -z "$urls" ]; then
        log WARN "$repo: saved state of remote '$name' has no URL; leaving it untouched"
        return 1
    fi
    announce "$repo" "restore remote '$name'"
    set_values "$repo" "remote.$name.url" "$urls" &&
        set_values "$repo" "remote.$name.pushurl" "$pushes" &&
        git_write "$repo" "remove saved state of remote '$name'" config --local --remove-section "$STATE_SECTION.$name"
}

# A remote renamed while in read-only mode ("git remote rename") keeps pushing
# disabled but its saved state stays behind under the old name. Move the state
# to the new name when that is unambiguous. Sets ADOPTED to the old name.
adopt_renamed_remote() {
    local repo="$1" names="$2" name saved urls pushes orphans="" renamed=""
    ADOPTED=""
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        cfg_get saved "$STATE_SECTION.$name.url"
        cfg_get urls "remote.$name.url"
        cfg_get pushes "remote.$name.pushurl"
        if [ -n "$saved" ] && [ -z "$urls" ]; then
            orphans="$orphans${orphans:+$NL}$name"
        elif [ -z "$saved" ] && [ "$pushes" = "$BLOCKED_PUSH_URL" ]; then
            renamed="$renamed${renamed:+$NL}$name"
        fi
    done <<EOF
$names
EOF
    [ -n "$renamed" ] || return 0
    case "$orphans$renamed" in
        *"$NL"*) ;;
        *)
            if [ -n "$orphans" ]; then
                announce "$repo" "move saved state of remote '$orphans' to its new name '$renamed'"
                git_write "$repo" "move saved state of remote '$orphans' to '$renamed'" \
                    config --local --rename-section "$STATE_SECTION.$orphans" "$STATE_SECTION.$renamed" &&
                    ADOPTED="$orphans"
                return
            fi
            ;;
    esac
    log WARN "$repo: remote(s) $(printf '%s' "$renamed" | tr '\n' ' ')have pushing disabled by git-watchdog but no saved original URL; leaving them untouched"
}

# reconcile_remote REPO NAME ACTIVE(1|"") - bring one remote to the wanted state.
reconcile_remote() {
    local repo="$1" name="$2" active="$3" masked="" urls pushes original="" ro_url="" wanted=""
    # A saved original url means the remote is in read-only mode.
    cfg_get original "$STATE_SECTION.$name.url"
    [ -n "$original" ] && masked=1
    cfg_get urls "remote.$name.url"
    cfg_get pushes "remote.$name.pushurl"
    if [ -n "$masked" ]; then
        saved_get original "$name" url
    else
        original="$urls"
    fi

    if [ -n "$active" ] && [ -n "$original" ] && parse_url "${original%%"$NL"*}" && remote_config_for && ! is_excluded; then
        wanted="$original"
        if [ -n "$RC_TOKEN" ]; then
            ro_url="$(read_only_url)"
            wanted="$ro_url"
        fi
    fi

    if [ -n "$masked" ]; then
        if [ -z "$urls" ]; then
            announce "$repo" "drop saved state of removed remote '$name'"
            git_write "$repo" "drop saved state of remote '$name'" config --local --remove-section "$STATE_SECTION.$name"
        elif [ -z "$wanted" ]; then
            revert_remote "$repo" "$name"
        elif [ "$urls" != "$wanted" ] || [ "$pushes" != "$BLOCKED_PUSH_URL" ]; then
            # Already read-only, but the token or the config changed.
            announce "$repo" "refresh read-only settings of remote '$name'${ro_url:+ ($ro_url)}"
            set_values "$repo" "remote.$name.url" "$wanted" &&
                set_values "$repo" "remote.$name.pushurl" "$BLOCKED_PUSH_URL"
        fi
    elif [ "$pushes" = "$BLOCKED_PUSH_URL" ]; then
        return 0 # renamed while read-only, without a unique saved state (warned)
    elif [ -n "$wanted" ]; then
        mask_remote "$repo" "$name" "$urls" "$pushes" "$ro_url"
    fi
}

# reconcile_repository REPO ACTIVE(1|"")
reconcile_repository() {
    local repo="$1" active="$2" names name
    read_repo_config "$repo"
    [ -n "$REPO_CFG" ] || return 0
    names="$(cfg_remote_names | sort -u)"

    adopt_renamed_remote "$repo" "$names"
    if [ -n "$ADOPTED" ] && [ -z "$DRY_RUN" ]; then
        read_repo_config "$repo"
        names="$(cfg_remote_names | sort -u)"
    fi

    while IFS= read -r name; do
        [ -n "$name" ] || continue
        [ "$name" = "$ADOPTED" ] && continue # dry-run: the state was not moved
        reconcile_remote "$repo" "$name" "$active"
    done <<EOF
$names
EOF
}

# reconcile ACTIVE(1|"") - bring every repository to the wanted state.
reconcile() {
    local active="$1" repo count=0
    while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        reconcile_repository "$repo" "$active"
        count=$((count + 1))
    done <<EOF
$(repositories)
EOF
    log DEBUG "checked $count repositories (read-only mode: ${active:+active}${active:-inactive})"
}

# List remotes currently in read-only mode: "repo<TAB>remote".
list_masked() {
    local repo name
    while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        git -C "$repo" config --local --get-regexp "^$STATE_SECTION\\..*\\.url\$" 2>/dev/null |
            while IFS=' ' read -r name _; do
                name="${name#"$STATE_SECTION".}"
                printf '%s\t%s\n' "$repo" "${name%.url}"
            done
    done <<EOF
$(repositories)
EOF
}

# ------------------------------------------------------------------------ daemon

daemon_pid() {
    local pid
    [ -d "$LOCK_DIR" ] && [ -O "$LOCK_DIR" ] || return 1
    pid="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
    case "$pid" in '' | *[!0-9]*) return 1 ;; esac
    kill -0 "$pid" 2>/dev/null || return 1
    ps -p "$pid" -o command= 2>/dev/null | grep -q 'git-watchdog' || return 1
    printf '%s\n' "$pid"
}

acquire_lock() {
    for _ in 1 2; do
        if (umask 077 && mkdir "$LOCK_DIR") 2>/dev/null; then
            printf '%s\n' "$$" >"$LOCK_DIR/pid"
            return 0
        fi
        if daemon_pid >/dev/null; then
            return 1
        fi
        [ -O "$LOCK_DIR" ] || die "lock directory $LOCK_DIR is not owned by you"
        rm -rf "$LOCK_DIR" # stale lock
    done
    return 1
}

release_lock() {
    if [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
        rm -rf "$LOCK_DIR"
    fi
}

cmd_daemon() {
    local procs active last_state="unset" last_scan=0 now sleeper
    if ! acquire_lock; then
        printf 'git-watchdog: daemon already running (pid %s)\n' "$(daemon_pid)"
        return 0
    fi
    trap 'kill "$sleeper" 2>/dev/null; release_lock; log INFO "daemon stopped (pid $$)"; exit 0' TERM INT HUP
    trap 'release_lock' EXIT
    rotate_log
    log INFO "daemon started (pid $$, version $VERSION${DRY_RUN:+, dry-run})"
    load_config || log WARN "no config at $CONFIG_FILE; run 'git watchdog init'"

    while :; do
        procs="$(matching_processes_sorted)"
        active=""
        [ -n "$procs" ] && active=1
        now="$(date +%s)"
        if [ "$active" != "$last_state" ]; then
            if [ -n "$active" ]; then
                log INFO "read-only mode ACTIVE, triggered by: $(describe_processes "$procs")"
            elif [ "$last_state" != "unset" ]; then
                log INFO "read-only mode INACTIVE, no matching processes running"
            fi
        fi
        if [ "$active" != "$last_state" ] || [ $((now - last_scan)) -ge "$CFG_RESCAN_INTERVAL" ]; then
            rotate_log
            load_config >/dev/null 2>&1
            reconcile "$active"
            last_scan="$now"
            last_state="$active"
        fi
        sleep "$CFG_CHECK_INTERVAL" &
        sleeper=$!
        wait "$sleeper"
    done
}

start_daemon() {
    local pid i
    if pid="$(daemon_pid)"; then
        printf '%s\n' "$pid"
        return 0
    fi
    nohup "$SELF" ${DRY_RUN:+--dry-run} daemon </dev/null >/dev/null 2>&1 &
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if pid="$(daemon_pid)"; then
            printf '%s\n' "$pid"
            return 0
        fi
        sleep 0.2
    done
    return 1
}

cmd_start() {
    local pid
    if pid="$(daemon_pid)"; then
        printf 'git-watchdog daemon already running (pid %s)\n' "$pid"
        return 0
    fi
    pid="$(start_daemon)" || die "failed to start the daemon, see $LOG_FILE"
    printf 'git-watchdog daemon started (pid %s)\n' "$pid"
}

cmd_stop() {
    local pid i
    if ! pid="$(daemon_pid)"; then
        printf 'git-watchdog daemon is not running\n'
        return 0
    fi
    if [ -n "$DRY_RUN" ]; then
        printf '[dry-run] would stop the daemon (pid %s)\n' "$pid"
        return 0
    fi
    kill "$pid"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    printf 'git-watchdog daemon stopped (pid %s)\n' "$pid"
}

# ------------------------------------------------------------------------ commands

cmd_status() {
    local pid procs repo name count=0
    load_config
    if [ -z "$CFG_LOADED" ]; then
        printf 'git-watchdog is not configured yet: %s not found.\n' "$CONFIG_FILE"
        printf "Run 'git watchdog init' to create it.\n"
        return 1
    fi
    if [ -z "$DRY_RUN" ]; then
        pid="$(start_daemon)" || pid=""
    else
        pid="$(daemon_pid)" || pid=""
    fi
    procs="$(matching_processes_sorted)"

    if [ -n "$procs" ]; then
        printf 'Read-only mode: ACTIVE\n'
        printf '%s\n' "$procs" | while IFS=' ' read -r p n; do
            printf '  triggered by: %s (pid %s)\n' "$n" "$p"
        done
    else
        printf 'Read-only mode: inactive (no matching processes running)\n'
    fi
    if [ -n "$pid" ]; then
        printf 'Daemon:         running (pid %s)\n' "$pid"
    elif [ -n "$DRY_RUN" ]; then
        printf 'Daemon:         not running (not started in dry-run mode)\n'
    else
        printf 'Daemon:         FAILED to start, see %s\n' "$LOG_FILE"
    fi
    printf 'Config:         %s\n' "$CONFIG_FILE"
    printf 'Log:            %s\n' "$LOG_FILE"

    if [ -n "$VERBOSE" ]; then
        printf 'Remotes in read-only mode:\n'
        while IFS="$TAB" read -r repo name; do
            [ -n "$repo" ] || continue
            printf '  %s (%s)\n' "$repo" "$name"
            count=$((count + 1))
        done <<EOF
$(list_masked)
EOF
        [ "$count" -gt 0 ] || printf '  none\n'
    fi
}

cmd_sync() {
    local procs active=""
    ECHO_LOG=1
    load_config || die "no config at $CONFIG_FILE; run 'git watchdog init' first"
    procs="$(matching_processes_sorted)"
    if [ -n "$procs" ]; then
        active=1
        log INFO "read-only mode ACTIVE, triggered by: $(describe_processes "$procs")"
    else
        log INFO "read-only mode inactive, no matching processes running"
    fi
    reconcile "$active"
}

cmd_revert() {
    local pid
    ECHO_LOG=1
    load_config || die "no config at $CONFIG_FILE; run 'git watchdog init' first"
    if pid="$(daemon_pid)" && [ -n "$(matching_processes)" ]; then
        printf 'Warning: the daemon (pid %s) will re-apply read-only mode while matching processes run.\n' "$pid" >&2
        printf "         Run 'git watchdog stop' first to keep the original remotes.\n" >&2
    fi
    reconcile ""
}

completion_script() {
    cat <<'EOF'
# bash completion for git-watchdog                              -*- shell-script -*-
# Installed by "git watchdog init". bash-completion loads it on demand, both for
# "git-watchdog ..." and, through Git's completion, for "git watchdog ...".

__git_watchdog_words() {
    local prev="$1"
    case "$prev" in
        init)
            if command -v git-watchdog >/dev/null 2>&1; then git-watchdog __hosts 2>/dev/null
            else git watchdog __hosts 2>/dev/null; fi ;;
        status) echo "--verbose --dry-run" ;;
        uninstall) echo "--remove-config --dry-run" ;;
        logs) echo "-f" ;;
        *) echo "status start stop restart daemon sync revert init uninstall check logs completion help version --dry-run --verbose --help --version" ;;
    esac
}

# Called by git's own completion for "git watchdog ...".
_git_watchdog() {
    local cur="${COMP_WORDS[COMP_CWORD]}" prev="${COMP_WORDS[COMP_CWORD-1]}"
    if declare -F __gitcomp >/dev/null 2>&1; then
        __gitcomp "$(__git_watchdog_words "$prev")"
    else
        # shellcheck disable=SC2207 # mapfile is not available in bash 3.2
        COMPREPLY=($(compgen -W "$(__git_watchdog_words "$prev")" -- "$cur"))
    fi
}

_git_watchdog_cmd() {
    local cur="${COMP_WORDS[COMP_CWORD]}" prev="${COMP_WORDS[COMP_CWORD-1]}"
    # shellcheck disable=SC2207 # mapfile is not available in bash 3.2
    COMPREPLY=($(compgen -W "$(__git_watchdog_words "$prev")" -- "$cur"))
}

complete -F _git_watchdog_cmd git-watchdog git-watchdog.sh
EOF
}

# Hosts for completion: configured hosts plus hosts of the current repository's remotes.
cmd_hosts() {
    local key _t _u url
    load_config >/dev/null 2>&1
    {
        printf '%s\n' "$CFG_REMOTES" | while IFS="$TAB" read -r key _t _u; do
            [ -n "$key" ] && printf '%s\n' "$key"
        done
        git config --get-regexp '^remote\..*\.url$' 2>/dev/null | while IFS=' ' read -r _ url; do
            parse_url "$url" && printf '%s\n' "$URL_HOST"
        done
    } | sort -u
}

# Show a path under the home directory as ~/...
tilde() {
    case "$1" in
        "$REAL_HOME"/*) printf '%s/%s' "~" "${1#"$REAL_HOME"/}" ;;
        *) printf '%s' "$1" ;;
    esac
}

install_file() { # install_file <content> <path> <mode>
    local content="$1" path="$2" mode="$3" tmp
    tmp="$(mktemp "$(dirname "$path")/.gwd.XXXXXX")" || return 1
    printf '%s\n' "$content" >"$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$path"
}

cmd_init() {
    local host="$1" token="" existing on_path completion_file="$COMPLETION_DIR/git-watchdog"

    # main() already stopped if a required tool is missing.
    printf 'Tools:       all required tools are installed\n'

    # 1. Config file (owner-only; it holds tokens).
    if [ -f "$CONFIG_FILE" ]; then
        printf 'Config:      %s (exists)\n' "$CONFIG_FILE"
    else
        if [ -n "$DRY_RUN" ]; then
            printf '[dry-run] would create %s\n' "$CONFIG_FILE"
        else
            printf 'Config:      %s (created)\n' "$CONFIG_FILE"
            (umask 077 && mkdir -p "$CONFIG_DIR") || die "cannot create $CONFIG_DIR"
            install_file "$(default_config)" "$CONFIG_FILE" 600 || die "cannot write $CONFIG_FILE"
        fi
    fi
    [ -z "$DRY_RUN" ] && chmod 700 "$CONFIG_DIR" 2>/dev/null && chmod 600 "$CONFIG_FILE" 2>/dev/null

    # 2. Remote host with its read-only token.
    if [ -n "$host" ]; then
        case "$host" in *[[:space:]/]* | *:*:* | '') die "invalid host '$host' (expected e.g. gitlab.com or git.example.com:8443)" ;; esac
        if [ -n "${GIT_WATCHDOG_TOKEN+x}" ]; then
            token="$GIT_WATCHDOG_TOKEN"
        elif [ -t 0 ]; then
            printf 'Read-only token for %s (input hidden, empty = only disable pushing): ' "$host" >&2
            IFS= read -rs token
            printf '\n' >&2
        else
            IFS= read -r token
        fi
        if [ -n "$DRY_RUN" ]; then
            printf '[dry-run] would set the read-only token of %s in %s\n' "$host" "$CONFIG_FILE"
        else
            GWD_TOKEN="$token" config_set_token "$host" || die "failed to update $CONFIG_FILE"
            printf 'Remote:      %s %s\n' "$host" "$([ -n "$token" ] && echo '(read-only token saved)' || echo '(no token; pushing will be disabled only)')"
        fi
    fi

    # 3. Bash completion. The snap ships "git-watchdog <TAB>" through snapd's
    #    completer. "git watchdog <TAB>" needs the file in the bash-completion
    #    dir, which the snap may not write: it keeps a copy in its own data dir
    #    (removed with the snap) and asks the user to link it.
    if [ -n "${SNAP:-}" ]; then
        completion_file="${SNAP_USER_COMMON:-$REAL_HOME/snap/git-watchdog/common}/git-watchdog.bash"
        if [ -n "$DRY_RUN" ]; then
            printf '[dry-run] would write bash completion to %s\n' "$completion_file"
        elif mkdir -p "$(dirname "$completion_file")" && install_file "$(completion_script)" "$completion_file" 644; then
            printf 'Completion:  "git-watchdog <TAB>" is provided by the snap. For "git watchdog <TAB>" run:\n'
            printf '  mkdir -p %s && ln -sf %s %s/git-watchdog\n' \
                "$(tilde "$COMPLETION_DIR")" "$(tilde "$completion_file")" "$(tilde "$COMPLETION_DIR")"
        else
            printf 'Warning: could not write bash completion to %s\n' "$completion_file" >&2
        fi
    elif [ -n "$DRY_RUN" ]; then
        printf '[dry-run] would install bash completion to %s/git-watchdog\n' "$COMPLETION_DIR"
    elif mkdir -p "$COMPLETION_DIR" && install_file "$(completion_script)" "$COMPLETION_DIR/git-watchdog" 644; then
        printf 'Completion:  %s/git-watchdog\n' "$COMPLETION_DIR"
    else
        printf 'Warning: could not install bash completion to %s\n' "$COMPLETION_DIR" >&2
    fi

    # 4. Git extension ("git watchdog" needs git-watchdog on PATH).
    existing="$(command -v git-watchdog 2>/dev/null)"
    [ -z "$existing" ] && [ -n "${SNAP:-}" ] && existing="/snap/bin/git-watchdog"
    if [ -n "$existing" ]; then
        printf 'Git command: git watchdog -> %s\n' "$existing"
    elif [ -n "$DRY_RUN" ]; then
        printf '[dry-run] would link %s/git-watchdog -> %s\n' "$BIN_DIR" "$SELF"
    elif mkdir -p "$BIN_DIR" && ln -sf "$SELF" "$BIN_DIR/git-watchdog"; then
        printf 'Git command: %s/git-watchdog -> %s\n' "$BIN_DIR" "$SELF"
        on_path=""
        case ":$PATH:" in *":$BIN_DIR:"*) on_path=1 ;; esac
        [ -n "$on_path" ] || printf 'Note: add %s to PATH so that "git watchdog" works.\n' "$BIN_DIR"
    else
        printf 'Warning: could not link %s/git-watchdog\n' "$BIN_DIR" >&2
    fi

    # 5. Snap: start the daemon at desktop login.
    if [ -n "${SNAP:-}" ]; then
        local autostart
        autostart="$(snap_autostart_file)"
        if [ -n "$DRY_RUN" ]; then
            printf '[dry-run] would write %s\n' "$autostart"
        elif mkdir -p "$(dirname "$autostart")" && install_file "$(snap_autostart_entry)" "$autostart" 644; then
            printf 'Autostart:   the daemon starts at login (%s)\n' "$autostart"
        else
            printf 'Warning: could not write %s; the daemon starts on "git watchdog" only\n' "$autostart" >&2
        fi
    fi

    printf '\nNext: review %s, then run "git watchdog" to start the daemon.\n' "$CONFIG_FILE"
}

# The snap starts its daemon at desktop login from this file (see snapcraft.yaml).
snap_autostart_file() {
    printf '%s/.config/autostart/git-watchdog-daemon.desktop' "${SNAP_USER_DATA:-$REAL_HOME/snap/git-watchdog/current}"
}

snap_autostart_entry() {
    cat <<'EOF'
[Desktop Entry]
Type=Application
Name=git-watchdog
Comment=Read-only Git remotes while selected processes run
Exec=git-watchdog.daemon
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
}

# Undo everything init and the daemon did: stop the daemon, restore all remotes,
# remove the git command link, the completion, the log and the lock. The config (with its tokens) is kept unless --remove-config.
cmd_uninstall() {
    local remove_config="" pid link file
    case "$1" in
        --remove-config) remove_config=1 ;;
        "") ;;
        *) die "unknown option for uninstall: $1 (expected --remove-config)" ;;
    esac
    ECHO_LOG=1

    # 1. Daemon (a service manager may restart it, e.g. a systemd unit).
    if pid="$(daemon_pid)"; then
        cmd_stop
        if [ -z "$DRY_RUN" ]; then
            sleep 1
            if daemon_pid >/dev/null; then
                die "the daemon was started again (pid $(daemon_pid)), probably by a service manager; disable that and run uninstall again"
            fi
        fi
    fi

    # 2. Remotes.
    if load_config; then
        reconcile ""
    else
        printf 'No config at %s; no repositories to restore.\n' "$CONFIG_FILE"
    fi

    # 3. Files created by init and the daemon.
    link="$BIN_DIR/git-watchdog"
    for file in "$link" "$COMPLETION_DIR/git-watchdog" \
        "${SNAP_USER_COMMON:-$REAL_HOME/snap/git-watchdog/common}/git-watchdog.bash" \
        "$(snap_autostart_file)" \
        "$LOG_FILE" "$LOG_FILE.1"; do
        [ -e "$file" ] || [ -L "$file" ] || continue
        # Only remove a git-watchdog link, never another tool of the same name.
        if [ "$file" = "$link" ] && { [ ! -L "$link" ] || ! readlink "$link" | grep -q 'git-watchdog'; }; then
            printf 'Keeping %s (not a link to git-watchdog)\n' "$link"
            continue
        fi
        if [ -n "$DRY_RUN" ]; then
            printf '[dry-run] would remove %s\n' "$file"
        else
            rm -f "$file" && printf 'Removed %s\n' "$file"
        fi
    done
    if [ -d "$LOCK_DIR" ] && [ -O "$LOCK_DIR" ] && ! daemon_pid >/dev/null; then
        if [ -n "$DRY_RUN" ]; then printf '[dry-run] would remove %s\n' "$LOCK_DIR"; else rm -rf "$LOCK_DIR"; fi
    fi

    # 4. The snap may not touch ~/.local; the user created the completion link.
    if [ -n "${SNAP:-}" ] && [ -L "$COMPLETION_DIR/git-watchdog" ]; then
        printf 'Remove the completion link yourself: rm %s/git-watchdog\n' "$COMPLETION_DIR"
    fi

    # 5. Config, only on request.
    if [ -z "$remove_config" ]; then
        [ -f "$CONFIG_FILE" ] && printf 'Kept %s (use --remove-config to remove it)\n' "$CONFIG_FILE"
    elif [ -f "$CONFIG_FILE" ]; then
        if [ -n "$DRY_RUN" ]; then
            printf '[dry-run] would remove %s\n' "$CONFIG_FILE"
        else
            rm -f "$CONFIG_FILE" && printf 'Removed %s\n' "$CONFIG_FILE"
            rmdir "$CONFIG_DIR" 2>/dev/null
        fi
    fi

    if [ -n "${SNAP:-}" ]; then
        printf 'To remove the snap itself: sudo snap remove git-watchdog\n'
    fi
}

cmd_logs() {
    [ -f "$LOG_FILE" ] || die "no log file at $LOG_FILE yet"
    if [ "$1" = "-f" ]; then
        tail -n 50 -f "$LOG_FILE"
    else
        tail -n 50 "$LOG_FILE"
    fi
}

usage() {
    cat <<EOF
git-watchdog $VERSION - read-only Git remotes while selected processes run

Usage: git watchdog [--dry-run] [command] [args]

Commands:
  status [-v]     Start the daemon if needed and show whether read-only mode is
                  active and which processes caused it (default command).
                  -v also lists the remotes currently in read-only mode.
  init [host]     Create the config, install bash completion and the git command.
                  With a host (e.g. gitlab.com), ask for its read-only token and
                  save it (or read it from \$GIT_WATCHDOG_TOKEN / stdin).
  start | stop | restart
                  Control the background daemon.
  daemon          Run the daemon in the foreground (for service managers).
  sync            Apply the wanted state once and exit.
  revert          Restore the original remotes of all repositories now.
  check           Show which required tools are installed (every other
                  command checks this itself and stops if one is missing).
  uninstall [--remove-config]
                  Stop the daemon, restore all remotes and remove what init
                  installed. The config is kept unless --remove-config is given.
  logs [-f]       Show (or follow) the log file.
  completion      Print the bash completion script.
  help | version

Options:
  --dry-run       Only report what would change; nothing is modified.
                  Without a command, runs "sync" in dry-run mode.
  -v, --verbose   More detail (status).

Files:
  config  $CONFIG_FILE
  log     $LOG_FILE
EOF
}

main() {
    local cmd="" args="" a
    local -a rest
    rest=()
    for a in "$@"; do
        case "$a" in
            --dry-run | -n) DRY_RUN=1 ;;
            -v | --verbose) VERBOSE=1 ;;
            -h | --help) cmd="help" ;;
            -V | --version) cmd="version" ;;
            *) rest[${#rest[@]}]="$a" ;;
        esac
    done
    if [ -z "$cmd" ]; then
        cmd="${rest[0]:-}"
        [ ${#rest[@]} -gt 0 ] && rest=("${rest[@]:1}")
    fi
    if [ -z "$cmd" ]; then
        if [ -n "$DRY_RUN" ]; then cmd="sync"; else cmd="status"; fi
    fi
    args="${rest[0]:-}"

    case "$cmd" in
        help) usage; return 0 ;;
        version) printf 'git-watchdog %s\n' "$VERSION"; return 0 ;;
        check) cmd_check; return $? ;;
        completion) completion_script; return 0 ;;
    esac
    require_tools
    reset_config
    case "$cmd" in
        status) cmd_status ;;
        start) cmd_start ;;
        stop) cmd_stop ;;
        restart) cmd_stop && cmd_start ;;
        daemon | run) cmd_daemon ;;
        sync) cmd_sync ;;
        revert) cmd_revert ;;
        init) cmd_init "$args" ;;
        uninstall) cmd_uninstall "$args" ;;
        logs | log) cmd_logs "$args" ;;
        __hosts) cmd_hosts ;;
        __default-config) default_config ;;
        *) printf 'git-watchdog: unknown command %s\n\n' "$cmd" >&2; usage >&2; return 2 ;;
    esac
}

main "$@"
