# git-watchdog

`git-watchdog` switches the remotes of your Git repositories to **read-only mode while selected processes are running**
(for example, the `claude` CLI or Claude Desktop), then restores them when those processes exit.

![](snap/local/logo.png)

While read-only mode is active, each matching remote is modified as follows:

- The fetch URL is replaced with an HTTPS URL containing a **read-only token**:

  `git@github.com:group/app.git` → `https://oauth2:<token>@github.com/group/app.git`

  This keeps fetching and pulling working without requiring your SSH keys.

- Pushing is disabled by setting `pushurl` to `git-watchdog-read-only://…`. \
  As a result, `git push` fails with: `unable to find remote helper for 'git-watchdog-read-only'`

When no matching process remains, the original `url` and `pushurl` values are restored exactly as they were.

## How it works

- **Stateless.** The original remote configuration is saved, masked, inside each repository's own `.git/config`:

    ```toml
    [git-watchdog "origin"]
        key = 29f246bdbad15494a6166a1c3cf8af50
        url = gwd1:4e9b32fdddb820f8c774447f539595375b9d33cd95b024e488710368
    ```

  A remote is considered to be in read-only mode when its saved `url` exists. This means the current state can always be
  derived from Git itself. If the daemon crashes or restarts, it simply converges back to the correct state.

- **Masked originals.** Saved `url` and `pushurl` values are XOR-ed with a random per-remote `key` (16 bytes from
  `/dev/urandom`) and hex encoded. This prevents the original remote from being directly readable from `.git/config`,
  for example by an agent inspecting `git config --list`. The key is stored alongside the value, so this is
  **obfuscation, not strong encryption**.

- The daemon checks the process list every `check-interval` seconds. It rescans repositories under `source-directories`
  whenever read-only mode switches on or off, and every `rescan-interval` seconds to detect new clones and configuration
  changes.

- Processes are matched by exact process name (`pgrep -x`). A matcher can also be an extended regular expression such as
  `claude.*`.

- Hidden directories and `node_modules` are skipped when searching for repositories.

## Install from source

Requirements: `bash` (3.2+), `git`, `pgrep`/`ps`, and standard POSIX tools such as `awk` and `od`.

```bash
git clone git@github.com:dobicinaitis/git-watchdog.git
./git-watchdog/git-watchdog.sh init # config, completion, `git watchdog`
git watchdog init gitlab.com        # asks for the read-only token
git watchdog                        # starts the daemon, shows status
```

`init` performs the following actions and is safe to run repeatedly:

1. Creates `~/.config/git-watchdog/config.yaml` with mode `600` and its parent directory with mode `700`.

2. If a host is specified, stores the read-only token for that host. The token is read from a hidden prompt,
   `$GIT_WATCHDOG_TOKEN`, or stdin, so it does not appear in shell history.

3. Installs Bash completion at: `~/.local/share/bash-completion/completions/git-watchdog`.

   The snap uses snapd's built-in completer instead.

4. Creates `~/.local/bin/git-watchdog` as a link to the script, unless `git-watchdog` is already available on `PATH`.
   This allows `git watchdog` to work as a Git subcommand.

5. If `~/.bashrc` exists and does not already reference the completion file, appends:

    ```
    if [ -f "$HOME/.local/share/bash-completion/completions/git-watchdog" ]; then . "$HOME/.local/share/bash-completion/completions/git-watchdog"; fi  # git-watchdog completion
    ```

   `bash-completion` loads the file automatically for `git-watchdog …`, but `git watchdog <TAB>` requires it to be
   loaded up front. The `if` guard ensures that new shells continue to work if the completion file is later removed.

### Tokens

Create a token with repository read-only access. For example:

- **GitLab:** a personal, group, or project access token with only `read_repository`.

- **GitHub:** a fine-grained token with _Contents: Read-only_ and `username: x-access-token`.

## Usage

```
git watchdog [--dry-run] [command]

  status [-v]     Start the daemon if needed and show whether read-only mode is
                  active and which process (name and pid) caused it. Default.
                  -v also lists the remotes currently in read-only mode.
  init [host]     Create the config, install completion and the git command;
                  with a host, save its read-only token.
  start | stop | restart
  daemon          Run in the foreground (for systemd, launchd, snap).
  sync            Apply the wanted state once and exit.
  revert          Restore all original remotes now.
  check           Show which required tools are installed (every other
                  command checks this on its own and stops if one is missing).
  uninstall [--remove-config]
                  Stop the daemon, restore all remotes and remove what init
                  installed; the config is kept unless --remove-config.
  logs [-f]       Show or follow the log.
  --dry-run       Report what would change without modifying anything.
                  `git watchdog --dry-run` alone runs a dry-run sync.
```

Example:

```bash
$ git watchdog
Read-only mode: ACTIVE
  triggered by: claude (pid 48213)
Daemon:         running (pid 47102)
Config:         /home/me/.config/git-watchdog/config.yaml
Log:            /tmp/git-watchdog-1000.log
```

Stopping the daemon leaves repositories in their current state. If matching processes are still running, those
repositories remain read-only until the daemon is started again or you run:

```bash
git watchdog revert
```

## Configuration

The configuration file is:

`~/.config/git-watchdog/config.yaml`

See `config.example.yaml` for an example.

```yaml
# Base paths to look for Git repositories in ($HOME and ~ are expanded).
source-directories:
  - $HOME

# Process names that enable read-only mode.
process-name-matchers:
  - claude
  - claude-desktop

# Hosts to switch to read-only mode.
remote:
  gitlab.com:
    read-only-token: glpat-xxxxxxxxxxxxxxxxxxxx
    username: oauth2        # optional (default: oauth2)
    exclude: # optional; project paths or globs, e.g. group/*
      - group/project
  git.example.com:8443: # host:port for HTTPS remotes on a custom port
    read-only-token: ...

# Optional tuning (defaults shown).
check-interval: 5
rescan-interval: 300
max-depth: 6
```

