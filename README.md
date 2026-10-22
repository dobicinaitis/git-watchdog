# git-watchdog

AI coding agents run commands with your permissions, including your SSH keys and Git credentials. A single
unattended `git push` can force-push over shared history, delete a branch or publish unreviewed code, and that is hard
to undo once it reaches the server.

`git-watchdog` removes push access while an agent is running. As long as a watched process is alive (by default the
Claude CLI and Claude Desktop), it puts the remotes of your local repositories in **read-only mode**:

- **Pushing is blocked**, so `git push` fails instead of reaching the server.
- **Fetching keeps working** through a read-only access token, so the agent doesn't need your SSH key to pull.

When the process exits, the original remotes are restored exactly as they were. It guards against accidental pushes,
not a determined attacker; see [Security notes](#security-notes).

![](snap/local/logo.png)

## How it works

The daemon watches the process list and switches each matching remote between two states:

|                      | Normal                     | Read-only mode                         |
|----------------------|----------------------------|----------------------------------------|
| **When**             | no watched process running | a watched process is running           |
| **Fetch** (`url`)    | your original URL          | HTTPS URL with the read-only token     |
| **Push** (`pushurl`) | your original setting      | `git-watchdog-read-only://…` (blocked) |

For example, an SSH remote on GitLab becomes:

```text
url      git@gitlab.com:group/app.git  →  https://oauth2:<token>@gitlab.com/group/app.git
pushurl  (unset)                       →  git-watchdog-read-only://push-disabled-while-read-only-mode-is-active
```

Fetching and pulling keep working without your SSH keys, while `git push` fails with:

```text
fatal: unable to find remote helper for 'git-watchdog-read-only'
```

When the last watched process exits, `url` and `pushurl` are restored exactly as they were.

### Details

#### State lives in Git

There is no separate state file. The original values are saved, masked, in each repository's own `.git/config`:

```ini
[git-watchdog "origin"]
    key = 29f246bdbad15494a6166a1c3cf8af50
    url = gwd1:4e9b32fdddb820f8c774447f539595375b9d33cd95b024e488710368
```

A remote is in read-only mode exactly when this saved `url` exists, so the state can always be read from Git itself.
If the daemon crashes or restarts, it simply converges back to the correct state.

> [!NOTE]
> **Masked, not encrypted.** Saved values are XOR-ed with a random per-remote `key` (16 bytes from `/dev/urandom`)
> and hex encoded, so an agent running `git config --list` doesn't see the original remote. The key is stored next to
> the value, so this is obfuscation, not strong encryption.

#### Runtime behavior

| What               | How                                                                             |
|--------------------|---------------------------------------------------------------------------------|
| Process checks     | Every `check-interval` seconds (default 5)                                      |
| Repository rescans | When read-only mode switches, and every `rescan-interval` seconds (default 300) |
| Process matching   | Exact name (`pgrep -x`), or an extended regular expression such as `claude.*`   |
| Repository search  | Under `source-directories`, skipping hidden directories and `node_modules`      |
| Updates            | The daemon restarts itself after `git pull`, a snap refresh or a reinstall      |

## Install

Install the snap from the Snap Store, then create the config and save a read-only token for your Git host:

```bash
sudo snap install git-watchdog
git watchdog init gitlab.com   # asks for the read-only token
git watchdog                   # shows the status
```

The snap needs `system-observe` connected by hand for now, and it keeps its config and log in snap-specific
locations. See [Snap specifics](docs/snap-specifics.md) for that and other snap details.

To install from a Git checkout instead (Linux or macOS), see [Install from source](docs/install-from-source.md).

`init` writes the config and prints the next steps. It's safe to run repeatedly. The token can be read from a hidden
prompt, `$GIT_WATCHDOG_TOKEN`, or stdin.

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

The configuration file is `~/snap/git-watchdog/common/config.yaml` for the snap (see
[Snap specifics](docs/snap-specifics.md#configuration-and-log)), or `~/.config/git-watchdog/config.yaml` when
[installed from source](docs/install-from-source.md).

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
| `~/snap/git-watchdog/common/config.yaml`  | Configuration when installed as a snap                                                           |
| `~/.config/git-watchdog/config.yaml`      | Configuration when [installed from source](docs/install-from-source.md)                          |
| `/tmp/git-watchdog-<uid>.log`             | Log (rotated at 1 MiB); snap: see [Snap specifics](docs/snap-specifics.md#configuration-and-log) |
| `/tmp/git-watchdog-<uid>.lock/`           | Daemon lock and PID                                                                              |
| `.git/config` `[git-watchdog "<remote>"]` | Masked original URLs and their key while read-only mode is active                                |

## Uninstall

For the snap, see [Uninstall](docs/snap-specifics.md#uninstall) in the snap notes. For a source install, see
[Uninstall](docs/install-from-source.md#uninstall) in the source install guide.

## Security notes

- Read-only mode protects against accidental or unattended pushes through the configured remotes. It is **not a
  sandbox**. A process that can read your SSH keys can still push by explicitly specifying a URL, and a process could
  also unmask the saved original URL in `.git/config`.

- While read-only mode is active, the read-only token is stored in the repositories' `.git/config`. This file is
  typically readable by other local users, so use a token with read-only permissions only.

- Tokens are never written to the log or displayed by `status`.

## Development

See the [developer guide](docs/dev-guide.md) for running the tests, CI and building the snap.
