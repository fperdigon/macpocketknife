# Privacy and secrets

MacPocketKnife is a personal pocket multi-tool for the Mac menu bar. Its first
tool, a battery guard for forgotten `caffeinate` processes and other sleep
blockers, is designed to work offline with local notifications.
There is no telemetry, analytics, advertising, or remote crash reporting.

## Dictation

Dictation uses only Apple's Speech framework and AVAudioEngine with the default
microphone. Every recognition request requires on-device recognition. If the chosen
locale cannot support it, recording does not start; there is no server fallback.
Enable offline dictation for the language in System Settings > Keyboard > Dictation.
Apple's Speech framework performs the processing on device. The app sends no audio
or transcript anywhere, including to Telegram.

Microphone and speech-recognition permission prompts appear on first use and may
appear again after an update resets this app's entries (see below).
Permissions can be managed in System Settings > Privacy & Security. The global
shortcut uses Carbon hotkey registration and needs no Accessibility permission.

Audio and recognition text exist only in memory during a session and are never
saved or logged by the app. Successful dictation writes the final text to the
general clipboard. Copy notifications contain a word count, not transcript text.
Clipboard managers and Universal Clipboard may retain or sync clipboard text;
those services are outside this app's control. Empty sessions leave the clipboard
unchanged; errors discard the session. Recording is limited to ten minutes.
Only dictation preferences (shortcut and language) are stored in UserDefaults.

## Audio-only recording

**Record audio…** uses Apple's ScreenCaptureKit and AVAssetWriter locally to save
one AAC `.m4a` file. You choose microphone, system audio, or both. Microphone
capture requires macOS 15+; macOS 13/14 supports system audio only. The toggles
are stored locally and default on. Microphone permission is requested only when
selected. A denied or unavailable microphone falls back to system audio when
selected, with a notice; a microphone-only attempt fails instead.

ScreenCaptureKit requires Screen Recording permission. The stream uses tiny,
low-frame-rate video frames that are discarded immediately: no video track or
screenshots are written. The options window captures no previews. PCM conversion
and mixing use memory-only buffers. The app's own system audio is excluded.

Recordings stay in the same user-selected recordings folder as video (default
`~/Movies/MacPocketKnife`), with `Audio YYYY-MM-DD HH.MM.SS.m4a` names. A hidden
`.Recording-<uuid>.m4a` working file holds encoded audio during recording and is
renamed after finalization; unusable output is removed. Files remain until you
delete them. Audio and video capture cannot run together. Save notifications
contain the file name and folder, and **Show in Finder** selects the local file.
Diagnostics record state changes, duration, and fixed failure categories only.
No audio or recording content is logged, uploaded, or sent to Telegram. There is
no cloud processing, telemetry, or server fallback for this feature.

## Screen recording

Screen recording uses Apple's ScreenCaptureKit and AVAssetWriter to save selected
displays and system audio locally as H.264/AAC MP4 files. The app's own audio is
excluded. Microphone capture is included by default on
macOS 15 or later and mixed with system audio into one 48 kHz stereo AAC track.
Turn it off in **Settings > Tools > Screen recording > Include microphone**.
If permission is denied or the microphone cannot start, video and system audio
still record, with a notice in the menu and saved notification. On older macOS,
the microphone is omitted and the macOS 15 requirement is shown once per session.
Screen Recording permission is required;
microphone permission is requested only when that option is enabled. Access can
be revoked in System Settings > Privacy & Security.

The options window takes in-memory screenshots of your screens only to show
previews. These screenshots are never saved or sent, and are released when the
window closes or hides. Previews refresh about every second while the window is
visible and need the same Screen Recording permission as recording. Opening the
window attempts capture and may prompt for access. If capture fails, refresh
stops until you return to the window or use **Allow screen preview**, which requests
access and opens Screen Recording settings. macOS may ask again after an app update.

The macOS 14+ system picker and its live display thumbnails stay on this Mac.
Neither picker selections nor thumbnails are uploaded. Display UUIDs and the last
selected display name are stored locally with preferences.

No recording content leaves the Mac through this feature. There is no telemetry,
content logging, upload, or Telegram delivery. Saved notices are local only and
include the file name and save-folder path. Screen recording preferences are
stored in UserDefaults. Files remain in ~/Movies/MacPocketKnife or the folder you
choose until you delete them; removing the app does not remove recordings.
A folder managed by an external sync service may sync files under that service's
settings. Choose a local folder if you do not want such syncing.

## Local diagnostic logs

Daily diagnostic files are stored only on this Mac in
`~/Library/Logs/MacPocketKnife/macpocketknife-YYYY-MM-DD.log`.
Open them from **Settings > About > Logs > Open logs folder**. The app never
uploads logs, including to Telegram. Each log is also mirrored to the macOS
unified log for Console.app, under subsystem `io.github.fperdigon.macpocketknife`;
macOS manages the unified log's retention separately.

