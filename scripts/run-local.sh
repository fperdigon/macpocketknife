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

# Build and launch the same universal release bundle used by releases.
set -euo pipefail
launch=true
for argument in "$@"; do
    case "$argument" in
        --no-launch) launch=false ;;
        *) printf 'Unknown argument: %s\nUsage: %s [--no-launch]\n' "$argument" "$0" >&2; exit 1 ;;
    esac
done
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
# Sign with the stable "MacPocketKnife Signing" identity when it is installed, so local builds
# behave like releases (permission grants survive rebuilds); otherwise sign ad-hoc.
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY=$(sh scripts/find-signing-identity.sh)
fi
SIGN_IDENTITY=${SIGN_IDENTITY:--}
export SIGN_IDENTITY
BUILD_CHANNEL=dev sh scripts/make-app-bundle.sh
bundle="$root/build/MacPocketKnife.app"

# The release bundle ID is OK while running from build/. Never copy this bundle
# into /Applications: it would clash with TCC grants and the updater.
if "$launch"; then
    executable="$bundle/Contents/MacOS/MacPocketKnife"
    # Escape the entire absolute path as an extended regular expression. Match
    # only this executable (optionally followed by arguments), never its name or
    # bundle ID, which are shared with the installed release.
    pattern=$(printf '%s' "$executable" | sed 's/[][\\.^$*+?(){}|]/\\&/g')
    pattern="^${pattern}([[:space:]].*)?$"
    pkill -f -x "$pattern" || [ "$?" -eq 1 ]
    attempts=0
    while pgrep -f -x "$pattern" >/dev/null; do
        if [ "$attempts" -ge 50 ]; then
            pkill -KILL -f -x "$pattern" || [ "$?" -eq 1 ]
            break
        fi
        sleep 0.1
        attempts=$((attempts + 1))
    done
    open "$bundle"
fi
