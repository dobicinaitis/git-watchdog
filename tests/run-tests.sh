#!/usr/bin/env bash
# Self-contained tests for git-watchdog. Everything happens inside a temporary
# directory (fake HOME, throwaway repositories, private log/lock dir); no real
# repository or user config is touched and nothing talks to the network.
#
# Usage: tests/run-tests.sh

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/git-watchdog.sh"
PASS=0
FAIL=0
TOKEN="glpat-SECRET-test-token-123"
FAKE_PROC="gwd-fake-agent"

ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
check() { # check <description> <command...>
    local d="$1"; shift
    if "$@"; then ok "$d"; else fail "$d"; fi
}
eq() { # eq <description> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected [$2] got [$3]"; fi
}

setup() {
    T="$(mktemp -d "${TMPDIR:-/tmp}/gwd-test.XXXXXX")"
    export HOME="$T/home"
    export GIT_WATCHDOG_RUN_DIR="$T/run"
    export GIT_CONFIG_NOSYSTEM=1
    unset XDG_CONFIG_HOME GIT_WATCHDOG_CONFIG GIT_WATCHDOG_TOKEN SNAP SNAP_REAL_HOME
    mkdir -p "$HOME/src" "$GIT_WATCHDOG_RUN_DIR" "$T/bin"
    # Hide any installed git-watchdog (e.g. the snap) so init behaves as on a clean machine.
    local dir clean_path=""
    local IFS=:
    for dir in $PATH; do
        [ -e "$dir/git-watchdog" ] || clean_path="$clean_path${clean_path:+:}$dir"
    done
    unset IFS
    export PATH="$T/bin:$clean_path"
    # The fake agent is a copy of sleep, so its process name is FAKE_PROC.
    # Multi-call binaries (e.g. uutils coreutils) refuse to run under another
    # name; a script works there instead, since Linux names it after the file.
    cp "$(command -v sleep)" "$T/bin/$FAKE_PROC"
    if ! "$T/bin/$FAKE_PROC" 0 2>/dev/null; then
        printf '#!/bin/sh\nwhile :; do sleep 1; done\n' >"$T/bin/$FAKE_PROC"
    fi
    chmod +x "$T/bin/$FAKE_PROC"
    CFG="$HOME/.config/git-watchdog/config.yaml"
    LOG="$GIT_WATCHDOG_RUN_DIR/git-watchdog-$(id -u).log"

    mkrepo "$HOME/src/app" origin git@gitlab.com:group/app.git
    git -C "$HOME/src/app" remote add github https://github.com/someone/app.git
    mkrepo "$HOME/src/nested/deeper/lib" origin ssh://git@gitlab.com/group/sub/lib.git
    git -C "$HOME/src/nested/deeper/lib" config --add remote.origin.pushurl git@gitlab.com:group/sub/lib.git
    mkrepo "$HOME/src/excluded" origin git@gitlab.com:group/project.git
    mkrepo "$HOME/src/other" origin https://git.example.com:8443/team/tool.git
    mkrepo "$HOME/src/.hidden/repo" origin git@gitlab.com:group/hidden.git
}

mkrepo() {
    mkdir -p "$1"
    git init -q "$1"
    git -C "$1" remote add "$2" "$3"
}

snapshot() { # all config lines of every test repo
    local r
    for r in "$HOME/src/app" "$HOME/src/nested/deeper/lib" "$HOME/src/excluded" "$HOME/src/other" "$HOME/src/.hidden/repo"; do
        printf '== %s\n' "$r"
        git -C "$r" config --local --list | grep -E '^(remote|git-watchdog)\.' | sort
    done
}

gwd() { "$SCRIPT" "$@"; }
url() { git -C "$1" config --get-all "remote.$2.url"; }
pushurl() { git -C "$1" config --get-all "remote.$2.pushurl"; }

start_fake() { "$T/bin/$FAKE_PROC" 300 & FAKE_PID=$!; sleep 0.3; }
stop_fake() { kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; }