Logs contain metadata: app version, build channel, macOS version, architecture,
launch and quit, changed setting names, update results and error categories,
keep-awake and protection actions, process names, battery alert levels, recording
and dictation state, durations and counts, language, permission outcomes, and
Telegram delivery status categories. Logs never contain dictation text,
transcripts, audio, screen or recording content, Telegram message bodies, bot
tokens, chat IDs, or Keychain values. Home-directory paths are replaced with `~`,
and token patterns and authorization credentials are redacted as a safeguard.

The app keeps the current day and preceding 29 local calendar days, pruning
older matching log files at launch and when the day changes. Other files are
left alone. Debug and info file logging stops at about 10 MB per day with one
size-cap warning; warnings and errors can continue up to 20 MB. The folder uses
owner-only permissions (0700), and log files use 0600. If logs cannot be written,
the app continues silently. Uninstalling the app does not remove its logs;
delete the folder to remove them immediately.

## Local storage

The Telegram bot token belongs only in the macOS Keychain, as a generic-password
item with service `macpocketknife` and account `telegramBotToken`.
The core Keychain store uses `WhenUnlockedThisDeviceOnly` accessibility and
explicitly disables iCloud synchronization. A custom service can be supplied
by a caller. The token must never be saved in preferences, logs, or source files.

Nonsecret preferences, such as keep-awake state and its optional expiry time,
are stored locally in the app's UserDefaults domain. Alert thresholds and
notification choices are preferences, not secrets. Treat the Telegram chat ID
as private routing information; never put it in source code or logs.

Use `AppLog` for diagnostic logging; it redacts every entry before writing.
Callers must still exclude secrets and content entirely, and pass known secret
values to `Redactor.redact(_:secrets:)` before displaying errors that might
contain them. Redaction is a safeguard, not a reason to log request bodies or
credentials.

## Network access and messages

The optional Telegram channel contacts the Telegram API only when enabled. Telegram receives the bot credential,
the destination chat ID, and the message content needed to deliver alerts.
Local notifications require no network access.

Messages contain the battery level and minimal information about what is
blocking sleep or what action was taken. They must not contain credentials,
personal identifiers, filesystem locations, or command arguments. Including
the Mac's name is opt-in and is disabled by default. Telegram processes and
retains delivered messages according to its own policies.

## Software updates

Update checks contact `api.github.com` for the public releases of
`fperdigon/macpocketknife`. Automatic checking is enabled by default and
runs at launch at most once every 24 hours, including failed attempts. Turn it
off in Settings > Updates to make checks manual only. Installing an offered
update downloads its release asset from GitHub and GitHub's release asset CDN.
No update network access occurs except during a check or installation.

Requests include ordinary HTTP connection metadata; no device identifiers,
preferences, battery state, credentials, or telemetry are sent. The selected
channel, skipped release, and last check time stay in local preferences.
The updater verifies GitHub's SHA-256 digest when supplied, bundle identity,
and the app's code signature before replacing the installed app.

## Removing everything

1. Disable Telegram delivery and quit the app.
2. In Keychain Access, find the generic-password item for the service above and
   delete its `telegramBotToken` entry. For a custom service, delete the item
   under that service instead. Core callers can also use
   `SecretStore.removeSecret(for: .telegramBotToken)`.
3. Remove the app's UserDefaults preferences using the domain of the installed
   app, and remove the app itself. Uninstalling alone does not delete Keychain
   items or preferences.
4. Revoke the bot token through BotFather if it should no longer be usable.
   Delete the Telegram conversation and bot separately if desired; deleting
   local data does not remove messages already delivered to Telegram.

## Repository checks

Run `sh scripts/scan-secrets.sh` from the repository to scan tracked working-tree
files. It detects Telegram bot token patterns, authorization credentials, and
private key headers, and fails without printing matched values. Untracked
files and Git history are outside its scope. Only the scanner itself is
excluded. A fake placeholder is accepted only if its complete matched value
is explicitly listed in `scripts/secret-allowlist.txt`; entries are literal,
case-sensitive values, not patterns. Never allowlist a real credential.

Run `sh scripts/test-scan-secrets.sh` to verify rejection of a fake token built
at runtime, along with authorization credentials and private key headers.
The test creates and removes an isolated temporary Git repository.

Run `swift test` for the core tests. The Keychain integration test uses a unique
random service and deletes its item afterward; it is skipped whenever the `CI`
environment variable is set. All other secret store and redactor tests use
in-memory data and require no hardware, network, or real clock.

## Permissions after updates

Ad-hoc signed updates can invalidate macOS permission grants. **Settings > General >
Reset permissions after updates** is on by default. On the first launch, and whenever
the main executable's SHA-256 changes (including nightlies with the same version),
the app uses the system `/usr/bin/tccutil` tool to reset only its own
`io.github.fperdigon.macpocketknife` entries for Microphone, ScreenCapture, and
SpeechRecognition. It never resets another app's entries or all apps' permissions.
Re-allow Screen Recording and Microphone in **Record screen… > Permissions**;
dictation requests Speech Recognition again on use. A local notice appears if
notifications are authorized and at least one reset succeeds. Turn the setting off
to keep existing entries. Resets do not grant access or read capture content.
