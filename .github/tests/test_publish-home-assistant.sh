#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

publish() {
    ADDON_TARGET=cloudflared \
        ADDON_SLUG=cloudflared \
        GITHUB_REPOSITORY_OWNER=ExampleOwner \
        PUBLISH_BRANCH=main \
        RELEASE_VERSION="$1" \
        bash "${script_dir}/publish-home-assistant.sh"
}

git init --bare --quiet "${test_root}/origin.git"
git init --quiet --initial-branch=main "${test_root}/work"
cd "${test_root}/work"
git config user.name "Publishing test"
git config user.email "publishing-test@example.invalid"
git remote add origin "${test_root}/origin.git"
mkdir cloudflared
cat >cloudflared/config.yaml <<'YAML'
---
name: Cloudflared
version: 7.0.6
arch:
  - aarch64
  - amd64
  - armv7
  - i386
options:
  external_hostname: ""
YAML
original_options=$(yq -o=json -I=0 '.options' cloudflared/config.yaml)
original_architectures=$(yq -o=json -I=0 '.arch' cloudflared/config.yaml)
git add cloudflared/config.yaml
git commit --quiet -m "test: create installable repository"
git push --quiet --set-upstream origin main

publish 7.0.6
[[ "$(yq -r '.image' cloudflared/config.yaml)" == 'ghcr.io/exampleowner/cloudflared/{arch}' ]] || fail "Image is not derived from the repository owner and slug"
[[ "$(git rev-list --count HEAD)" == 2 ]] || fail "Existing release did not publish its image metadata"
echo "PASS: connect existing release images"

publish 7.0.10
[[ "$(yq -r '.version' cloudflared/config.yaml)" == 7.0.10 ]] || fail "Release version was not updated"
[[ "$(yq -o=json -I=0 '.options' cloudflared/config.yaml)" == "${original_options}" ]] || fail "Add-on options changed"
[[ "$(yq -o=json -I=0 '.arch' cloudflared/config.yaml)" == "${original_architectures}" ]] || fail "Supported architectures changed"
git --git-dir="${test_root}/origin.git" show main:cloudflared/config.yaml >"${test_root}/published.yaml"
cmp cloudflared/config.yaml "${test_root}/published.yaml" || fail "Published metadata differs from the commit"
[[ -z "$(git status --porcelain)" ]] || fail "Publishing left uncommitted files"
echo "PASS: publish the next release and preserve install configuration"

published_commit=$(git rev-parse HEAD)
publish 7.0.10
[[ "$(git rev-parse HEAD)" == "${published_commit}" ]] || fail "Rerun created an unnecessary commit"
echo "PASS: repeated publication is a no-op"

publish 7.0.9
[[ "$(git rev-parse HEAD)" == "${published_commit}" ]] || fail "Older release replaced current metadata"
echo "PASS: older release cannot roll back metadata"

if publish '7.0.8; invalid' >"${test_root}/invalid.log" 2>&1; then
    fail "Invalid release version was accepted"
fi
[[ -z "$(git status --porcelain)" ]] || fail "Invalid release changed the repository"
echo "PASS: invalid release is rejected before writing"

if ADDON_TARGET=../outside \
    ADDON_SLUG=cloudflared \
    GITHUB_REPOSITORY_OWNER=ExampleOwner \
    PUBLISH_BRANCH=main \
    RELEASE_VERSION=7.0.8 \
    bash "${script_dir}/publish-home-assistant.sh" >"${test_root}/invalid.log" 2>&1; then
    fail "Add-on directory traversal was accepted"
fi
[[ -z "$(git status --porcelain)" ]] || fail "Invalid directory changed the repository"
echo "PASS: invalid add-on directory is rejected before writing"

yq -i '.version = "dev"' cloudflared/config.yaml
git add cloudflared/config.yaml
git commit --quiet -m "test: use upstream development metadata"
publish 7.0.11
[[ "$(yq -r '.version' cloudflared/config.yaml)" == 7.0.11 ]] || fail "Development metadata was not published"
echo "PASS: upstream development metadata can publish a stable version"

published_commit=$(git --git-dir="${test_root}/origin.git" rev-parse main)
cat >"${test_root}/origin.git/hooks/pre-receive" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "${test_root}/origin.git/hooks/pre-receive"
if publish 7.0.12 >"${test_root}/rejected.log" 2>&1; then
    fail "Rejected push was reported as successful"
fi
[[ "$(git --git-dir="${test_root}/origin.git" rev-parse main)" == "${published_commit}" ]] || fail "Rejected push changed published metadata"
echo "PASS: rejected push fails without changing the published repository"
