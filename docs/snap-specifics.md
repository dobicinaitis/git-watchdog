# Snap specifics

These notes apply to the snap installed from the Snap Store. For the install steps, see
the [README](../README.md#install). For a Git checkout, see [Install from source](install-from-source.md).

## Bash completion

The snap provides Bash completion for `git-watchdog`. For `git watchdog <TAB>` to work, `init` prints a command to link
the snap's completion script into the `bash-completion` directory, which the snap is not allowed to write itself.

Run these commands to enable `git` completion if you skipped it during `init`:

```bash
mkdir -p ~/.local/share/bash-completion/completions
ln -sf ~/snap/git-watchdog/common/git-watchdog.bash ~/.local/share/bash-completion/completions/git-watchdog
```

## Start at login

The snap starts the daemon when you log in to your desktop using snap's `autostart` support.

`init` also starts the daemon right away, so it runs without logging out and back in.

Without a desktop session, such as over SSH, the daemon starts the first time you run `git watchdog`.

## Configuration and log

- The snap keeps its configuration in `~/snap/git-watchdog/common/config.yaml` instead of
  `~/.config/git-watchdog/config.yaml`, because a confined snap cannot access `~/.config` without the super-privileged
  `personal-files` interface. The folder survives snap updates and is removed together with the snap.

- Snaps have a private `/tmp`, so the snap's log is located at:

  `/tmp/snap-private-tmp/snap.git-watchdog/tmp/git-watchdog-<uid>.log`

  Use `git watchdog logs` to read it.

## Repository access

The `home` interface covers repositories under `$HOME`, but not repositories inside hidden top-level directories.

## Updates

snapd normally postpones automatic refreshes while one of a snap's apps is running, and the daemon is always running.
snapd then notifies you of the pending update and applies it anyway after its deadline (about two weeks). Either way,
the running daemon switches to the new revision on its own once the refresh happens.

To update right away:

```bash
git watchdog stop
sudo snap refresh git-watchdog
git watchdog
```

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
