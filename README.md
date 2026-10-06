# git-watchdog

`git-watchdog` switches the remotes of your Git repositories to **read-only mode while selected processes are running**
(for example, the `claude` CLI or Claude Desktop), then restores them when those processes exit.

![](snap/local/logo.png)

## How it works

While read-only mode is active, each matching remote is modified as follows:

- The fetch URL is replaced with an HTTPS URL containing a **read-only token**:

  `git@github.com:group/app.git` → `https://oauth2:<token>@github.com/group/app.git`

  This keeps fetching and pulling working without requiring your SSH keys.

- Pushing is disabled by setting `pushurl` to `git-watchdog-read-only://…`. \
  As a result, `git push` fails with: `unable to find remote helper for 'git-watchdog-read-only'`

When no matching process remains, the original `url` and `pushurl` values are restored exactly as they were.

### Details

- The process is **stateless.** Original remote configuration is saved, masked, inside each repository's own
  `.git/config`:

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

- A daemon never keeps running an outdated version. When the program is updated (`git pull`, snap refresh or
  reinstall), the daemon restarts itself, and `git watchdog` replaces a daemon that started before the current program
  was installed.

## Install

Install the snap from the Snap Store, then create the config and save a read-only token for your Git host:

```bash
sudo snap install git-watchdog
git watchdog init gitlab.com   # asks for the read-only token
git watchdog                   # shows the status
```

The snap needs `system-observe` to see other processes. Until the Snap Store grants it automatically, connect it by
hand:

```bash
sudo snap connect git-watchdog:system-observe
```

To install from a Git checkout instead (Linux or macOS), see [Install from source](docs/install-from-source.md).

`init` writes the config and prints the next steps. It's safe to run repeatedly. The token is read from a hidden
prompt, `$GIT_WATCHDOG_TOKEN`, or stdin, so it does not appear in shell history.

### Bash completion

The snap provides Bash completion for `git-watchdog`. For `git watchdog <TAB>` to work, `init` prints a command to link
the snap's completion script into the `bash-completion` directory, which the snap is not allowed to write itself.

Run these commands to enable `git` completion:

```bash
mkdir -p ~/.local/share/bash-completion/completions
ln -sf ~/snap/git-watchdog/common/git-watchdog.bash ~/.local/share/bash-completion/completions/git-watchdog
```

### Start at login

The snap starts the daemon when you log in to your desktop using snap's `autostart` support.

`init` also starts the daemon right away, so it runs without logging out and back in.

Without a desktop session, such as over SSH, the daemon starts the first time you run `git watchdog`.

### Snap details

- The snap keeps its configuration in `~/snap/git-watchdog/common/config.yaml` instead of
  `~/.config/git-watchdog/config.yaml`, because a confined snap cannot access `~/.config` without the super-privileged
  `personal-files` interface. The folder survives snap updates and is removed together with the snap.

- Snaps have a private `/tmp`, so the snap's log is located at:

  `/tmp/snap-private-tmp/snap.git-watchdog/tmp/git-watchdog-<uid>.log`

  Use `git watchdog logs` to read it.

- The `home` interface covers repositories under `$HOME`, but not repositories inside hidden top-level directories.

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
git-watchdog status

  ! Read-only    ACTIVE (pushing is blocked)
                 triggered by claude (pid 48213)
  ✓ Daemon       running (pid 47102)
  ✓ Config       ~/.config/git-watchdog/config.yaml
  ✓ Log          /tmp/git-watchdog-1000.log
```

Stopping the daemon leaves repositories in their current state. If matching processes are still running, those
repositories remain read-only until the daemon is started again or you run:

```bash
git watchdog revert
```

## Configuration

The configuration file is `~/snap/git-watchdog/common/config.yaml` for the snap (see [Snap details](#snap-details)),
or `~/.config/git-watchdog/config.yaml` when [installed from source](docs/install-from-source.md).

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

| Path                                      | Purpose                                                                                          |
|-------------------------------------------|--------------------------------------------------------------------------------------------------|
| `~/snap/git-watchdog/common/config.yaml`  | Configuration (mode `600`; contains tokens)                                                      |
| `~/.config/git-watchdog/config.yaml`      | Configuration when [installed from source](docs/install-from-source.md)                          |
| `/tmp/git-watchdog-<uid>.log`             | Log (mode `600`; rotated at 1 MiB; tokens are redacted); snap: see [Snap details](#snap-details) |
| `/tmp/git-watchdog-<uid>.lock/`           | Daemon lock and PID                                                                              |
| `.git/config` `[git-watchdog "<remote>"]` | Masked original URLs and their key while read-only mode is active                                |

## Uninstall

```bash
git watchdog uninstall
sudo snap remove git-watchdog
```

`git watchdog uninstall` stops the daemon and restores every remote. If you created the completion link described in
[Bash completion](#bash-completion), remove it as well:

```bash
rm ~/.local/share/bash-completion/completions/git-watchdog
```

For a source install, see [Uninstall](docs/install-from-source.md#uninstall) in the source install guide.

## Security notes

- Read-only mode protects against accidental or unattended pushes through the configured remotes. It is **not a
  sandbox**. A process that can read your SSH keys can still push by explicitly specifying a URL, and a process could
  also unmask the saved original URL in `.git/config`.

- While read-only mode is active, the read-only token is stored in the repositories' `.git/config`. This file is
  typically readable by other local users, so use a token with read-only permissions only.

- Tokens are never written to the log or displayed by `status`.

## Development

See the [developer guide](docs/dev-guide.md) for running the tests, CI and building the snap.
