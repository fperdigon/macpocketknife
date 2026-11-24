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

# Run with: sh scripts/test-scan-secrets.sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' 0
trap 'exit 1' HUP INT TERM
mkdir -p "$test_root/scripts"
cp "$script_dir/scan-secrets.sh" "$test_root/scripts/scan-secrets.sh"
printf '%s\n' '# Exact test placeholders only.' > "$test_root/scripts/secret-allowlist.txt"
cd "$test_root"
git init -q
git add scripts

scan() {
    sh scripts/scan-secrets.sh
}

expect_rejection() {
    result=0
    scan > scan-output 2>&1 || result=$?
    if [ "$result" -ne 1 ]; then
        printf '%s\n' 'Expected the planted secret to be rejected.' >&2
        exit 1
    fi
    if grep -F -q -e "$token" scan-output; then
        printf '%s\n' 'Scanner printed a secret.' >&2
        exit 1
    fi
}

scan
# Assemble all credential-shaped strings at runtime; none are stored in this test source.
token=$(printf '%s:%s' '123456789' 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi')
printf '%s\n' "$token" > 'test fixture.txt'
scan # Untracked content is outside the scanner scope.
git add 'test fixture.txt'
: > scripts/secret-allowlist.txt
expect_rejection # An empty allowlist must still reject secrets.
printf '%s\n' "$token" >> scripts/secret-allowlist.txt
scan # Only the exact explicitly allowlisted value may pass.
printf '%s %sX\n' "$token" "$token" > 'test fixture.txt'
expect_rejection # A different value on the same line must still fail.

bearer_prefix='Bearer '
printf '%s%s\n' "$bearer_prefix" 'test-credential' > 'test fixture.txt'
expect_rejection
printf '%s%s\n' 'bEaReR ' 'test-credential' > 'test fixture.txt'
expect_rejection
for kind in '' 'RSA ' 'EC ' 'OPENSSH ' 'ENCRYPTED '; do
    printf '%s%s%s\n' '-----BEGIN ' "$kind" 'PRIVATE KEY-----' > 'test fixture.txt'
    expect_rejection
done
# Other credential shapes, each built from fragments at runtime.
rep() { # rep CHAR COUNT
    awk -v c="$1" -v n="$2" 'BEGIN { for (i = 0; i < n; i++) printf "%s", c; printf "\n" }'
}
alnum36=$(rep 'a1' 18)
check_shape() {
    printf '%s\n' "$token" > 'test fixture.txt'
    expect_rejection
}
for prefix in 'gh''p_' 'gh''o_' 'gh''s_' 'gh''u_' 'gh''r_'; do
    token="$prefix$alnum36"; check_shape
done
token="github""_pat_$(rep 'Ab3' 10)"; check_shape
token="AK""IA$(rep 'Q7' 8)"; check_shape
token="xo""xb-123456789012-$(rep 'z9' 6)"; check_shape
token="AI""za$(rep 'Xy_' 12)"; check_shape
token="ey""J$(rep 'a1' 6).ey""J$(rep 'b2' 6).$(rep 'c3' 8)"; check_shape
# Near misses must stay clean.
token='ghp_short'
printf '%s\n' "$token" 'AKIA-too-short' 'eyJ.only.two' > 'test fixture.txt'
scan
printf '%s\n' 'Battery at 50%; sleep is blocked.' > 'test fixture.txt'
scan
printf '%s\n' 'Secret scanner tests passed.'
