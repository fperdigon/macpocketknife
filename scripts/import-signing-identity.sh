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

# CI helper: import the release signing certificate into a temporary keychain.
#
# Inputs (environment only, never arguments or output):
#   SIGNING_CERT_P12       base64 of a PKCS#12 file (secret)
#   SIGNING_CERT_PASSWORD  its password (secret)
#   RUNNER_TEMP            directory for the temporary keychain
#   GITHUB_ENV             file that receives SIGN_IDENTITY, EXPECT_SIGNED_IDENTITY, SIGNING_KEYCHAIN
#   SIGNING_CERT_CN        expected certificate name (default "MacPocketKnife Signing")
#
# With neither secret set (forks, missing configuration) it warns and leaves the build ad-hoc
# signed. With only one set, or with any import failure, it fails the job: a build that should be
# signed must never silently fall back to ad-hoc.
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }

p12_b64="${SIGNING_CERT_P12:-}"
p12_password="${SIGNING_CERT_PASSWORD:-}"
expected_cn="${SIGNING_CERT_CN:-MacPocketKnife Signing}"

if [ -z "$p12_b64" ] && [ -z "$p12_password" ]; then
    echo '::warning::Signing secrets are not available; building with an ad-hoc signature. macOS permission grants will not survive updates of this build.'
    exit 0
fi
if [ -z "$p12_b64" ] || [ -z "$p12_password" ]; then
    fail 'Only one of SIGNING_CERT_P12 and SIGNING_CERT_PASSWORD is set; refusing to fall back to an ad-hoc signature.'
fi
[ -n "${RUNNER_TEMP:-}" ] || fail 'RUNNER_TEMP is not set.'
[ -n "${GITHUB_ENV:-}" ] || fail 'GITHUB_ENV is not set.'

keychain="$RUNNER_TEMP/macpocketknife-signing.keychain-db"
p12_file="$RUNNER_TEMP/macpocketknife-signing.p12"
keychain_password="$(openssl rand -hex 24)"
echo "::add-mask::$keychain_password"
# Record the keychain first so the always-run cleanup step can delete it after a partial failure.
echo "SIGNING_KEYCHAIN=$keychain" >> "$GITHUB_ENV"
cleanup_p12() { rm -f "$p12_file"; }
trap cleanup_p12 EXIT

umask 077
printf '%s' "$p12_b64" | base64 --decode > "$p12_file" \
    || fail 'SIGNING_CERT_P12 is not valid base64.'
[ -s "$p12_file" ] || fail 'SIGNING_CERT_P12 decoded to an empty file.'

security create-keychain -p "$keychain_password" "$keychain" \
    || fail 'Could not create the temporary keychain.'
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain" \
    || fail 'Could not unlock the temporary keychain.'
existing="$(security list-keychains -d user | tr -d '"' | tr -s '[:space:]' ' ')"
# shellcheck disable=SC2086 # keychain paths from the runner do not contain spaces.
security list-keychains -d user -s "$keychain" $existing
security default-keychain -d user -s "$keychain"

security import "$p12_file" -k "$keychain" -P "$p12_password" -T /usr/bin/codesign >/dev/null 2>&1 \
    || fail 'Importing the signing certificate failed. Check SIGNING_CERT_P12 and SIGNING_CERT_PASSWORD.'
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null 2>&1 \
    || fail 'Could not authorize codesign to use the imported key.'

# The certificate is self-signed and not trusted, so `find-identity -v` would not list it.
identities="$(security find-identity -p codesigning "$keychain" \
    | grep -E '^[[:space:]]*[0-9]+\) [0-9A-Fa-f]{40} "' || true)"
matching="$(printf '%s\n' "$identities" | grep -F "\"$expected_cn\"" || true)"
[ -n "$matching" ] || fail "No code-signing identity named \"$expected_cn\" was found in the imported certificate."
[ "$(printf '%s\n' "$matching" | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "More than one code-signing identity named \"$expected_cn\" was found."
hash="$(printf '%s\n' "$matching" | awk '{print $2}')"
printf '%s\n' "$hash" | grep -Eq '^[0-9A-Fa-f]{40}$' || fail 'Could not read the signing identity hash.'
echo "::add-mask::$hash"
{
    echo "SIGN_IDENTITY=$hash"
    echo "EXPECT_SIGNED_IDENTITY=$expected_cn"
} >> "$GITHUB_ENV"
echo "Signing identity \"$expected_cn\" imported into a temporary keychain."
