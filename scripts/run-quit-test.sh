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

set -eu

binary=${1:-.build/debug/MacPocketKnife}
if [ ! -x "$binary" ]; then
    echo "FAIL: app executable not found: $binary (run swift build first)" >&2
    exit 1
fi
log=$(mktemp -t macpocketknife-quit)
pid=
cleanup() {
    if [ -n "$pid" ]; then
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    rm -f "$log"
}
trap cleanup EXIT HUP INT TERM
"$binary" --quit-selftest >"$log" 2>&1 &
pid=$!
seconds=0
while kill -0 "$pid" 2>/dev/null; do
    if [ "$seconds" -ge 15 ]; then
        echo "FAIL: quit-selftest did not exit within 15 seconds (PID $pid)" >&2
        ps -p "$pid" -o pid=,stat=,etime=,comm= >&2 || true
        cat "$log" >&2
        exit 1
    fi
    sleep 1
    seconds=$((seconds + 1))
done
status=0
wait "$pid" || status=$?
pid=
cat "$log"
if [ "$status" -ne 0 ]; then
    echo "FAIL: quit-selftest exited with status $status" >&2
    exit 1
fi
echo "PASS: quit-selftest exited with status 0"
