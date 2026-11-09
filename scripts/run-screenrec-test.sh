#!/bin/bash
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

# End-to-end test of the shipped ScreenCaptureKit recorder. Artifacts are retained.
set -eu
cd "$(dirname "$0")/.."
ci=false
case "${1:-}" in --ci) ci=true ;; "") ;; *) echo "Usage: $0 [--ci]" >&2; exit 2 ;; esac
if [ "${GITHUB_ACTIONS:-}" = true ]; then ci=true; fi
work="$PWD/build/screenrec-test/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$work"
echo "Screen recording test artifacts: $work"
exec > >(tee "$work/driver.log") 2>&1
player_pid=""
record_seconds=12.5
recorder_timeout=53 # ceil(record_seconds + 40)

# Snapshot descendants before TERM, since they may be reparented afterwards.
process_tree() {
    local pid=$1 child
    for child in $(pgrep -P "$pid" 2>/dev/null || true); do
        process_tree "$child"
    done
    echo "$pid"
}

stop_player() {
    [ -n "$player_pid" ] || return 0
    local targets
    targets=$(process_tree "$player_pid")
    kill -TERM $targets 2>/dev/null || true
    sleep 2
    kill -KILL $targets 2>/dev/null || true
    wait "$player_pid" 2>/dev/null || true
    player_pid=""
}

run_with_timeout() {
    local seconds=$1
    shift
    local step=$1 pid timer code=0 marker targets
    "$@" <&0 &
    pid=$!
    marker="$work/timeout-$pid"
    echo "$pid" > "$work/active-$pid"
    (
        sleeper=""
        trap '[ -z "$sleeper" ] || kill "$sleeper" 2>/dev/null; exit 0' TERM INT
        sleep "$seconds" &
        sleeper=$!
        wait "$sleeper" || exit 0
        sleeper=""
        echo "TIMEOUT: $step after ${seconds}s" >&2
        touch "$marker" "$work/timed-out"
        targets=$(process_tree "$pid")
        echo "$targets" > "$work/active-$pid"
        kill -TERM $targets 2>/dev/null || true
        sleep 2 &
        sleeper=$!
        wait "$sleeper" || true
        sleeper=""
        kill -KILL $targets 2>/dev/null || true
    ) &
    timer=$!
    echo "$timer" > "$work/active-$timer"
    wait "$pid" || code=$?
    # make-clip's own watchdog exits before this outer deadline.
    if [ "${step##*/}" = make-clip ] && [ "$code" -eq 3 ]; then
        echo "TIMEOUT: $step (internal watchdog)" >&2
        touch "$marker" "$work/timed-out"
        kill -TERM "$timer" 2>/dev/null || true
    fi
    if [ -f "$marker" ]; then
        wait "$timer" || true
        code=124
    else
        # The timer trap also kills its sleep, including in command substitutions.
        kill -TERM "$timer" 2>/dev/null || true
        wait "$timer" 2>/dev/null || true
    fi
    rm -f "$work/active-$pid" "$work/active-$timer" "$marker"
    return "$code"
}

