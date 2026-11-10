# Contributing

Use English for code, comments, documentation, issues, and pull requests.
Keep changes focused on one issue and explain the resulting behavior.

## Build and test

Use macOS 13 or later with a Swift 6 toolchain. No external dependencies are
required. Run these commands from the repository root:

```sh
swift build
swift test
sh scripts/check-license-headers.sh
sh scripts/test-check-license-headers.sh
sh scripts/scan-secrets.sh
sh scripts/test-scan-secrets.sh
```

If the environment blocks SwiftPM's build sandbox, use `--disable-sandbox` with
`swift build` and `swift test`. The existing Keychain integration test is skipped
when `CI` is set; use `CI=1 swift test` to avoid accessing the real Keychain.

Run `swift run MacPocketKnife --print-status` to print the current status line once and exit.
Run `swift run MacPocketKnife --show-settings` to open Settings immediately after launch.
Run `swift run MacPocketKnife --snapshot-settings <directory>` to save PNG snapshots of every Settings tab and exit.

## macOS integration tests

`MacPocketKnifeIntegrationTests` runs real caffeinate processes, pseudo-terminal
shells, and IOKit sleep assertions with fake battery state and policy time. Run it
with `swift test --filter MacPocketKnifeIntegrationTests` (or as part of
`swift test`). It needs no display or network. The suite skips when `forkpty` or
pseudo-terminals are unavailable; the direct-spawn scenario additionally requires
a runner without a controlling terminal, as on macOS CI. Each test scopes assertion
listings to its own processes and tears down its children and sleep assertions.
Bounded OS-readiness polling does not drive policy time.

## Speech tests

Run `scripts/run-speech-test.sh` to feed the synthetic clips in
`Tests/Fixtures/Speech` to Apple's on-device recognizer and check the transcripts.
The first run shows the macOS Speech Recognition prompt once. The Spanish case needs
offline Spanish dictation (System Settings > Keyboard > Dictation); without it the
case is skipped with a hint. In CI only English runs, because the runner has no
offline Spanish model. CI turns on Dictation for the throwaway runner user because
the runner has it disabled. The test exercises the recognizer on synthetic audio and does
not cover the microphone, hotkey or clipboard path.

## Screen recording tests

Core tests use display, recorder factory, and picker fakes to cover target
resolution, settings migration, collision-safe filenames, cancellation, and
multiple streams without screen permissions. Run `swift test --enable-code-coverage`
for coverage. In a GUI session, also verify two connected displays, unplugging
one while recording, the macOS 14+ preview picker's selection/cancel paths and
cleanup, and the macOS 13 fallback. These hardware/UI checks are manual.

Run `scripts/run-screenrec-test.sh` in a logged-in GUI session. It plays sound and
flashes full-screen colours for about 15 seconds per attempt. Keep the Mac awake
and unlocked, with an audio output device selected. The first run exits with
`PERMISSION DENIED` (code 10) if access is missing. Enable ScreenRecTest in System
Settings > Privacy & Security > Screen & System Audio Recording (use + and pick
`build/ScreenRecTest.app` if it is not listed), then rerun. Local runs launch through
LaunchServices so permission belongs to the bundle. The grant is tied to the exact
build. After code changes, run
`tccutil reset ScreenCapture io.github.fperdigon.macpocketknife.screenrectest`,
re-add `build/ScreenRecTest.app`, and allow the one-time macOS consent dialog before
rerunning the test; otherwise the dialog covers the screen and fails the colour
check. The test never grants
permission or changes audio devices locally. Run `scripts/run-screenrec-test.sh --mic` locally on macOS 15+ to include the
microphone and require exactly one mixed audio track while retaining the system
tone ordering and A/V sync checks. This mode requires microphone permission and
fails if capture falls back without it. It cannot be combined with CI mode.
The default end-to-end test checks system audio without a microphone.

The test generates a deterministic 12-second H.264/AAC clip with twelve unique
colour/tone pairs and short silent gaps. A synthetic clip is deliberately preferred
over downloading a video: it is offline, reproducible, and has precisely aligned
video and audio boundaries. A separate bundled AVPlayer app plays it while the
shipped `ScreenCaptureKitRecorder.start(configuration:destination:display:content:)` / `stop()`
path records the main display. No product settings are read or changed.

The verifier requires video and audio tracks, non-silent PCM, matching durations,
at least five ordered reference colours and tones (at least 85% of observed
slots), and at least four matching boundaries with less than 300 ms A/V offset.
It reports sequences, RMS/peak, durations, and mean/max sync error. All media,
logs, and sample PNG frames remain in the printed `build/screenrec-test/` directory.
The analysis can be checked independently without permission or full-screen playback:

```sh
swiftc -swift-version 6 scripts/screenrec/make-clip.swift -o /tmp/make-clip
swiftc -swift-version 6 scripts/screenrec/verify.swift -o /tmp/verify
/tmp/make-clip /tmp/reference.mp4
/tmp/verify --selftest
/tmp/verify /tmp/reference.mp4 /tmp/reference.mp4 --seconds 12
/tmp/make-clip /tmp/silent.mp4 --silent
/tmp/verify /tmp/reference.mp4 /tmp/silent.mp4 --seconds 12 # must fail
```

`--shuffled` generates reversed slots for another negative control. Use fresh output
paths; the generator refuses to overwrite files. Media generation, playback and
analysis use only macOS frameworks, with Python stdlib for orchestration.

The experimental `screenrec-test` CI job currently allows failure and uploads all
artifacts, with measurements in the step summary. With `--ci` or
`GITHUB_ACTIONS=true`, it logs display/audio/SIP diagnostics, first attempts capture
without TCC changes, and retries a permission failure once after granting the test
bundle access on the disposable runner. **Use `--ci` only on disposable machines.**
If the runner lacks an audio device or captures silence, an isolated best-effort
fallback installs BlackHole with Homebrew, restarts coreaudiod and selects its
output through CoreAudio. This optional CI experiment is the only third-party
download; the normal test path needs none. If audio remains unavailable, exit 20
and `AUDIO NOT CAPTURED` distinguish it from permission (10), usage (2), or other
capture/correlation failures (1). Hosted VM audio support remains unproven; silence
is a failure, never a skipped or successful test.

## Code style and tests

Follow nearby sources: four-space indentation, Swift naming conventions,
small types, and the existing Apache-2.0 copyright and license header at the
start of every Swift source and test file. Keep Swift 6 concurrency checks clean;
use `Sendable` and main-actor isolation where appropriate.

Add Swift Testing tests (`import Testing`) for new or changed logic. Put pure
logic behind protocols where it needs external inputs, and inject fakes for
power, process tables, assertions, storage, networking, and time. New logic tests
must not depend on real hardware state, the network, or the real clock.

Do not commit personal data, identifiers, hostnames, local filesystem locations,
bot tokens, or other secrets, including in fixtures, logs, and screenshots.
Use neutral synthetic examples. Never allowlist a real credential.

## Reporting issues

Open a GitHub issue with a short description, expected and actual behavior,
reproduction steps, macOS and Swift versions, and the relevant app version or
revision. Remove sensitive information from any diagnostics before sharing.
Report security vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

Contributions are licensed under Apache-2.0; preserve [LICENSE](LICENSE),
[NOTICE](NOTICE), and source headers.
