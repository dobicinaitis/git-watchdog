#!/usr/bin/env bash
# Utility functions used by the release workflow (.github/workflows/create-release.yml).

REPO_BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

# Prints release notes made of the commit subjects since the latest tag, without
# chore/ci/cleanup commits and without the conventional commit types.
print_changelog() {
    local last_tag range
    last_tag=$(git describe --tags --abbrev=0 2>/dev/null)
    range="${last_tag:+${last_tag}..}HEAD"
    printf '## Release notes 🎁\n### Changes\n'
    git log --no-merges --reverse --pretty='- %s → %h' "$range" \
        | sed -E '/^- (cleanup|chore|ci)(\([^)]*\))?!?: /d' \
        | sed -E 's/^- [a-z]+(\([^)]*\))?!?: /- /'
    cat <<'NOTES'

### Install
```bash
sudo snap install git-watchdog
```
NOTES
}

# Sets the release version in git-watchdog.sh, snap/snapcraft.yaml and the snap file name in docs/dev-guide.md.
update_version() {
    local new_version=$1
    local script="$REPO_BASE_DIR/git-watchdog.sh"
    local snapcraft="$REPO_BASE_DIR/snap/snapcraft.yaml"
    local dev_guide="$REPO_BASE_DIR/docs/dev-guide.md"
    if ! [[ "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Invalid version: '$new_version'" >&2
        return 1
    fi
    sed -i -E "s/^VERSION=\"[^\"]*\"$/VERSION=\"${new_version}\"/" "$script"
    sed -i -E "s/^version: '[^']*'$/version: '${new_version}'/" "$snapcraft"
    sed -i -E "s/git-watchdog_[0-9]+\.[0-9]+\.[0-9]+_amd64\.snap/git-watchdog_${new_version}_amd64.snap/g" "$dev_guide"
    # fail if any file was not updated
    grep -qx "VERSION=\"${new_version}\"" "$script" || { echo "Version not set in $script" >&2; return 1; }
    grep -qx "version: '${new_version}'" "$snapcraft" || { echo "Version not set in $snapcraft" >&2; return 1; }
    grep -qF "git-watchdog_${new_version}_amd64.snap" "$dev_guide" || { echo "Version not set in $dev_guide" >&2; return 1; }
}
