# Install from source (Linux)

These steps install `git-watchdog` from a Git checkout instead of the snap. For the snap, see the
[README](../README.md#install).

> [!NOTE]
> These steps are tested on Linux. The script avoids GNU-only tool flags and its test suite also runs on macOS in CI,
> but a full macOS setup (process names, shell completion, starting at login) hasn't been verified. If you use macOS
> and want to help, contributions are welcome.

Requirements: `bash` (3.2+), `git`, `pgrep`/`ps`, and standard POSIX tools such as `awk` and `od`.

```bash
git clone git@github.com:dobicinaitis/git-watchdog.git
./git-watchdog/git-watchdog.sh init # config, completion, `git watchdog`
git watchdog init gitlab.com        # asks for the read-only token
git watchdog                        # starts the daemon, shows status
```

Example output:

```text
git-watchdog init

  ✓ Tools        all required tools are installed
  ✓ Config       ~/.config/git-watchdog/config.yaml (created)
  ✓ Remote       gitlab.com (read-only token saved)
  ✓ Completion   ~/.local/share/bash-completion/completions/git-watchdog
  ✓ Git command  git watchdog (~/.local/bin/git-watchdog)

Next steps
  1. Review the config (source directories, process names, hosts):
     ~/.config/git-watchdog/config.yaml
  2. Start the daemon and see its status:
     git watchdog
```

Symbols are colored on a terminal (set `NO_COLOR` to turn that off) and fall back to ASCII outside UTF-8 locales.

`init` performs the following actions and is safe to run repeatedly:

1. Creates `~/.config/git-watchdog/config.yaml` with mode `600` and its parent directory with mode `700`.

2. If a host is specified, stores the read-only token for that host. The token is read from a hidden prompt,
   `$GIT_WATCHDOG_TOKEN`, or stdin, so it does not appear in shell history.

3. Installs Bash completion at: `~/.local/share/bash-completion/completions/git-watchdog`.

4. Creates `~/.local/bin/git-watchdog` as a link to the script, unless `git-watchdog` is already available on `PATH`.
   This allows `git watchdog` to work as a Git subcommand.

See [Tokens](../README.md#tokens) for what kind of token to create.

## Start at login

Without the snap, the daemon is started by `git watchdog` on first use. To start it at login, register it as a systemd
user service.

### systemd user service

Create:

`~/.config/systemd/user/git-watchdog.service`

```ini
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

## Uninstall

```bash
git watchdog uninstall
```

This stops the daemon, restores every remote, and removes:

- the `git watchdog` link;

- the Bash completion;

- the log; and

- the daemon lock.

The configuration file is kept so a later `init` can reuse it. Add `--remove-config` to delete it, including your stored
tokens.

With `--dry-run`, the command only reports what it would do.

If you set up a systemd service, disable and remove it as well, then delete the checkout.
