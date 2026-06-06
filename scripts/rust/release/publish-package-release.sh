#!/usr/bin/env bash
# Cut a Swift package release.
#
# Tags a new package version on an existing commit, pushes the tag, and
# creates a matching GitHub release whose body links to the Rust artifact
# release pinned in rust/Pin.json and embeds an auto-generated
# "What's Changed" PR list since the previous package release.
#
# Intended to run from `main` after the commit you want to tag has been
# merged. HEAD's rust/Pin.json must point at an existing Rust artifact
# release, but the pinned Rust version does not need to match the Swift
# package version – Swift-only patch releases reuse whatever Rust artifact
# is already pinned.
#
# Usage: scripts/rust/release/publish-package-release.sh <version> [<ref>]
#   <version>  Semantic version for the package tag, e.g. 0.4.1 or 0.4.1-rc.1.
#   <ref>      Optional git ref to tag (defaults to HEAD).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
USAGE="usage: scripts/rust/release/publish-package-release.sh <version> [<ref>] [--yes]"

VERSION=""
REF=""
ASSUME_YES=false
for arg in "$@"; do
  case "${arg}" in
    --yes|-y)
      ASSUME_YES=true
      ;;
    *)
      if [[ -z "${VERSION}" ]]; then
        VERSION="${arg}"
      elif [[ -z "${REF}" ]]; then
        REF="${arg}"
      else
        echo "Unknown argument: ${arg}" >&2
        echo "${USAGE}" >&2
        exit 1
      fi
      ;;
  esac
done

if [[ -z "${VERSION}" ]]; then
  echo "${USAGE}" >&2
  exit 1
fi
REF="${REF:-HEAD}"
PIN_FILE="rust/Pin.json"

# Reject anything that is not a semver string like 1.2.3 or 1.2.3-rc.1.
# We do not want free-form tags like "latest" or "v0.4.1" sneaking in.
if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "Version must be semantic, for example 0.4.1 or 0.4.1-rc.1." >&2
  exit 1
fi

cd "${REPO_ROOT}"

# Confirm the ref exists before we do any mutating work.
git rev-parse --verify "${REF}" >/dev/null

# Bail early if the tag or release already exists – both `git tag` and
# `gh release create` would fail further down anyway, but detecting the
# collision up front keeps error messages informative.
if git rev-parse --verify "refs/tags/${VERSION}" >/dev/null 2>&1; then
  echo "Tag ${VERSION} already exists locally." >&2
  exit 1
fi

if gh release view "${VERSION}" >/dev/null 2>&1; then
  echo "Package release ${VERSION} already exists." >&2
  exit 1
fi

# Read the Rust artifact version pinned at ${REF} and verify the release
# exists. Swift package versions and Rust artifact versions are independent:
# a Swift-only patch release reuses the existing Rust pin, so pin_version
# may lag VERSION. The required invariant is that whichever Rust artifact
# Pin.json points at actually exists upstream.
pin_version="$(git show "${REF}:${PIN_FILE}" | jq -r '.version')"
rust_release_url="$(gh release view "hfapi-rust-${pin_version}" --json url --jq '.url')"

# Guard against drift between Package.swift's inline Rust pin and
# rust/Pin.json at ${REF}. CI runs the same check against the working
# tree on every push; this is the last-mile guard against tagging a
# ref where the two have drifted.
bash "${REPO_ROOT}/scripts/rust/release/check-package-swift-pin.sh" \
  <(git show "${REF}:Package.swift") \
  <(git show "${REF}:${PIN_FILE}")

# Create and push an annotated tag. Annotated (not lightweight) so `git
# describe` and GitHub's release UI treat it as a first-class tag object.
# Pushing a tag is irreversible from the public surface – once consumers
# fetch it they cannot un-fetch it – so prompt for confirmation unless
# --yes was passed.
git tag -a "${VERSION}" "${REF}" -m "${VERSION}"

if [[ "${ASSUME_YES}" != true ]]; then
  ref_sha="$(git rev-parse "${REF}")"
  echo
  echo "About to push tag ${VERSION} -> ${ref_sha} to origin."
  echo "This is irreversible from the public surface; consumers can fetch the tag immediately."
  read -r -p "Push? [y/N] " response
  case "${response}" in
    [yY]|[yY][eE][sS]) ;;
    *)
      echo "Aborted before push. Local tag ${VERSION} still exists; run 'git tag -d ${VERSION}' to delete it." >&2
      exit 1
      ;;
  esac
fi

git push origin "refs/tags/${VERSION}"

# If anything from this point on fails, the tag is already on origin but
# no release exists yet. Without cleanup the next re-run would refuse to
# proceed at the "tag exists locally" check. Delete the local and remote
# tag on failure so the operator can re-run after fixing whatever broke.
on_post_push_failure() {
  echo >&2
  echo "A step after the tag push failed. Cleaning up tag ${VERSION} locally and on origin..." >&2
  git push --delete origin "refs/tags/${VERSION}" 2>/dev/null || true
  git tag -d "${VERSION}" 2>/dev/null || true
  rm -f "${notes_file:-}" 2>/dev/null || true
}
trap on_post_push_failure ERR

# Build the custom prefix that GitHub will prepend above the
# auto-generated "What's Changed" section (see --generate-notes below).
notes_file="$(mktemp)"

cat >"${notes_file}" <<EOF
Associated Rust artifact release:
${rust_release_url}
EOF

# Find the previous package tag so --notes-start-tag gives GitHub the
# correct baseline for "What's Changed". Without it, GitHub's auto-pick
# sometimes chooses an hfapi-rust-* tag instead of a package tag,
# which produces a nonsensical or empty diff.
#
#   git tag --list --sort=-v:refname   → all tags, newest first (version sort).
#   grep '^[0-9]+\.[0-9]+\.[0-9]+...'  → keep only semver-style package tags,
#                                        skipping the parallel hfapi-rust-* series.
#   grep -v "^${VERSION}$"             → drop the tag we just created, since
#                                        that is the *current* release, not the previous one.
#   head -1                            → pick the newest remaining tag.
#   || true                            → allow no match (first-ever release) without tripping `set -e`.
previous_package_tag="$(
  git tag --list --sort=-v:refname \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' \
    | grep -v "^${VERSION}$" \
    | head -1 || true
)"

# Assemble the `gh release create` flags as an array so we can append
# optional flags (--notes-start-tag, --prerelease) without messing with
# shell quoting.
#
# --generate-notes tells GitHub to append an auto-generated "What's
# Changed" section listing merged PRs since the previous tag. Our
# --notes-file contents are prepended above that section.
gh_args=(
  --verify-tag
  --title "${VERSION}"
  --notes-file "${notes_file}"
  --generate-notes
)
if [[ -n "${previous_package_tag}" ]]; then
  gh_args+=(--notes-start-tag "${previous_package_tag}")
fi
# Pre-release tags (1.2.3-rc.1) get the GitHub "pre-release" flag so they
# are not surfaced as Latest on the repo landing page.
if [[ "${VERSION}" == *-* ]]; then
  gh_args+=(--prerelease)
fi

gh release create "${VERSION}" "${gh_args[@]}"

package_release_url="$(gh release view "${VERSION}" --json url --jq '.url')"

echo
echo "Published package release ${VERSION}."
echo "Release: ${package_release_url}"
