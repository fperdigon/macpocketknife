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

# Builds a universal, ad-hoc signed (sealed), unnotarized app and DMG.
set -euo pipefail
cd "$(dirname "$0")/.."
version="$(cat VERSION)"
# Always seal with an ad-hoc signature; no Developer ID or notarization service.
SIGN_IDENTITY="${SIGN_IDENTITY:--}" sh scripts/make-app-bundle.sh "$@"
app='build/MacPocketKnife.app'
dmg="dist/MacPocketKnife-${version}.dmg"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p dist
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
# Leave enough space for filesystem overhead on newer macOS versions.
size_mb="$(( $(du -sk "$app" | cut -f1) / 1024 + 64 ))"
hdiutil create -volname 'MacPocketKnife' -srcfolder "$stage" \
    -ov -fs HFS+ -size "${size_mb}m" -format UDZO "$dmg"
scripts/verify-dmg.sh "$dmg"
(cd dist && shasum -a 256 "${dmg##*/}" > "${dmg##*/}.sha256")
printf 'Built and verified %s\n' "$dmg"
