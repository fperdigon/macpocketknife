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

# Verify a download without launching it. Each image is mounted read-only.
# Set EXPECT_SIGNED_IDENTITY to a certificate name to also require that the app is signed by it.
set -uo pipefail
[ "$#" -ge 1 ] || { echo "usage: $0 file.dmg [file.dmg ...]" >&2; exit 2; }

# A subshell gives each image its own EXIT trap, including early failures/signals.
verify_one() (
    set -euo pipefail
    dmg="$1"
    fail() { echo "FAIL: $*" >&2; exit 1; }
    [ -f "$dmg" ] || fail 'file not found'
    hdiutil verify "$dmg" >/dev/null || fail 'image checksum is invalid'
    work="$(mktemp -d)"
    mnt="$work/mnt"
    mkdir "$mnt"
    attached=false
    cleanup() {
        status=$?
        trap - EXIT
        if [ "$attached" = true ]; then
            if ! hdiutil detach "$mnt" -quiet; then
                echo 'FAIL: could not unmount image' >&2
                # Retain the mount directory if detach fails; never delete a mounted tree.
                exit 1
            fi
        fi
        rm -rf "$work"
        exit "$status"
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mnt" >/dev/null || fail 'could not attach image'
    attached=true
    shopt -s nullglob
    apps=("$mnt/"*.app)
    [ "${#apps[@]}" -eq 1 ] || fail 'expected exactly one app'
    app="${apps[0]}"
    [ "${app##*/}" = 'MacPocketKnife.app' ] || fail 'unexpected app name'
    [ -L "$mnt/Applications" ] && [ "$(readlink "$mnt/Applications")" = /Applications ] || fail 'no Applications -> /Applications symlink'
    plist="$app/Contents/Info.plist"
    [ -d "$app/Contents/Resources" ] || fail 'missing Resources directory'
    plutil -lint "$plist" >/dev/null || fail 'invalid Info.plist'
    key() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist"; }
    [ "$(key CFBundleIdentifier)" = io.github.fperdigon.macpocketknife ] || fail 'unexpected bundle identifier'
    [ "$(key CFBundlePackageType)" = APPL ] || fail 'invalid package type'
    [ -n "$(key CFBundleShortVersionString)" ] || fail 'missing version'
    [ "$(key LSUIElement)" = true ] || fail 'LSUIElement must be true'
    [ "$(key CFBundleExecutable)" = MacPocketKnife ] || fail 'unexpected executable name'
    exe="$app/Contents/MacOS/MacPocketKnife"
    [ -x "$exe" ] || fail 'missing executable or executable bit'
    for architecture in arm64 x86_64; do
        lipo "$exe" -verify_arch "$architecture" || fail "missing $architecture architecture"
    done
    codesign --verify --deep --strict "$app" || fail 'invalid code signature'
    entitlements=$(codesign -d --entitlements - --xml "$app" 2>&1) || fail 'could not read code signature entitlements'
    printf '%s\n' "$entitlements" | grep -Fq '<key>com.apple.security.device.audio-input</key>' || fail 'missing microphone entitlement'
    if [ -n "${EXPECT_SIGNED_IDENTITY:-}" ]; then
        # The release certificate is self-signed, so the leaf is the first Authority line.
        details=$(codesign -dvv "$app" 2>&1) || fail 'could not read code signature details'
        printf '%s\n' "$details" | grep -Fxq 'Signature=adhoc' && fail 'expected a certificate signature but the app is ad-hoc signed'
        leaf=$(printf '%s\n' "$details" | sed -n 's/^Authority=//p' | awk 'NR == 1')
        [ "$leaf" = "$EXPECT_SIGNED_IDENTITY" ] || fail "unexpected signing identity (expected $EXPECT_SIGNED_IDENTITY, found ${leaf:-none})"
    fi
    echo 'PASS: bundle structure, universal executable, whole-bundle signature and microphone entitlement'
)
failures=0
for dmg in "$@"; do
    verify_one "$dmg" || failures=$((failures + 1))
done
[ "$failures" -eq 0 ] || { echo "$failures image(s) failed." >&2; exit 1; }
echo 'All checks passed.'