run_suite() {
    local before out
    setup

    # --- repository files
    eq "config.example.yaml starts with the default config" "$(gwd __default-config)" \
        "$(head -n "$(gwd __default-config | wc -l)" "$ROOT/config.example.yaml")"

    # --- tool check and init
    check "check reports all tools present" eval "gwd check >/dev/null"
    printf '# user bashrc\n' >"$HOME/.bashrc"
    out="$(printf '%s\n' "$TOKEN" | gwd init gitlab.com)"
    check "init creates config" test -f "$CFG"
    eq "config is owner-only" "600" "$(stat -c %a "$CFG" 2>/dev/null || stat -f %Lp "$CFG")"
    check "init installs completion" test -f "$HOME/.local/share/bash-completion/completions/git-watchdog"
    check "init links git extension" test -L "$HOME/.local/bin/git-watchdog"
    check "init output does not echo the token" sh -c "! printf '%s' \"\$1\" | grep -q '$TOKEN'" _ "$out"
    local completion="$HOME/.local/share/bash-completion/completions/git-watchdog"
    # The .bashrc line refers to the literal $HOME.
    # shellcheck disable=SC2016
    local bashrc_completion='$HOME/.local/share/bash-completion/completions/git-watchdog' bashrc_snap='$HOME/snap/git-watchdog/common/git-watchdog.bash'
    eq "init adds the completion to .bashrc" "1" "$(grep -cF "$bashrc_completion" "$HOME/.bashrc")"
    GIT_WATCHDOG_TOKEN="" gwd init git.example.com:8443 >/dev/null
    eq "init does not add the .bashrc line twice" "1" "$(grep -cF "$bashrc_completion" "$HOME/.bashrc")"
    check ".bashrc loads the completion" bash -c ". '$HOME/.bashrc' && declare -F _git_watchdog >/dev/null"
    mv "$completion" "$T/completion.bak"
    check ".bashrc still works without the completion file" bash -c "set -e; . '$HOME/.bashrc'"
    mv "$T/completion.bak" "$completion"
    # Inside the snap the completion lives in the snap's data dir.
    local snap_init_out
    snap_init_out="$(SNAP=/snap/git-watchdog/x1 SNAP_USER_COMMON="$HOME/snap/git-watchdog/common" SNAP_USER_DATA="$HOME/snap/git-watchdog/x1" gwd init)"
    check "snap init writes the autostart entry" grep -q '^Exec=git-watchdog.daemon$' "$HOME/snap/git-watchdog/x1/.config/autostart/git-watchdog-daemon.desktop"
    check "snap init writes completion to its data dir" test -f "$HOME/snap/git-watchdog/common/git-watchdog.bash"
    check "snap init keeps its config in its data dir" test -f "$HOME/snap/git-watchdog/common/config.yaml"
    check "snap init leaves .bashrc alone" sh -c "! grep -qF '$bashrc_snap' '$HOME/.bashrc'"
    check "snap init prints the .bashrc line" grep -qF "$bashrc_snap" <<<"$snap_init_out"
    rm -rf "$HOME/snap"
    GIT_WATCHDOG_TOKEN="new-token" gwd init git.example.com:8443 >/dev/null
    eq "init updates an existing host token once" "1" "$(grep -c 'new-token' "$CFG")"

    # Use the fake agent process and the test source dir.
    local tmp="$T/cfg"
    sed -e "s#- \$HOME\$#- \$HOME/src#" -e "s#^  - claude\$#  - $FAKE_PROC#" -e "/^  - claude-desktop\$/d" "$CFG" >"$tmp"
    cat >>"$tmp" <<EOF
check-interval: 1
EOF
    cp "$tmp" "$CFG"
    # Add an exclude for group/project under gitlab.com (block style).
    awk '{print} /^  gitlab.com:$/ {print "    exclude:"; print "      - group/project"}' "$CFG" >"$tmp" && cp "$tmp" "$CFG"
    grep -q 'exclude:' "$CFG" || fail "exclude inserted" "$(cat "$CFG")"
    cp "$CFG" "$T/cfg.full"

    # --- inactive: nothing changes
    before="$(snapshot)"
    gwd sync >/dev/null
    eq "sync without matching process changes nothing" "$before" "$(snapshot)"

    # --- dry run while active
    start_fake
    out="$(gwd --dry-run)"
    eq "dry-run changes nothing" "$before" "$(snapshot)"
    check "dry-run reports planned changes" grep -q 'would' <<<"$out"

    # --- active: mask
    gwd sync >/dev/null
    eq "gitlab remote gets token URL" "https://oauth2:$TOKEN@gitlab.com/group/app.git" "$(url "$HOME/src/app" origin)"
    check "gitlab remote push disabled" grep -q '^git-watchdog-read-only://' <<<"$(pushurl "$HOME/src/app" origin)"
    eq "unconfigured host untouched" "https://github.com/someone/app.git" "$(url "$HOME/src/app" github)"
    eq "ssh:// URL converted" "https://oauth2:$TOKEN@gitlab.com/group/sub/lib.git" "$(url "$HOME/src/nested/deeper/lib" origin)"
    eq "excluded project untouched" "git@gitlab.com:group/project.git" "$(url "$HOME/src/excluded" origin)"
    eq "host:port with custom token" "https://oauth2:new-token@git.example.com:8443/team/tool.git" "$(url "$HOME/src/other" origin)"
    eq "hidden directories are skipped" "git@gitlab.com:group/hidden.git" "$(url "$HOME/src/.hidden/repo" origin)"
    check "saved original URL is masked" grep -q '^gwd1:[0-9a-f]*$' <<<"$(git -C "$HOME/src/app" config git-watchdog.origin.url)"
    check "original URL is not readable in .git/config" sh -c "! grep -q 'git@gitlab.com' '$HOME/src/app/.git/config'"
    check "saved pushurl is masked" sh -c "! grep -q 'git@gitlab.com' '$HOME/src/nested/deeper/lib/.git/config'"
    local masked_snapshot
    masked_snapshot="$(snapshot)"
    gwd sync >/dev/null
    eq "second sync is idempotent" "$masked_snapshot" "$(snapshot)"
    out="$(gwd status -v --dry-run)"
    check "status shows ACTIVE" grep -q 'Read-only mode: ACTIVE' <<<"$out"
    check "status names process and pid" grep -q "triggered by: $FAKE_PROC (pid $FAKE_PID)" <<<"$out"
    check "status -v lists masked remotes" grep -q "src/app (origin)" <<<"$out"
    check "git push is refused" sh -c "! git -C '$HOME/src/app' push origin HEAD 2>/dev/null"

    # --- a host without a token keeps the original fetch URL, push stays blocked
    GIT_WATCHDOG_TOKEN="" gwd init gitlab.com >/dev/null
    gwd sync >/dev/null
    eq "removing the token restores the fetch URL" "git@gitlab.com:group/app.git" "$(url "$HOME/src/app" origin)"
    check "removing the token keeps push disabled" grep -q '^git-watchdog-read-only://' <<<"$(pushurl "$HOME/src/app" origin)"

    # --- token rotation refreshes URLs
    GIT_WATCHDOG_TOKEN="rotated" gwd init gitlab.com >/dev/null
    gwd sync >/dev/null
    eq "token rotation refreshes URL" "https://oauth2:rotated@gitlab.com/group/app.git" "$(url "$HOME/src/app" origin)"

    # --- rename while masked is adopted
    git -C "$HOME/src/app" remote rename origin upstream
    gwd sync >/dev/null
    check "renamed remote keeps its saved state" grep -q '^gwd1:' <<<"$(git -C "$HOME/src/app" config git-watchdog.upstream.url)"
    git -C "$HOME/src/app" remote rename upstream origin
    gwd sync >/dev/null

    # --- inactive: exact revert
    stop_fake
    gwd sync >/dev/null
    eq "revert restores exact original config" "$before" "$(snapshot)"

    # --- no hosts configured: all remotes get pushing disabled, URLs unchanged
    awk '/^remote:/ {exit} {print}' "$CFG" >"$tmp" && printf 'remote:\n' >>"$tmp" && cp "$tmp" "$CFG"
    start_fake
    gwd sync >/dev/null
    eq "all-remotes mode keeps fetch URL" "https://github.com/someone/app.git" "$(url "$HOME/src/app" github)"
    check "all-remotes mode disables push" grep -q '^git-watchdog-read-only://' <<<"$(pushurl "$HOME/src/app" github)"
    stop_fake
    gwd sync >/dev/null
    eq "all-remotes mode reverts exactly" "$before" "$(snapshot)"

    # --- daemon
    cp "$T/cfg.full" "$CFG" # config with hosts again
    GIT_WATCHDOG_TOKEN="$TOKEN" gwd init gitlab.com >/dev/null
    out="$(gwd status)"
    check "status starts the daemon" grep -q 'Daemon:         running' <<<"$out"
    check "status shows inactive" grep -q 'Read-only mode: inactive' <<<"$out"
    start_fake
    sleep 3
    eq "daemon masks when process starts" "https://oauth2:$TOKEN@gitlab.com/group/app.git" "$(url "$HOME/src/app" origin)"
    stop_fake
    sleep 3
    eq "daemon reverts when process exits" "$before" "$(snapshot)"
    out="$(gwd status)"
    local pid1 pid2
    pid1="$(sed -n 's/.*running (pid \([0-9]*\)).*/\1/p' <<<"$out")"
    pid2="$(sed -n 's/.*running (pid \([0-9]*\)).*/\1/p' <<<"$(gwd status)")"
    eq "status reuses the running daemon" "$pid1" "$pid2"
    gwd stop >/dev/null
    check "stop terminates the daemon" sh -c "! kill -0 $pid1 2>/dev/null"

    # --- log hygiene
    eq "log is owner-only" "600" "$(stat -c %a "$LOG" 2>/dev/null || stat -f %Lp "$LOG")"
    check "log never contains the token" sh -c "! grep -q '$TOKEN' '$LOG'"
    check "log contains activity" grep -q 'read-only mode ACTIVE' "$LOG"

    # --- uninstall (keeps the config by default)
    printf 'alias ll="ls -l"\n' >>"$HOME/.bashrc"
    gwd start >/dev/null
    start_fake
    sleep 3
    gwd --dry-run uninstall >/dev/null
    check "uninstall --dry-run keeps the daemon" eval "gwd status --dry-run | grep -q 'Daemon:         running'"
    check "uninstall --dry-run keeps read-only mode" grep -q '^git-watchdog-read-only://' <<<"$(pushurl "$HOME/src/app" origin)"
    gwd uninstall >/dev/null
    stop_fake
    check "uninstall stops the daemon" sh -c "! test -d '$GIT_WATCHDOG_RUN_DIR/git-watchdog-$(id -u).lock'"
    eq "uninstall restores the remotes" "$before" "$(snapshot)"
    check "uninstall removes the git command link" sh -c "! test -e '$HOME/.local/bin/git-watchdog'"
    check "uninstall removes the completion" sh -c "! test -e '$completion'"
    check "uninstall removes the .bashrc line" sh -c "! grep -q 'git-watchdog' '$HOME/.bashrc'"
    check "uninstall keeps other .bashrc lines" grep -q 'alias ll=' "$HOME/.bashrc"
    check "uninstall removes the log" sh -c "! test -e '$LOG'"
    check "uninstall keeps the config" test -f "$CFG"
    gwd uninstall --remove-config >/dev/null
    check "uninstall --remove-config removes the config" sh -c "! test -e '$CFG'"

    rm -rf "$T"
}

run_suite

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