- Only remotes on listed hosts are modified. A host without a token still has pushing disabled, but its fetch URL is not
  replaced.

- **If no host is listed** (`remote:` is empty), all remotes in all repositories are processed. Pushing is disabled,
  while fetch URLs remain unchanged because there is no token to use.

The built-in parser supports block-style YAML such as the example above, as well as inline lists such as:

```yaml
[ claude, claude-desktop ]
```

Anchors, multiline strings, and inline maps are not supported.

## Files

| Path                                      | Purpose                                                           |
|-------------------------------------------|-------------------------------------------------------------------|
| `~/.config/git-watchdog/config.yaml`      | Configuration (mode `600`; contains tokens); snap: see below      |
| `/tmp/git-watchdog-<uid>.log`             | Log (mode `600`; rotated at 1 MiB; tokens are redacted)           |
| `/tmp/git-watchdog-<uid>.lock/`           | Daemon lock and PID                                               |
| `.git/config` `[git-watchdog "<remote>"]` | Masked original URLs and their key while read-only mode is active |

## Uninstall

```bash
git watchdog uninstall
```

This stops the daemon, restores every remote, and removes:

- the `git watchdog` link;

- the Bash completion;

- its `~/.bashrc` entry;

- the log; and

- the daemon lock.

The configuration file is kept so a later `init` can reuse it. Add `--remove-config` to delete it, including your stored
tokens.

With `--dry-run`, the command only reports what it would do.

For the snap, run the commands below, then remove the line ending in
`# git-watchdog completion` from `~/.bashrc` if you added it:

```bash
git watchdog uninstall
sudo snap remove git-watchdog
```

## Start at login

### Snap (Linux)

The snap starts the daemon when you log in to your desktop using snap's `autostart` support. `init`
creates:

`~/snap/git-watchdog/current/.config/autostart/git-watchdog-daemon.desktop`

Without a desktop session, such as over SSH, the daemon starts the first time you run `git watchdog`.

The snap also provides Bash completion for `git-watchdog` through snapd's `completer`. For `git watchdog <TAB>`, `init`
copies the completion script to:

`~/snap/git-watchdog/common/git-watchdog.bash`

and prints a guarded line for you to add to `~/.bashrc` (the snap is not allowed to edit it):

```bash
if [ -f "$HOME/snap/git-watchdog/common/git-watchdog.bash" ]; then . "$HOME/snap/git-watchdog/common/git-watchdog.bash"; fi  # git-watchdog completion
```

The directory is deleted when the snap is removed, and the guard makes the line a no-op afterward.

The snap keeps its configuration in `~/snap/git-watchdog/common/config.yaml` instead of
`~/.config/git-watchdog/config.yaml`, because a confined snap cannot access `~/.config` without the super-privileged
`personal-files` interface. The folder survives snap updates and is removed together with the snap.

```bash
snapcraft pack
sudo snap install --dangerous git-watchdog_0.1.0_amd64.snap
sudo snap connect git-watchdog:system-observe
git watchdog init github.com
```

Notes:

- `system-observe` (needed to see other processes) is not connected automatically for locally built snaps, so the
  `snap connect` command is required.

- Snaps have a private `/tmp`, so the snap's log is located at:

  `/tmp/snap-private-tmp/snap.git-watchdog/tmp/git-watchdog-<uid>.log`

  Use `git watchdog logs` to read it.

- The `home` interface covers repositories under `$HOME`, but not repositories inside hidden top-level directories.

### systemd user service (Linux, without snap)

Create:

`~/.config/systemd/user/git-watchdog.service`

```toml
[Unit]
Description = git-watchdog

[Service]
ExecStart = %h/.local/bin/git-watchdog daemon
Restart = always

[Install]
WantedBy = default.target
```

Then enable and start the service:

```bash
systemctl --user enable --now git-watchdog
```

### launchd (macOS)

Create:

`~/Library/LaunchAgents/dev.git-watchdog.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
    <dict>
        <key>Label</key>
        <string>dev.git-watchdog</string>
        <key>ProgramArguments</key>
        <array>
            <string>/Users/YOU/.local/bin/git-watchdog</string>
            <string>daemon</string>
        </array>
        <key>EnvironmentVariables</key>
        <dict>
            <key>PATH</key>
            <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        </dict>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
    </dict>
</plist>
```

Then load it:

```bash
launchctl load ~/Library/LaunchAgents/dev.git-watchdog.plist
```

## macOS notes

The script uses only Bash 3.2 features and BSD-compatible tool flags, so it runs with the stock `/bin/bash`.

On macOS, `pgrep -x` matches the process name as reported by:

```bash
ps -o comm
```

## Security notes

- Read-only mode protects against accidental or unattended pushes through the configured remotes. It is **not a
  sandbox**. A process that can read your SSH keys can still push by explicitly specifying a URL, and a process could
  also unmask the saved original URL in `.git/config`.

- While read-only mode is active, the read-only token is stored in the repositories' `.git/config`. This file is
  typically readable by other local users, so use a token with read-only permissions only.

- Tokens are never written to the log or displayed by `status`.

## Development

Run the test suite with:

```bash
tests/run-tests.sh
```

The tests create throwaway repositories and a fake agent process in a temporary directory, using their own `HOME` and
log/lock directories.

[CI](.github/workflows/ci.yml) runs ShellCheck and the test suite on Ubuntu and macOS using the stock Bash 3.2.