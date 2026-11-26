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

# Prints the SHA-1 hash of the "MacPocketKnife Signing" certificate in the default keychain
# search list, or nothing when there is none. The certificate is self-signed and untrusted, so
# it does not appear in `find-identity -v`; expired certificates are skipped.
set -eu
name=${SIGNING_CERT_CN:-MacPocketKnife Signing}
security find-identity -p codesigning 2>/dev/null \
    | grep -F "\"$name\"" \
    | grep -v 'CERT_EXPIRED' \
    | sed -nE 's/^[[:space:]]*[0-9]+\) ([0-9A-Fa-f]{40}) ".*/\1/p' \
    | sed -n 1p || true
