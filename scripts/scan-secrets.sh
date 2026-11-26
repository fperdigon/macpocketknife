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

# Scan tracked working-tree contents, including staged new files, without printing secrets.
set -eu
LC_ALL=C
export LC_ALL

root=$(git rev-parse --show-toplevel) || exit 2
cd "$root"
allowlist=scripts/secret-allowlist.txt
if [ ! -f "$allowlist" ]; then
    printf '%s\n' 'Secret scanner allowlist is missing.' >&2
    exit 2
fi

# Telegram bot tokens, bearer tokens, PEM private keys, GitHub tokens, AWS access keys,
# Slack tokens, Google API keys and JWTs.
# Certificate and key material must never be committed, whatever it contains.
forbidden=$(git ls-files -- '*.p12' '*.pfx' '*.pem' '*.key' '*.cer' '*.mobileprovision' '*.keychain' '*.keychain-db' '.signing/*' '*/.signing/*') || {
    printf '%s\n' 'Secret scanner could not list tracked files.' >&2
    exit 2
}
if [ -n "$forbidden" ]; then
    printf '%s\n' 'Tracked file with a certificate or key extension (remove it and rotate it if it was real):' >&2
    printf '%s\n' "$forbidden" >&2
    exit 1
fi

pattern='[0-9]{5,}:[A-Za-z0-9_-]{20,}'
pattern="$pattern|Bearer[[:space:]]+[A-Za-z0-9._~+/-]+=*"
pattern="$pattern|-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----"
pattern="$pattern|gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}"
pattern="$pattern|(AKIA|ASIA)[0-9A-Z]{16}"
pattern="$pattern|xox[baprs]-[A-Za-z0-9-]{10,}"
pattern="$pattern|AIza[0-9A-Za-z_-]{35}"
pattern="$pattern|eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"
status=0
matches=$(git grep --no-ext-grep --no-textconv -a -h -o -i -E "$pattern" -- . ':!scripts/scan-secrets.sh') || status=$?
case "$status" in
    0) ;;
    1) exit 0 ;;
    *) printf '%s\n' 'Secret scanner could not read tracked files.' >&2; exit 2 ;;
esac

# Entries are complete, case-sensitive matched values, never patterns or whole-line exclusions.
if printf '%s\n' "$matches" | awk '
    FILENAME == ARGV[1] {
        if ($0 != "" && $0 !~ /^#/) allowed[$0] = 1
        next
    }
    !($0 in allowed) { found = 1 }
    END { exit found ? 1 : 0 }
' "$allowlist" -; then
    exit 0
fi
printf '%s\n' 'Potential secret detected in tracked files. Remove it or explicitly allowlist an exact fake placeholder.' >&2
exit 1
