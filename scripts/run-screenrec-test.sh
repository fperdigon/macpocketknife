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
finish() {
    local code=$?
    if [ -n "$player_pid" ]; then kill "$player_pid" 2>/dev/null || true; fi
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
}
trap finish EXIT
trap 'exit 130' INT TERM

if $ci; then
    sw_vers || true
    system_profiler SPDisplaysDataType || true
    system_profiler SPAudioDataType || true
    csrutil status || true
    pgrep -fl WindowServer || true
fi

swift build
binary_dir="$(swift build --show-bin-path)"
# Keep a stable bundle path and identity so local authorization survives reruns.
app="$PWD/build/ScreenRecTest.app"
bundle_id=io.github.fperdigon.macpocketknife.screenrectest
mkdir -p "$app/Contents/MacOS"
cp "$binary_dir/MacPocketKnife" "$app/Contents/MacOS/MacPocketKnife"
python3 - "$app/Contents/Info.plist" "$bundle_id" <<'PLIST'
import pathlib, plistlib, sys
info = plistlib.loads(pathlib.Path("Resources/Info.plist").read_bytes())
info.update(CFBundleIdentifier=sys.argv[2], CFBundleName="ScreenRecTest",
            CFBundleDisplayName="ScreenRecTest", CFBundleShortVersionString="0.0.0",
            CFBundleVersion="0.0.0", CAMGitSHA="unknown", CAMBuildChannel="dev")
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps(info))
PLIST
codesign --force --sign - "$app"
player="$work/ClipPlayer.app"
mkdir -p "$player/Contents/MacOS"
python3 - "$player/Contents/Info.plist" <<'PLIST'
import pathlib, plistlib, sys
info = dict(CFBundleIdentifier="io.github.fperdigon.macpocketknife.clipplayer",
            CFBundleExecutable="play-clip", CFBundleName="ClipPlayer",
            CFBundlePackageType="APPL", LSUIElement=True, LSMinimumSystemVersion="13.0")
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps(info))
PLIST
for source in make-clip verify audio-device; do
    swiftc -swift-version 6 -target "$(uname -m)-apple-macosx13.0" scripts/screenrec/"$source.swift" -o "$work/$source"
done
swiftc -swift-version 6 -target "$(uname -m)-apple-macosx13.0" scripts/screenrec/play-clip.swift -o "$player/Contents/MacOS/play-clip"
codesign --force --sign - "$player"
"$work/make-clip" "$work/reference.mp4"
"$work/verify" --selftest > "$work/verifier-selftest.log"
cat "$work/verifier-selftest.log"
"$work/verify" "$work/reference.mp4" "$work/reference.mp4" --seconds 12 > "$work/reference-check.log"
cat "$work/reference-check.log"
for control in silent shuffled; do
    "$work/make-clip" "$work/$control.mp4" "--$control"
    if "$work/verify" "$work/reference.mp4" "$work/$control.mp4" --seconds 12 > "$work/$control-check.log"; then
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
if ! "$work/audio-device"; then no_output=true; fi

# Disposable CI runners only. Called exclusively after exit 10 from preflight.
grant_screen_capture_on_runner() {
    $ci || return 1
    local db="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
    local system_db="/Library/Application Support/com.apple.TCC/TCC.db"
    local sql="INSERT OR REPLACE INTO access(service,client,client_type,auth_value,auth_reason,auth_version,flags,last_modified) VALUES('kTCCServiceScreenCapture','$bundle_id',0,2,4,1,0,strftime('%s','now'));"
    echo "Granting ScreenCapture to $bundle_id on disposable CI runner"
    if ! sqlite3 "$db" "$sql"; then
        sudo sqlite3 "$system_db" "$sql" || return 1
    fi
    killall tccd 2>/dev/null || true
    sleep 2
}

# Optional CI experiment, isolated here for easy removal. This is the sole external
# dependency fallback; generation, playback, recording and analysis use Apple APIs.
install_runner_audio() {
    $ci || return 1
    echo "Trying a BlackHole virtual output on the disposable runner"
    if ! brew install --cask blackhole-2ch; then
        brew install blackhole-2ch || return 1
    fi
    sudo killall coreaudiod || true
    sleep 3
    "$work/audio-device" --select-blackhole || return 1
    system_profiler SPAudioDataType || true
}

attempt=0
run_attempt() {
    attempt=$((attempt + 1))
    local recording="$work/recording-$attempt.mp4" code=0
    echo "== Capture attempt $attempt"
    "$player/Contents/MacOS/play-clip" "$work/reference.mp4" > "$work/player-$attempt.log" 2>&1 &
    player_pid=$!
    # Wait for advancing media time, rather than assuming process launch means playback.
    local tick=0
    until grep -q '^PLAYBACK_STARTED ' "$work/player-$attempt.log"; do
        if ! kill -0 "$player_pid" 2>/dev/null || [ "$tick" -ge 100 ]; then
            cat "$work/player-$attempt.log"
            echo "FAIL player did not start"
            kill "$player_pid" 2>/dev/null || true
            wait "$player_pid" 2>/dev/null || true
            player_pid=""
            return 1
        fi
        sleep 0.1
        tick=$((tick + 1))
    done
    cat "$work/player-$attempt.log"
    sleep 1
    python3 - "$app/Contents/MacOS/MacPocketKnife" "$recording" "$record_seconds" > "$work/recorder-$attempt.log" 2>&1 <<'RECORD'
import subprocess, sys
try:
    result = subprocess.run([sys.argv[1], "--record-selftest", sys.argv[2], sys.argv[3]], timeout=40)
    sys.exit(result.returncode if result.returncode >= 0 else 1)
except subprocess.TimeoutExpired:
    print("FAIL recorder timed out", flush=True)
    sys.exit(1)
RECORD
    code=$?
    cat "$work/recorder-$attempt.log"
    if [ "$code" -ne 0 ]; then
        kill "$player_pid" 2>/dev/null || true
        wait "$player_pid" 2>/dev/null || true
        player_pid=""
        return "$code"
    fi
    wait "$player_pid" || code=$?
    player_pid=""
    if [ "$code" -ne 0 ]; then cat "$work/player-$attempt.log"; return "$code"; fi
    "$work/verify" "$work/reference.mp4" "$recording" --seconds "$record_seconds" \
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
    if [ "$code" -eq 0 ]; then break; fi
    if [ "$code" -eq 10 ] && $ci && ! $permission_retried; then
        permission_retried=true
        if grant_screen_capture_on_runner; then continue; fi
    fi
    silent=false
    if [ -f "$work/verify-$attempt.log" ] && grep -q '^AUDIO_NOT_CAPTURED' "$work/verify-$attempt.log"; then silent=true; fi
    if [ "$code" -ne 10 ] && $ci && ! $audio_retried && { $no_output || $silent; }; then
        audio_retried=true
        if install_runner_audio; then
            no_output=false
            continue
        fi
    fi
    break
done
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
