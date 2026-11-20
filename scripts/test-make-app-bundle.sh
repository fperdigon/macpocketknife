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

# Integration test: uses Xcode build tools and ad-hoc signing, with no credentials.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
SIGN_IDENTITY=- sh scripts/make-app-bundle.sh "$@"
bundle="$root/build/MacPocketKnife.app"
plist="$bundle/Contents/Info.plist"
[ -d "$bundle/Contents/Resources" ]
[ -x "$bundle/Contents/MacOS/MacPocketKnife" ]
plutil -lint "$plist"

expect_key() {
    actual=$(/usr/libexec/PlistBuddy -c "Print :$1" "$plist")
    if [ "$actual" != "$2" ]; then
        printf '%s\n' "Unexpected Info.plist value for $1." >&2
        exit 1
    fi
}

expect_key CFBundleName 'MacPocketKnife'
expect_key CFBundleDisplayName 'MacPocketKnife'
expect_key CFBundleIdentifier 'io.github.fperdigon.macpocketknife'
expect_key CFBundleExecutable MacPocketKnife
expect_key CFBundlePackageType APPL
expect_key CFBundleShortVersionString "$(cat VERSION)"
expect_key CFBundleVersion "$(cat VERSION)"
expect_key CAMGitSHA "${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || printf unknown)}"
expect_key CAMBuildChannel "${BUILD_CHANNEL:-dev}"
expect_key LSMinimumSystemVersion 13.0
expect_key LSUIElement true
expect_key NSHumanReadableCopyright 'Copyright 2026 Francisco Perdigon Romero and contributors'
for architecture in arm64 x86_64; do
    lipo "$bundle/Contents/MacOS/MacPocketKnife" -verify_arch "$architecture"
done
codesign --verify --deep --strict "$bundle"
entitlements=$(codesign -d --entitlements - --xml "$bundle" 2>&1)
printf '%s\n' "$entitlements" | grep -Fq '<key>com.apple.security.device.audio-input</key>'
signature=$(codesign --display --verbose=4 "$bundle" 2>&1)
printf '%s\n' "$signature" | grep -Fq 'Signature=adhoc'
printf '%s\n' "$signature" | grep -Eq 'flags=.*runtime'
printf '%s\n' 'App bundle tests passed.'
