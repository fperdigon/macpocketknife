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

# Integration test: compare the local runner with the release bundle builder.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
bundle="$root/build/MacPocketKnife.app"

# Both builds reuse Swift's release build cache; no DMG is needed.
BUILD_CHANNEL=dev SIGN_IDENTITY=- sh scripts/make-app-bundle.sh
direct_identifier=$(codesign --display --verbose=4 "$bundle" 2>&1 | sed -n 's/^Identifier=//p')
[ "$direct_identifier" = io.github.fperdigon.macpocketknife ]

# Invalid flags must fail before any build, quit, or launch can happen.
if bash scripts/run-local.sh --invalid-option >/dev/null 2>&1; then
    printf '%s\n' 'run-local.sh accepted an unknown flag.' >&2
    exit 1
fi
bash scripts/run-local.sh --no-launch

resources="$bundle/Contents/Resources"
for resource in AppIcon.icns MenuBarIcon.png MenuBarIcon@2x.png; do
    cmp "Resources/$resource" "$resources/$resource"
done
plist="$bundle/Contents/Info.plist"
[ -x "$bundle/Contents/MacOS/MacPocketKnife" ]
plutil -lint "$plist"

# plutil supplies canonical JSON for a complete key and value comparison.
# Only the three documented template substitutions may change any values.
comparison=$(mktemp -d)
trap 'rm -rf "$comparison"' EXIT HUP INT TERM
plutil -convert json -o "$comparison/template.json" Resources/Info.plist
plutil -convert json -o "$comparison/local.json" "$plist"
build_sha=${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || printf unknown)}
python3 - "$comparison/template.json" "$comparison/local.json" "$(cat VERSION)" "$build_sha" <<'PYTHON'
import json
import sys

with open(sys.argv[1]) as source:
    template = json.load(source)
with open(sys.argv[2]) as source:
    actual = json.load(source)
assert sorted(actual) == sorted(template), "Info.plist keys differ from template"
substitutions = {"@VERSION@": sys.argv[3], "@GIT_SHA@": sys.argv[4], "@BUILD_CHANNEL@": "dev"}
expected = {}
for key, value in template.items():
    if isinstance(value, str):
        for token, replacement in substitutions.items():
            value = value.replace(token, replacement)
    expected[key] = value
assert actual == expected, "Info.plist differs beyond allowed template substitutions"
PYTHON

icon=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$plist")
case "$icon" in
    *.icns) ;;
    *) icon="$icon.icns" ;;
esac
[ -f "$resources/$icon" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")" = MacPocketKnife ]
for architecture in arm64 x86_64; do
    lipo "$bundle/Contents/MacOS/MacPocketKnife" -verify_arch "$architecture"
done
codesign --verify --deep --strict "$bundle"
entitlements=$(codesign -d --entitlements - --xml "$bundle" 2>&1)
printf '%s\n' "$entitlements" | grep -Fq '<key>com.apple.security.device.audio-input</key>'
signature=$(codesign --display --verbose=4 "$bundle" 2>&1)
identifier=$(printf '%s\n' "$signature" | sed -n 's/^Identifier=//p')
[ "$identifier" = "$direct_identifier" ]
printf '%s\n' "$signature" | grep -Fxq 'Signature=adhoc'
printf '%s\n' "$signature" | grep -Eq 'flags=.*runtime'
printf '%s\n' 'Local app bundle tests passed.'
