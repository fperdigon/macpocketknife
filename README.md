# MacPocketKnife

A personal pocket multi-tool for the Mac menu bar. Its first tool is a battery
guard for forgotten `caffeinate` processes and the app’s own keep-awake, designed
for offline use with local alerts and an optional Telegram channel.

## Status

The app runs in the menu bar and monitors battery power and sleep blockers. It
Keep unlocked keeps the display awake for long jobs and debugger sessions.
It shows battery time remaining and watts, and provides a Keep awake toggle. A
`caffeinate` process started from a console is terminated immediately; app-started `caffeinate` is reported and handled at the configured kill threshold.
Battery alerts escalate by severity and can be delivered through macOS local
notifications or optional Telegram. Settings are available in tabs, and updates
can be checked and installed in the app.

- **Screen recording:** record the main display with system audio to MP4 using Control-Option-Command-R; optional microphone on macOS 15+, with local files and notifications.
- **Dictation:** on-device voice-to-text from the default microphone, toggled from the menu or Control-Option-Command-T, with the transcript copied to the clipboard.

## Protection rules

The app applies these protection rules:

| Origin | Behavior |
|---|---|
| Started from a console (shell, Terminal, iTerm, tmux or ssh in the parent chain) | Terminated immediately; the user is told. The app takes over. |
| Started by another app, or not classifiable | Only reported. Terminated when the battery reaches the kill threshold (default 15%) on battery power. |
| The app's own assertion | Indefinite by default. Released at the kill threshold like the others. |
| Other sleep blockers (media players, other keep-awake tools) | Ignored by default (can be listed in the menu, information only) |

Only processes owned by the current user are eligible for termination. A retry
limit prevents repeated termination if something keeps relaunching `caffeinate`.
Console classification uses conservative ancestry heuristics; incomplete evidence
is treated as app-originated.

## Install

### Homebrew (recommended)

Install:

```bash
brew install --cask fperdigon/tap/macpocketknife
```

The cask removes the quarantine flag so Gatekeeper does not block this ad-hoc
signed, non-notarized app.

Upgrade:

```bash
brew upgrade --cask macpocketknife
```

For Homebrew installs, use `brew upgrade` to keep Homebrew's recorded version
current; the app's own updater can make that version stale. Automatic update
checks can be turned off in **Settings > Updates**.

Uninstall:

```bash
brew uninstall --cask macpocketknife
```

Add `--zap` to remove preferences and caches:

```bash
brew uninstall --cask macpocketknife --zap
```

### Manual install (DMG)

1. Download `MacPocketKnife-<version>.dmg` and its matching `.sha256` file from
   [GitHub Releases](https://github.com/fperdigon/macpocketknife/releases).
   The latest stable release is at the top; nightlies are pre-releases.
2. In the download folder, verify the DMG with:

   ```bash
   shasum -a 256 -c MacPocketKnife-<version>.dmg.sha256
   ```

3. Open the DMG, drag **MacPocketKnife** to Applications, then eject the DMG.
4. The app is ad-hoc signed and **not notarized**, so macOS blocks it on first
   launch. Try to open it once, then go to **System Settings > Privacy & Security**,
   scroll to the message about MacPocketKnife, click **Open Anyway**, and confirm.
   On macOS 15 and later, the old right-click > Open shortcut no longer bypasses
   this block. Alternatively, if you are comfortable with Terminal, run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/MacPocketKnife.app
   ```

   This removes the download-quarantine flag from this app only.
5. A menu bar icon appears. Allow notifications when macOS asks. Open the menu
   to see status, toggle Keep awake, open Settings, or Check for Updates.

### Updating

Use **Check for Updates…** in the menu or check in **Settings > Updates**. Stable
releases are selected by default; nightly updates are optional in Settings >
Updates. Installing an update quits and reopens the app.

### Uninstall

Quit the app and delete it from Applications. To remove preferences, run
`defaults delete io.github.fperdigon.macpocketknife`. If you saved a Telegram
token, delete the Keychain item for service `macpocketknife`.

### Requirements

macOS 13 or later; Apple silicon or Intel.

## Build, test, and run from source

Requires macOS 13 or later and a Swift 6 toolchain. There are no external package
dependencies. From the repository root:

```sh
swift build
swift test
swift run MacPocketKnife
```

The app runs in the menu bar without a Dock icon. Use its menu to quit.
See [CONTRIBUTING.md](CONTRIBUTING.md) for repository checks and testing guidance,
and the [user guide](docs/USER_GUIDE.md) for controls and setup.

## Privacy

No telemetry, analytics, advertising, or remote crash reporting. The optional
Telegram channel is the only intended network use. Its bot token belongs in the
macOS Keychain; nonsecret preferences stay local. Machine-name inclusion is
opt-in and disabled by default in the core formatter.

See [privacy and removal details](docs/PRIVACY.md). Report vulnerabilities using
the private process in [SECURITY.md](SECURITY.md).

## License

Apache-2.0. Copyright 2026 Francisco Perdigon Romero and contributors.
See [LICENSE](LICENSE) and [NOTICE](NOTICE).

## About the author

Created by Francisco Perdigon Romero (https://github.com/fperdigon), founder of Core AI (https://core-ai.net), a company specializing in privacy-focused enterprise AI solutions.
