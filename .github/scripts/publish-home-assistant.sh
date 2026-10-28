#!/usr/bin/env bash
set -euo pipefail

fail() {
    echo "::error::$*" >&2
    exit 1
}

# Stable releases use major.minor.patch.
version_pattern='^[0-9]+\.[0-9]+\.[0-9]+$'
[[ "${RELEASE_VERSION:?}" =~ ${version_pattern} ]] || fail "Invalid stable release version: ${RELEASE_VERSION}"
[[ "${ADDON_TARGET:?}" =~ ^[a-zA-Z0-9_-]+$ ]] || fail "Invalid add-on directory"
[[ "${ADDON_SLUG:?}" =~ ^[a-z0-9_-]+$ ]] || fail "Invalid add-on slug"
[[ "${GITHUB_REPOSITORY_OWNER:?}" =~ ^[a-zA-Z0-9-]+$ ]] || fail "Invalid repository owner"
git check-ref-format "refs/heads/${PUBLISH_BRANCH:?}" >/dev/null || fail "Invalid publishing branch"

config="${ADDON_TARGET}/config.yaml"
current_version=$(yq -r '.version' "${config}")
if [[ "${current_version}" != "dev" ]]; then
    [[ "${current_version}" =~ ${version_pattern} ]] || fail "Invalid current add-on version: ${current_version}"
    if dpkg --compare-versions "${RELEASE_VERSION}" lt "${current_version}"; then
        echo "::notice::Keeping ${current_version}; release ${RELEASE_VERSION} is older."
        exit 0
    fi
fi

export ADDON_IMAGE="ghcr.io/${GITHUB_REPOSITORY_OWNER,,}/${ADDON_SLUG}/{arch}"
yq -i '.version = strenv(RELEASE_VERSION) | .image = strenv(ADDON_IMAGE)' "${config}"

if git diff --quiet -- "${config}"; then
    echo "Home Assistant metadata already matches ${RELEASE_VERSION}."
    exit 0
fi

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add -- "${config}"
git commit -m "chore: publish ${ADDON_SLUG} ${RELEASE_VERSION}"
git push origin "HEAD:${PUBLISH_BRANCH}"
