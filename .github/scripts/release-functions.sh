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

# Sets the release version in git-watchdog.sh and snap/snapcraft.yaml.
update_version() {
    local new_version=$1
    local script="$REPO_BASE_DIR/git-watchdog.sh"
    local snapcraft="$REPO_BASE_DIR/snap/snapcraft.yaml"
    if ! [[ "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Invalid version: '$new_version'" >&2
        return 1
    fi
    sed -i -E "s/^VERSION=\"[^\"]*\"$/VERSION=\"${new_version}\"/" "$script"
    sed -i -E "s/^version: '[^']*'$/version: '${new_version}'/" "$snapcraft"
    # fail if either file was not updated
    grep -qx "VERSION=\"${new_version}\"" "$script" || { echo "Version not set in $script" >&2; return 1; }
    grep -qx "version: '${new_version}'" "$snapcraft" || { echo "Version not set in $snapcraft" >&2; return 1; }
}
