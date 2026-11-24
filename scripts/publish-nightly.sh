#!/usr/bin/env bash
# Copyright 2026 Francisco Perdigon Romero and contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Publishes the current commit as a "nightly-YYYYMMDD-<sha>" pre-release with the DMGs in dist/.
#
# Why one release per commit: with GitHub's "immutable releases" a tag name can never be reused,
# so the old "delete and recreate the `nightly` release" approach fails from the second build on.
# Change history is carried forward from the previous nightly's notes, and only the newest
# KEEP_NIGHTLIES (default 1, the newest) release is kept; its notes hold the full history. Deleted
# releases leave their tags behind, which is harmless.
#
# Needs: gh (authenticated via GH_TOKEN), GITHUB_SHA, a full git checkout, dist/*.dmg.
set -euo pipefail

# Nightlies are published only from main, never from other branches, tags or pull requests.
if [ "${GITHUB_REF:-}" != "refs/heads/main" ]; then
  echo "Refusing to publish a nightly from ${GITHUB_REF:-an unknown ref}; only refs/heads/main may." >&2
  exit 2
fi
KEEP_NIGHTLIES="${KEEP_NIGHTLIES:-1}"
if ! [[ "$KEEP_NIGHTLIES" =~ ^[1-9][0-9]*$ ]]; then
  echo 'KEEP_NIGHTLIES must be a positive integer.' >&2
  exit 2
fi
sha="${GITHUB_SHA:?GITHUB_SHA is required}"
if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo 'GITHUB_SHA must be a full commit SHA.' >&2
  exit 2
fi
short="${sha:0:7}"
day="$(date -u +%Y-%m-%d)"
tag="nightly-${day//-/}-${short}"

if gh release view "$tag" >/dev/null 2>&1; then
  echo "Release $tag already exists (re-run of the same commit); nothing to publish."
  exit 0
fi

# Newest existing nightly release (by creation time), if any.
nightlies() {
  gh release list --limit 100 --json tagName,createdAt \
    --jq '[.[] | select(.tagName | startswith("nightly-"))] | sort_by(.createdAt) | reverse | .[].tagName'
}
prev_tag="$(nightlies | head -n 1 || true)"

prev_body=""
if [ -n "$prev_tag" ]; then
  prev_body="$(gh release view "$prev_tag" --json body --jq .body 2>/dev/null || true)"
fi
prev_sha="$(printf '%s\n' "$prev_body" | sed -n 's/.*nightly-sha: \([0-9a-f]\{40\}\).*/\1/p' | head -n 1)"
prev_history="$(printf '%s\n' "$prev_body" | sed -n '/<!-- history -->/,$p' | tail -n +2)"
if [ -z "$prev_sha" ]; then
  prev_sha="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
fi

notes_tmp="$(mktemp)"
trap 'rm -f "$notes_tmp"' EXIT
{
  echo "Automated build of \`main\` from ${day}, commit ${short} (${sha}). Unsigned (ad-hoc signed, not notarized) and unstable; use a tagged release unless you want the latest changes."
  echo "<!-- nightly-sha: ${sha} -->"
  echo
  echo "## Changes (newest first)"
  echo "<!-- history -->"
  echo "### ${day} (${short})"
  "$(dirname "$0")/release-notes.sh" "$prev_sha" "$sha"
  if [ -n "$prev_history" ]; then
    echo
    printf '%s\n' "$prev_history"
  fi
} > "$notes_tmp"
head -c 100000 "$notes_tmp" > notes.md

for f in dist/*.dmg; do
  mv "$f" "${f%.dmg}-nightly-${day}-${short}.dmg"
  rm -f "$f.sha256"
done

# Checksums use final asset names, including the nightly suffix.
for f in dist/*.dmg; do
  (cd dist && shasum -a 256 "${f##*/}" > "${f##*/}.sha256")
done

gh release create "$tag" dist/*.dmg dist/*.sha256 \
  --target "$sha" \
  --prerelease \
  --title "Nightly" \
  --notes-file notes.md

# Keep only the newest nightlies.
nightlies | tail -n +"$((KEEP_NIGHTLIES + 1))" | while read -r old; do
  [ -n "$old" ] && gh release delete "$old" --yes || true
done
