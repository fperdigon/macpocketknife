# MacPocketKnife user guide

MacPocketKnife is a personal pocket multi-tool for the Mac menu bar. Its first
tool is a battery guard for forgotten `caffeinate` processes and the app’s own keep-awake.

## Availability and installation

The app monitors battery power and sleep blockers from the menu bar. It provides
battery status, Keep awake, Settings, local notifications, optional Telegram
alerts, and in-app updates. Console-started `caffeinate` processes are terminated
immediately; app-started `caffeinate` is reported and handled at the configured
kill threshold.

## Install

Install with Homebrew or manually from a DMG; follow the corresponding steps in
[README.md](../README.md#install) without repeating them here. The app requires
macOS 13 or later on Apple silicon or Intel. Builds are ad-hoc signed and not
notarized.

Source builds require macOS 13 or later and Swift 6:

```sh
swift build
swift test
swift run MacPocketKnife
```

Use the menu bar menu's Quit command to exit.

## Keep-awake toggle

Turn on Keep Awake in the menu bar to prevent idle system sleep. Turn it off to
release the app's assertion. Indefinite operation is the default. Settings lets
you choose a default duration, and the app restores saved Keep awake state on launch.

## Keep unlocked

Turn on **Keep unlocked**, directly below Keep awake in the menu, to keep the
display awake and prevent the idle screen saver, display sleep and inactivity
lock. Its checkmark shows when it is active. Turn it off to release its own
assertion. It also prevents idle system sleep and works independently of Keep awake.

The Mac stays unlocked and un-dimmed while this is on, so only use it where you
trust the surroundings. Manual lock (Ctrl-Cmd-Q), closing the lid and MDM or other
password policies still apply; this feature does not bypass them.

Keep unlocked uses the same default duration setting as Keep awake (indefinite
by default). Its state and expiry are saved separately and restored on launch.
On battery, it receives the same escalating alerts, mentioning that the display
is kept awake, and is released at the battery kill threshold.

## Dictation

Choose **Dictate** below **Keep unlocked**, or press **Control-Option-Command-T**,
to start recording from the default microphone and transcribing live. A red dot
appears beside the menu bar icon while recording. Choose **Stop dictation** or
press the shortcut again to stop and copy the transcript. Paste with **Command-V**.
A local notification confirms the copy with a word count. Empty dictation leaves
the clipboard unchanged and shows “No speech detected”. Recording stops and copies
automatically after ten minutes. Audio or recognition errors discard the session.
Toggling again while permission requests are pending cancels startup.

In **Settings > Tools > Dictation**, enable or disable the global shortcut and
choose its letter (A–Z). Control, Option and Command are fixed modifiers. A shortcut
conflict is shown in settings and a local notice; choose another letter. Shortcuts
use the physical ANSI letter-key positions and require no Accessibility permission.

**Dictation language** defaults to the current system locale. The language picker
also lists locales supported by Apple's on-device speech recognizer. All app labels
remain in English. Enable offline dictation for the chosen language in **System
Settings > Keyboard > Dictation**, allowing any language download to finish. If
on-device recognition is unavailable, the app stays idle and explains this step;
it never falls back to server recognition.

The first use requests **Microphone** and **Speech Recognition** permissions.
If denied, allow MacPocketKnife under **System Settings > Privacy & Security >
Microphone / Speech Recognition**, then retry. Error guidance also appears in the
menu and opens Privacy settings when clicked. A working default audio input is
required; change it under **System Settings > Sound** if needed.

Apple's Speech framework processes speech on device. MacPocketKnife does not save
or log audio or transcripts, and sends no dictation data anywhere. Recognition uses
memory only during the session. Only the final text goes to the general clipboard;
notifications contain only a word count. Clipboard managers and Universal Clipboard
may retain or sync that text outside the app. Replace or clear your clipboard when
finished if the text is sensitive.

## Screen recording

Choose **Record screen** below **Dictate**, or press **Control-Option-Command-R**,
to record the main display and system audio: videos, calls, and other apps' sound.
The app's own audio is excluded. A red **⏺ mm:ss** indicator shows elapsed time;
it appears alongside the Dictation dot when both tools are active. Choose
**Stop recording** or press the shortcut again to finalize the file. A local
**Screen recording saved** notification includes the file name and folder path.

Files go to **~/Movies/MacPocketKnife** by default. The folder is created when
needed. Names use local time: **Screen yyyy-MM-dd HH.mm.ss.mp4**, with a numbered
suffix when necessary to avoid overwriting recordings. **Show recordings in
Finder** opens the folder. Edit or trim recordings with **QuickTime Player**.

In **Settings > Tools > Screen recording**, enable or disable the global shortcut,
choose its A–Z key, select 30 or 60 fps, show or hide the cursor, and choose or
reset the save folder. Control, Option and Command are fixed modifiers. Choose a
key different from Dictation's key; duplicate shortcuts are refused and explained
in settings. Carbon shortcuts use physical ANSI key positions and need no
Accessibility access. **Include microphone** defaults to off and is available
only on macOS 15 or later; it adds a second AAC audio track in the same file.
Player support for simultaneous playback of multiple audio tracks varies.

On first use, approve the macOS **Screen Recording** prompt. In **System Settings >
Privacy & Security > Screen & System Audio Recording**, enable MacPocketKnife
(the pane may be called **Screen Recording** on older macOS versions). You may
need to quit and relaunch the app after granting access, then start recording
again. Permission guidance in the menu opens this pane. Microphone access is
requested separately only if **Include microphone** is enabled.

Capture uses native display pixels, H.264 video, and 48 kHz stereo AAC system
audio. Only the main display is recorded; protected content may be blank or
silent, and high resolutions or 60 fps can exceed the Mac's encoder capacity.
Slow storage may cause dropped frames. At least 1 GB of free space is required
to start; recording stops and finalizes if space becomes critically low or
capture fails. Empty or unusable files are removed. Stopping sharing from macOS,
disconnecting the display, or quitting the app also finalizes the recording.
There is no duration limit. Recording does not keep the Mac awake: sleep,
locking, and lid behavior still apply. All capture and encoding stay on the Mac;
recording content is never logged or sent to Telegram.

## External sleep blockers

The app applies these rules:

- Console-started `caffeinate`: terminate it immediately, notify you, and let the
  app take over keep-awake control. Classification requires conservative console
  ancestry evidence; incomplete or unknown ancestry is treated as app-originated.
- `caffeinate` started by another app, or not classifiable: report it, then
  terminate it only at the battery kill threshold while on battery power.
- Other sleep blockers, such as media players: ignored by default. Enable “Also list other apps that keep the Mac awake (information only)” in Protection settings to list them in the menu. They never trigger notices, battery alerts, or termination.

Only current-user processes are eligible for termination. The default retry
limit is three termination actions per process name in a rolling 60-second
window, preventing a loop if a process repeatedly relaunches.

## Battery alerts and kill threshold

While on battery with `caffeinate`, Keep awake or Keep unlocked active, the core schedules an initial
alert, immediate escalation when severity increases, and repeated alerts:

| Battery level | Default repeat interval | Severity |
|---|---|---|
| 50% or higher | 10 minutes | Normal |
| Below 50%, at least 20% | 2 minutes | Urgent |
| Below 20% | 1 minute | Critical |

Alerts stop when external power returns or the blocker disappears. The core
also stops scheduling when the battery percentage is unknown.

At or below the default **15% kill threshold**, while on battery, eligible
`caffeinate` processes are terminated and the app releases both of its own assertions.
Other sleep blockers are ignored except for the optional informational menu listing. Settings controls the threshold and
alert levels and intervals. Alerts are delivered through local notifications;
macOS notification authorization must be allowed for them to appear.

## Telegram setup

Telegram alert delivery is optional and configured in Settings. The bot token is
stored in the macOS Keychain.
The intended setup is:

1. Open Settings and enable Telegram delivery.
2. Use an existing bot token, or open Telegram's BotFather and use `/newbot` to
   create a bot. Follow its prompts and keep the resulting token private.
3. Enter the token in Settings and validate the bot.
   Tokens must be stored only in the macOS Keychain.
4. Begin chat discovery, then open a private conversation with the bot and send
   exactly `/start`. Send a new message after discovery begins: the core discards
   the existing backlog. Discovery times out after 60 seconds by default; retry
   and send a fresh `/start` if needed.
5. Choose Send test message and verify receipt before enabling
   routine delivery. The existing core test-message operation is not silent.

**Silent mode:** routine alerts can be sent without sound;
the core channel supports this option. Telegram alerts are intended to respect
the phone's silent and Do Not Disturb settings. Urgency uses frequency and wording;
delivery and sound also depend on Telegram and device settings.

## Updates

Choose **Check for Updates…** in the status menu, or open **Settings > Updates**
and choose **Check now**. Stable releases are the default; select Nightly for
the newest published development build. A development build with no known commit
never reports that it is current on the Nightly channel.

Automatic checking is on by default. It runs at launch at most once every
24 hours, including failed checks; disable it in Settings for manual checks.
**Later** dismisses an offer. **Skip this version** suppresses that release in
background checks; a manual check can still offer it. Changing channels clears
the skipped release.

**Install and relaunch** downloads the DMG with progress, verifies GitHub's
SHA-256 digest if one is published, mounts the image read-only, and checks the
app's bundle identifier and code signature. Installation stages the bundle on
the same volume and atomically replaces it, retaining a backup through validation.
If installation fails, the app reports an error and restores the backup when
replacement has started. The destination folder must be writable.

The app saves and flushes its current Keep awake and Keep unlocked states before quitting. A helper
waits for exit and reopens the installed app, which restores the saved state and
expiry. Checks use GitHub's public API; installation downloads only the chosen
release asset. There is no telemetry. See [PRIVACY.md](PRIVACY.md).

## Privacy and removal

There is no telemetry. Local operation needs no network. Optional Telegram
delivery shares the bot credential, destination chat ID, and message content
with Telegram. Machine-name inclusion is opt-in and off by default. Keep tokens
and chat IDs out of logs and shared diagnostics. See [PRIVACY.md](PRIVACY.md).

To remove everything:

1. Disable Telegram and Keep Awake if desired, then quit the app and remove the
   installed app or local build products.
2. If setup or core use stored a token, delete the generic-password Keychain item
   with service `macpocketknife` and account `telegramBotToken` in Keychain
   Access. If a custom service was used, remove its corresponding item instead.
3. Remove the app's UserDefaults preferences using the installed app's actual
   preferences domain. Uninstalling alone does not delete preferences or tokens.
4. Revoke the token through BotFather if it should no longer work. Remove the bot
   and Telegram conversation separately if desired; deleting local data does not
   erase messages already delivered to Telegram.