finish() {
    local code=$?
    set +e # Diagnostics must never prevent helper cleanup.
    trap - EXIT
    if [ "$code" -eq 124 ] || [ -f "$work/timed-out" ]; then code=30; fi
    if [ "$code" -ne 0 ]; then
        echo "== Failure diagnostics: artifact sizes"
        find "$work" -type f -exec ls -lh {} +
        echo "== Helper processes before cleanup"
        ps -axo pid,ppid,etime,command | grep -E 'make-clip|play-clip|audio-device|MacPocketKnife|screenrec|/verify' || true
        for log in "$work"/*.log; do
            [ -f "$log" ] || continue
            echo "== Tail: $log"
            tail -n 60 "$log"
        done
    fi
    # PID files also cover helpers launched inside the background player wrapper.
    local entry pid targets=""
    for entry in "$work"/active-*; do
        [ -f "$entry" ] || continue
        for pid in $(cat "$entry"); do
            targets="$targets $(process_tree "$pid")"
        done
    done
    if [ -n "$player_pid" ]; then targets="$targets $(process_tree "$player_pid")"; fi
    if [ -n "$targets" ]; then
        kill -TERM $targets 2>/dev/null || true
        sleep 2
        kill -KILL $targets 2>/dev/null || true
    fi
    rm -f "$work"/active-*
    echo "Screen recording test exit: $code; artifacts: $work"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        {
            echo '### Screen recording test'
            echo "Exit: $code. Artifacts: screenrec-test."
            echo '```text'
            for log in "$work"/verify-*.log; do
                if [ -f "$log" ]; then cat "$log"; fi
            done
            echo '```'
        } >> "$GITHUB_STEP_SUMMARY"
    fi
    exit "$code"
}
trap finish EXIT
trap 'exit 130' INT TERM

if $ci; then
    run_with_timeout 15 sw_vers || true
    run_with_timeout 30 system_profiler SPDisplaysDataType || true
    run_with_timeout 30 system_profiler SPAudioDataType || true
    run_with_timeout 15 csrutil status || true
    pgrep -fl WindowServer || true
fi

run_with_timeout 180 swift build
binary_dir="$(run_with_timeout 30 swift build --show-bin-path)"
# Keep a stable bundle path and identity so local authorization survives reruns.
app="$PWD/build/ScreenRecTest.app"
bundle_id=io.github.fperdigon.macpocketknife.screenrectest
mkdir -p "$app/Contents/MacOS"
cp "$binary_dir/MacPocketKnife" "$app/Contents/MacOS/MacPocketKnife"
run_with_timeout 15 python3 - "$app/Contents/Info.plist" "$bundle_id" <<'PLIST'
import pathlib, plistlib, sys
info = plistlib.loads(pathlib.Path("Resources/Info.plist").read_bytes())
info.update(CFBundleIdentifier=sys.argv[2], CFBundleName="ScreenRecTest",
            CFBundleDisplayName="ScreenRecTest", CFBundleShortVersionString="0.0.0",
            CFBundleVersion="0.0.0", CAMGitSHA="unknown", CAMBuildChannel="dev")
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps(info))
PLIST
run_with_timeout 30 codesign --force --sign - "$app"
player="$work/ClipPlayer.app"
mkdir -p "$player/Contents/MacOS"
run_with_timeout 15 python3 - "$player/Contents/Info.plist" <<'PLIST'
import pathlib, plistlib, sys
info = dict(CFBundleIdentifier="io.github.fperdigon.macpocketknife.clipplayer",
            CFBundleExecutable="play-clip", CFBundleName="ClipPlayer",
            CFBundlePackageType="APPL", LSUIElement=True, LSMinimumSystemVersion="13.0")
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps(info))
PLIST
for source in make-clip verify audio-device; do
    run_with_timeout 90 swiftc -swift-version 6 -target "$(uname -m)-apple-macosx13.0" scripts/screenrec/"$source.swift" -o "$work/$source"
done
run_with_timeout 90 swiftc -swift-version 6 -target "$(uname -m)-apple-macosx13.0" scripts/screenrec/play-clip.swift -o "$player/Contents/MacOS/play-clip"
run_with_timeout 30 codesign --force --sign - "$player"
run_with_timeout 60 "$work/make-clip" "$work/reference.mp4" > "$work/make-reference.log" 2>&1
run_with_timeout 90 "$work/verify" --selftest > "$work/verifier-selftest.log" 2>&1
cat "$work/verifier-selftest.log"
run_with_timeout 90 "$work/verify" "$work/reference.mp4" "$work/reference.mp4" --seconds 12 > "$work/reference-check.log" 2>&1
cat "$work/reference-check.log"
for control in silent shuffled; do
    run_with_timeout 60 "$work/make-clip" "$work/$control.mp4" "--$control" > "$work/make-$control.log" 2>&1
    control_code=0
    run_with_timeout 90 "$work/verify" "$work/reference.mp4" "$work/$control.mp4" --seconds 12 > "$work/$control-check.log" 2>&1 || control_code=$?
    if [ "$control_code" -eq 124 ]; then exit 30; fi
    if [ "$control_code" -eq 0 ]; then
        echo "FAIL negative control unexpectedly passed: $control"
        exit 1
    fi
    cat "$work/$control-check.log"
    # A crash or reader error is not a successful negative control.
    if [ "$control" = silent ]; then
        grep -q '^FAIL audio is not silent' "$work/$control-check.log"
    else
        grep -q '^FAIL video ordered slots=' "$work/$control-check.log"
        grep -q '^FAIL audio ordered slots=' "$work/$control-check.log"
    fi
    echo "PASS rejected $control negative control"
done

no_output=false
audio_code=0
run_with_timeout 15 "$work/audio-device" > "$work/audio-device.log" 2>&1 || audio_code=$?
cat "$work/audio-device.log"
if [ "$audio_code" -eq 124 ]; then exit 30; fi
if [ "$audio_code" -ne 0 ]; then no_output=true; fi

# Disposable CI runners only. Called exclusively after exit 10 from preflight.
grant_screen_capture_on_runner() {
    $ci || return 1
    local db="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
    local system_db="/Library/Application Support/com.apple.TCC/TCC.db"
    local sql="INSERT OR REPLACE INTO access(service,client,client_type,auth_value,auth_reason,auth_version,flags,last_modified) VALUES('kTCCServiceScreenCapture','$bundle_id',0,2,4,1,0,strftime('%s','now'));"
    echo "Granting ScreenCapture to $bundle_id on disposable CI runner"
    if ! run_with_timeout 15 sqlite3 "$db" "$sql"; then
        run_with_timeout 15 sudo sqlite3 "$system_db" "$sql" || return 1
    fi
    killall tccd 2>/dev/null || true
    sleep 2
}

# Optional CI experiment, isolated here for easy removal. This is the sole external
# dependency fallback; generation, playback, recording and analysis use Apple APIs.
install_runner_audio() {
    $ci || return 1
    echo "Trying a BlackHole virtual output on the disposable runner"
    if ! run_with_timeout 120 brew install --cask blackhole-2ch; then
        run_with_timeout 120 brew install blackhole-2ch || return 1
    fi
    run_with_timeout 15 sudo killall coreaudiod || true
    sleep 3
    run_with_timeout 15 "$work/audio-device" --select-blackhole > "$work/audio-device-blackhole.log" 2>&1 || return 1
    run_with_timeout 30 system_profiler SPAudioDataType || true
}

attempt=0
run_attempt() {
    attempt=$((attempt + 1))
    local recording="$work/recording-$attempt.mp4" code=0
    echo "== Capture attempt $attempt"
    run_with_timeout 42 "$player/Contents/MacOS/play-clip" "$work/reference.mp4" > "$work/player-$attempt.log" 2>&1 &
    player_pid=$!
    # Wait for advancing media time, rather than assuming process launch means playback.
    local tick=0
    until grep -q '^PLAYBACK_STARTED ' "$work/player-$attempt.log"; do
        if ! kill -0 "$player_pid" 2>/dev/null || [ "$tick" -ge 100 ]; then
            cat "$work/player-$attempt.log"
            echo "FAIL player did not start"
            stop_player
            return 1
        fi
        sleep 0.1
        tick=$((tick + 1))
    done
    cat "$work/player-$attempt.log"
    sleep 1
    run_with_timeout "$recorder_timeout" "$app/Contents/MacOS/MacPocketKnife" \
        --record-selftest "$recording" "$record_seconds" > "$work/recorder-$attempt.log" 2>&1 || code=$?
    cat "$work/recorder-$attempt.log"
    if [ "$code" -ne 0 ]; then
        stop_player
        return "$code"
    fi
    wait "$player_pid" || code=$?
    player_pid=""
    if [ "$code" -ne 0 ]; then cat "$work/player-$attempt.log"; return "$code"; fi
    run_with_timeout 90 "$work/verify" "$work/reference.mp4" "$recording" --seconds "$record_seconds" \
        --frames "$work/frames-$attempt" > "$work/verify-$attempt.log" 2>&1 || code=$?
    cat "$work/verify-$attempt.log"
    return "$code"
}

# Each mutation is attempted at most once, regardless of whether missing audio or
# permission is encountered first. All retries replay the clip from the beginning.
permission_retried=false
audio_retried=false
code=0
while true; do
    code=0
    run_attempt || code=$?
    if [ "$code" -eq 124 ] || [ -f "$work/timed-out" ]; then exit 30; fi
    if [ "$code" -eq 0 ]; then break; fi
    if [ "$code" -eq 10 ] && $ci && ! $permission_retried; then
        permission_retried=true
        if grant_screen_capture_on_runner; then
            [ ! -f "$work/timed-out" ] || exit 30
            continue
        fi
    fi
    silent=false
    if [ -f "$work/verify-$attempt.log" ] && grep -q '^AUDIO_NOT_CAPTURED' "$work/verify-$attempt.log"; then silent=true; fi
    if [ "$code" -ne 10 ] && $ci && ! $audio_retried && { $no_output || $silent; }; then
        audio_retried=true
        if install_runner_audio; then
            [ ! -f "$work/timed-out" ] || exit 30
            no_output=false
            continue
        fi
    fi
    break
done
if [ -f "$work/timed-out" ]; then exit 30; fi
if [ "$code" -ne 0 ]; then
    if [ "$code" -ne 10 ] && { $no_output || { [ -f "$work/verify-$attempt.log" ] && grep -q '^AUDIO_NOT_CAPTURED' "$work/verify-$attempt.log"; }; }; then
        if $no_output; then
            echo "AUDIO NOT CAPTURED (runner has no audio device)"
        else
            echo "AUDIO NOT CAPTURED (system audio is silent despite an output device)"
        fi
        exit 20
    fi
    echo "FAIL screen recording test (exit $code)"
    exit "$code"
fi
echo "PASS screen recording video, system audio, ordered correlation and A/V sync"
