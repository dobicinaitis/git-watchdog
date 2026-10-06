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
