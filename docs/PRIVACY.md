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

Microphone and speech-recognition permission prompts appear only on first use.
Permissions can be managed in System Settings > Privacy & Security. The global
shortcut uses Carbon hotkey registration and needs no Accessibility permission.

Audio and recognition text exist only in memory during a session and are never
saved or logged by the app. Successful dictation writes the final text to the
general clipboard. Copy notifications contain a word count, not transcript text.
Clipboard managers and Universal Clipboard may retain or sync clipboard text;
those services are outside this app's control. Empty sessions leave the clipboard
unchanged; errors discard the session. Recording is limited to ten minutes.
Only dictation preferences (shortcut and language) are stored in UserDefaults.

## Screen recording

Screen recording uses Apple's ScreenCaptureKit and AVAssetWriter to save the main
display and system audio locally as H.264/AAC MP4 files. The app's own audio is
excluded. Microphone capture is optional, off by default, and available only on
macOS 15 or later as a second audio track. Screen Recording permission is required;
microphone permission is requested only when that option is enabled. Access can
be revoked in System Settings > Privacy & Security.

No recording content leaves the Mac through this feature. There is no telemetry,
content logging, upload, or Telegram delivery. Saved notices are local only and
include the file name and save-folder path. Screen recording preferences are
stored in UserDefaults. Files remain in ~/Movies/MacPocketKnife or the folder you
choose until you delete them; removing the app does not remove recordings.
A folder managed by an external sync service may sync files under that service's
settings. Choose a local folder if you do not want such syncing.

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

The secret store and redactor are core building blocks. This issue does not
add Telegram networking or settings controls to the menu bar app.
Callers must pass known secret values to `Redactor.redact(_:secrets:)` before
logging or displaying errors that might contain them. It also masks Telegram
bot token patterns and credentials using the `Bearer` authorization scheme.
Redaction is a safeguard, not a reason to log request bodies or credentials.

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
