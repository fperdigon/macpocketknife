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

# Feeds the synthetic speech fixtures to Apple's on-device recognizer and checks the
# transcript. English always runs; Spanish runs locally only (CI has no offline Spanish
# model). Usage: scripts/run-speech-test.sh [--ci]
set -u
cd "$(dirname "$0")/.."

ci=false
if [ "${1:-}" = "--ci" ] || [ "${GITHUB_ACTIONS:-}" = "true" ]; then ci=true; fi

bundle_id=io.github.fperdigon.macpocketknife.speechtest
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
app="$work/SpeechTest.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleExecutable</key><string>transcribe</string>
<key>CFBundleName</key><string>SpeechTest</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSSpeechRecognitionUsageDescription</key><string>Test transcription of synthetic audio fixtures on this Mac.</string>
</dict></plist>
PLIST
swiftc scripts/speech/transcribe.swift -o "$app/Contents/MacOS/transcribe" || exit 1
codesign --force --deep -s - --entitlements "$PWD/Resources/MacPocketKnife.entitlements" "$app" || exit 1

# Runs the transcriber as its own app so the permission belongs to this bundle, not the
# launching terminal. Output lands in $work/<name>.out; echoes the exit code.
run_transcribe() {
  local name="$1" locale="$2" file="$3" code
  rm -f "$work/$name.out"
  : > "$work/$name.out"
  "$app/Contents/MacOS/transcribe" "$locale" "$file" > "$work/$name.out" 2>&1
  code=$?
  grep -v "No Assistant asset" "$work/$name.out" | sed "s/^/  [$name] /"
  return $code
}

# CI only (this and enable_dictation_on_runner): the hosted runner is a disposable
# VM with SIP disabled, so the speech permission is granted in its own TCC database.
# Never used on a developer machine.
grant_speech_on_runner() {
  local db="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
  local sql="INSERT OR REPLACE INTO access(service,client,client_type,auth_value,auth_reason,auth_version,flags,last_modified) VALUES('kTCCServiceSpeechRecognition','$bundle_id',0,2,4,1,0,strftime('%s','now'));"
  echo "granting speech recognition to $bundle_id on this disposable runner"
  if [ -f "$db" ] && sqlite3 "$db" ".schema access" >/dev/null 2>&1; then
    sqlite3 "$db" ".schema access" | head -3
    sqlite3 "$db" "$sql" && sqlite3 "$db" "SELECT service,client,auth_value FROM access WHERE client='$bundle_id';"
  else
    local system_db="/Library/Application Support/com.apple.TCC/TCC.db"
    sudo sqlite3 "$system_db" "$sql" && sudo sqlite3 "$system_db" "SELECT service,client,auth_value FROM access WHERE client='$bundle_id';"
  fi
  killall tccd 2>/dev/null
  sleep 2
}

# CI only: the runner has Siri and Dictation disabled (kLSRErrorDomain 201), so turn
# Dictation on for the throwaway runner user. Never used on a developer machine.
enable_dictation_on_runner() {
  echo "enabling Dictation for user $(id -un) on this disposable runner"
  defaults write com.apple.assistant.support "Dictation Enabled" -bool true || true
  defaults write com.apple.assistant.support "Assistant Enabled" -bool true || true
  defaults write com.apple.speech.recognition.AppleSpeechRecognition.prefs DictationIMMasterDictationEnabled -bool true || true
  defaults write com.apple.HIToolbox AppleDictationAutoEnable -bool true || true
  defaults read com.apple.assistant.support "Dictation Enabled" 2>&1 || true
  defaults read com.apple.assistant.support "Assistant Enabled" 2>&1 || true
  defaults read com.apple.speech.recognition.AppleSpeechRecognition.prefs DictationIMMasterDictationEnabled 2>&1 || true
  defaults read com.apple.HIToolbox AppleDictationAutoEnable 2>&1 || true
  killall -u "$(id -un)" assistantd corespeechd speechd siriknowledged 2>/dev/null || true
  sleep 3
}

transcript_of() { sed -n 's/^TRANSCRIPT: //p' "$work/$1.out" | tail -1; }

# check <name> <transcript> <word...>: case- and accent-insensitive containment.
check() {
  local name="$1" text="$2" missing="" word plain
  shift 2
  plain="$(printf '%s' "$text" | python3 -c 'import sys, unicodedata; t = unicodedata.normalize("NFD", sys.stdin.read()); print("".join(c for c in t if not unicodedata.combining(c)).lower())')"
  for word in "$@"; do
    case "$plain" in *"$word"*) ;; *) missing="$missing $word" ;; esac
  done
  if [ -n "$missing" ]; then
    echo "FAIL $name: missing words:$missing"
    echo "     transcript: $text"
    return 1
  fi
  echo "PASS $name: \"$text\""
}

failures=0

echo "== en-US"
run_transcribe en en-US Tests/Fixtures/Speech/dictation-en.m4a
code=$?
if [ $code -ne 0 ] && $ci; then
  echo "first attempt failed (exit $code); retrying after granting the permission and enabling Dictation"
  grant_speech_on_runner
  enable_dictation_on_runner
  run_transcribe en en-US Tests/Fixtures/Speech/dictation-en.m4a
  code=$?
fi
if [ $code -eq 0 ]; then
  check en-US "$(transcript_of en)" battery cpu report || failures=$((failures + 1))
else
  echo "FAIL en-US: transcriber exited with code $code (4 unsupported, 5 not authorized, 3 timeout, 6 error)"
  failures=$((failures + 1))
fi

echo "== es-US"
if $ci; then
  echo "SKIP es-US (local only: the offline Spanish model is not installed on CI runners)"
else
  run_transcribe es es-US Tests/Fixtures/Speech/dictation-es.m4a
  code=$?
  if [ $code -eq 0 ]; then
    check es-US "$(transcript_of es)" bateria procesador compilacion || failures=$((failures + 1))
  elif [ $code -eq 4 ]; then
    echo "SKIP es-US: offline Spanish dictation is unavailable. Enable it in System Settings > Keyboard > Dictation."
  else
    echo "FAIL es-US: transcriber exited with code $code"
    failures=$((failures + 1))
  fi
fi

if [ $failures -ne 0 ]; then echo "speech test FAILED ($failures)"; exit 1; fi
echo "speech test passed"
