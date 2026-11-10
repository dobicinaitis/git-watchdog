# Developer guide

## Tests

Run the test suite with:

```bash
tests/run-tests.sh
```

The tests create throwaway repositories and a fake agent process in a temporary directory, using their own `HOME` and
log/lock directories.

## Manual testing

To try a change by hand, create a test environment:

```bash
./git-watchdog.sh create-test-environment # or: git watchdog create-test-environment
. ~/git-watchdog-test-environment/env.sh
```

This creates a `~/git-watchdog-test-environment` directory with:

- Three repositories in `test-repos/`: 
  - `app` - fake gitlab.com remote with a read-only token
  - `tool` a host without a token
  - `excluded` - an excluded repository in the config
- A local bare repository as each one's remote, so pushes and fetches never reach the network.
- Its own config, log and daemon, which run next to your regular ones.
- A `fake-monitored-process` script that turns read-only mode on while it runs.

The `env.sh` file points `GIT_WATCHDOG_CONFIG` and `GIT_WATCHDOG_RUN_DIR` at the test environment and defines a
`git-watchdog-test` command as the git-watchdog that created it.

> [!NOTE]
> If your regular config watches `$HOME`, your regular daemon also finds the test repositories and switches them to
> read-only mode while a real monitored processes runs. Stop it using `git watchdog stop` while you test.

```bash
"$TEST_ENV/fake-monitored-process" &   # read-only mode on
cd "$TEST_ENV/test-repos/app"
git-watchdog-test status -v
git push origin HEAD:main              # blocked
kill %1                                # read-only mode off
```

### Script or snap

`env.sh` runs the git-watchdog that created the environment: the script from your checkout or the snap.
To switch, create the environment again with the other one, or redefine `git-watchdog-test`.

> [!WARNING]
> With the snap installed, `git watchdog` and `git-watchdog` run the snap. Run the script using `git-watchdog-test`, 
> and don't run its `init`: that writes `~/.config/git-watchdog` and replaces the snap's completion link.

To test a snap you built, install it over the Store version (your config is kept), then go back afterwards:

```bash
sudo snap install --dangerous git-watchdog_0.4.0_amd64.snap
sudo snap connect git-watchdog:system-observe
git watchdog create-test-environment # git-watchdog-test now runs the snap
# ... test ...
sudo snap revert git-watchdog # back to the Store revision
```

Your regular daemon moves to the new revision on its own; `git watchdog logs` shows it.

### Clean up

```bash
git-watchdog-test stop; pkill -f fake-monitored-process; rm -rf ~/git-watchdog-test-environment
```

## CI

[CI](../.github/workflows/ci.yml) runs ShellCheck and the test suite on Ubuntu and macOS using the stock Bash 3.2.

## Releases

Releases are fully automated by [create-release.yml](../.github/workflows/create-release.yml). It runs on every push
to `main` (and manually via *Run workflow*):

1. Runs [CI](../.github/workflows/ci.yml) (ShellCheck and tests); nothing is released if it fails.
2. Calculates the next version from the [conventional commits](https://www.conventionalcommits.org/) since the latest
   `vX.Y.Z` tag. If none of them warrants a release, the run stops here.
3. Sets the version in `git-watchdog.sh`, `snap/snapcraft.yaml` and the snap file name in `docs/dev-guide.md`,
   commits it as `chore: bumped release version to X.Y.Z`, tags it `vX.Y.Z`, pushes both and creates a GitHub release
   whose notes list the commit subjects (without `chore`/`ci`/`cleanup` commits).
4. Builds the snap from the tag, checks `git-watchdog version` and publishes it to the Snap Store `stable` channel.

The version bump commit does not trigger another release (it is pushed with `GITHUB_TOKEN`, and the workflow skips
commits starting with `chore: bumped release version`).

| Commit                                                     | Version bump |
|------------------------------------------------------------|--------------|
| `feat!: ...`, or `BREAKING CHANGE:` in the message body    | major        |
| `feat: ...`, `feature: ...`                                | minor        |
| `fix:`, `bugfix:`, `perf:`, `refactor:`, `test:`, `tests:` | patch        |
| `docs:`, `chore:`, `ci:`, `style:`, `build:`, ...          | none         |

Required setup:

- Secret `SNAPCRAFT_TOKEN`: Snap Store credentials, created with
  `snapcraft export-login --snaps=git-watchdog --channels=stable --acls=package_access,package_push,package_update,package_release -`.
- *Settings → Actions → General → Workflow permissions*: the workflow requests `contents: write` itself, but if
  `main` is protected, allow GitHub Actions to bypass the rule (or the push of the version bump is rejected).
- The version is calculated relative to the latest tag, so the first release needs an existing tag, e.g. on the
  initial commit: `git tag v0.0.0 $(git rev-list --max-parents=0 HEAD) && git push origin v0.0.0`.

## Building the snap

```bash
snapcraft pack
sudo snap install --dangerous git-watchdog_0.4.0_amd64.snap
sudo snap connect git-watchdog:system-observe
git watchdog init gitlab.com
```

Notes:

- `system-observe` (needed to see other processes) is not connected automatically for locally built snaps, so the
  `snap connect` command is required.

- See [Snap specifics](snap-specifics.md#configuration-and-log) for where the snap keeps its config and log, and
  [Bash completion](snap-specifics.md#bash-completion) for its completion script.
