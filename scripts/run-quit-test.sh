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
sample_log=$(mktemp -t macpocketknife-quit-sample)
pid=
sample_pid=
cleanup() {
    if [ -n "$sample_pid" ]; then
        kill -KILL "$sample_pid" 2>/dev/null || true
        wait "$sample_pid" 2>/dev/null || true
    fi
    if [ -n "$pid" ]; then
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    rm -f "$log" "$sample_log"
}
trap cleanup EXIT HUP INT TERM

sample_main_thread() {
    echo "quit-selftest: sampling main thread (5 second timeout)" >&2
    /usr/bin/sample "$pid" 1 -file "$sample_log" >/dev/null 2>&1 &
    sample_pid=$!
    # macOS does not ship timeout(1). Bound sample, including attaching to the app.
    elapsed=0
    while kill -0 "$sample_pid" 2>/dev/null; do
        if [ "$elapsed" -ge 5 ]; then
            echo "quit-selftest: sample timed out" >&2
            kill -KILL "$sample_pid" 2>/dev/null || true
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    wait "$sample_pid" 2>/dev/null || true
    sample_pid=
    if [ -s "$sample_log" ]; then
        awk '
            /Thread_[[:xdigit:]]+/ {
                if (main) exit
                if ($0 ~ /com[.]apple[.]main-thread/) main = 1
            }
            main { print; found = 1 }
            END { if (!found) print "quit-selftest: no main-thread stack found in sample" }
        ' "$sample_log" >&2
    else
        echo "quit-selftest: sample unavailable or empty" >&2
    fi
}

"$binary" --quit-selftest >"$log" 2>&1 &
pid=$!
seconds=0
while kill -0 "$pid" 2>/dev/null; do
    if [ "$seconds" -ge 15 ]; then
        echo "FAIL: quit-selftest did not exit within 15 seconds (PID $pid)" >&2
        ps -p "$pid" -o pid=,stat=,etime=,comm= >&2 || true
        sample_main_thread
        echo "quit-selftest: app log" >&2
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
