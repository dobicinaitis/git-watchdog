# Developer guide

## Tests

Run the test suite with:

```bash
tests/run-tests.sh
```

The tests create throwaway repositories and a fake agent process in a temporary directory, using their own `HOME` and
log/lock directories.

## CI

[CI](../.github/workflows/ci.yml) runs ShellCheck and the test suite on Ubuntu and macOS using the stock Bash 3.2.

## Releases

Releases are fully automated by [create-release.yml](../.github/workflows/create-release.yml). It runs on every push
to `main` (and manually via *Run workflow*):

1. Runs [CI](../.github/workflows/ci.yml) (ShellCheck and tests); nothing is released if it fails.
2. Calculates the next version from the [conventional commits](https://www.conventionalcommits.org/) since the latest
   `vX.Y.Z` tag. If none of them warrants a release, the run stops here.
3. Sets the version in `git-watchdog.sh` and `snap/snapcraft.yaml`, commits it as
   `chore: bumped release version to X.Y.Z`, tags it `vX.Y.Z`, pushes both and creates a GitHub release whose notes
   list the commit subjects (without `chore`/`ci`/`cleanup` commits).
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
sudo snap install --dangerous git-watchdog_0.1.0_amd64.snap
sudo snap connect git-watchdog:system-observe
git watchdog init gitlab.com
```

Notes:

- `system-observe` (needed to see other processes) is not connected automatically for locally built snaps, so the
  `snap connect` command is required.

- See the [README](../README.md#snap-details) for where the snap keeps its config, log and completion script.
