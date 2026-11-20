#!/bin/sh
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

# Run with: sh scripts/make-app-bundle.sh [Swift build options]
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
version=$(cat VERSION)
if ! printf '%s\n' "$version" | LC_ALL=C grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    printf '%s\n' 'VERSION must contain a numeric major.minor.patch version.' >&2
    exit 1
fi

build_sha=${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || printf unknown)}
if [ "$build_sha" != unknown ] && ! printf '%s\n' "$build_sha" | LC_ALL=C grep -Eq '^[0-9a-fA-F]{40}$'; then
    printf '%s\n' 'Build SHA must be a full 40-character commit SHA or unknown.' >&2
    exit 1
fi
build_channel=${BUILD_CHANNEL:-dev}
case "$build_channel" in
    stable|nightly|dev) ;;
    *) printf '%s\n' 'BUILD_CHANNEL must be stable, nightly or dev.' >&2; exit 1 ;;
esac

# Keep build diagnostics separate so stdout ends with the bundle path.
swift build -c release --arch arm64 --arch x86_64 "$@" >&2
binary_dir=$(swift build -c release --arch arm64 --arch x86_64 "$@" --show-bin-path)
bundle="$root/build/MacPocketKnife.app"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary_dir/MacPocketKnife" "$bundle/Contents/MacOS/MacPocketKnife"
cp Resources/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$bundle/Contents/Resources/"
chmod 755 "$bundle/Contents/MacOS/MacPocketKnife"
sed -e "s/@VERSION@/$version/g" -e "s/@GIT_SHA@/$build_sha/g" \
    -e "s/@BUILD_CHANNEL@/$build_channel/g" Resources/Info.plist > "$bundle/Contents/Info.plist"
plutil -lint "$bundle/Contents/Info.plist" >&2
plutil -lint "$root/Resources/MacPocketKnife.entitlements" >&2

identity=${SIGN_IDENTITY:--}
if [ "$identity" = '-' ]; then
    codesign --force --sign - --options runtime \
        --entitlements "$root/Resources/MacPocketKnife.entitlements" "$bundle" >&2
else
    codesign --force --sign "$identity" --options runtime --timestamp \
        --entitlements "$root/Resources/MacPocketKnife.entitlements" "$bundle" >&2
fi
codesign --verify --deep --strict "$bundle" >&2
printf '%s\n' "$bundle"
