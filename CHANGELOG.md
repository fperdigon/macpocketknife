# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Local logging with daily files rotated over 30 days (#90).
- Audio-only recording mode: microphone and system audio saved to m4a (#96).
- Screen Recording and Microphone permission shortcuts are always shown, including a Microphone settings link when recording access is denied (#91, #92).
- Microphone entitlement and local build parity with release builds (#93).

### Changed
- Permission requests for recording now live only in the recording options window (#95).

### Fixed
- The app's own permissions (TCC) are reset after an update, so stale grants do not break recording (#94).

## [0.3.0] - 2026-11-19

### Added
- Screen recording with system audio, display selection (one, all, or pick with preview), and an options window with live screen cards refreshed every second (#72, #75, #80, #82, #87).
- Microphone mixed into the recording as one audio track, on by default (#77).

### Changed
- The microphone item was removed from the menu; the option stays in Settings (#78).

### Fixed
- The app now quits correctly instead of hanging in the update window (#84).

## [0.2.2] - 2026-10-26

### Added
- App icon, used in the menu bar and About tab, and an About menu item (#64, #65).
- On-device voice dictation with a global hotkey and clipboard output (#69).
- Keep unlocked menu option (#68).

### Fixed
- Menu bar icon was an opaque white square; transparency is fixed (#66).

## [0.2.1] - 2026-10-25

### Changed
- The app reacts to caffeinate only: no notices or battery alerts for other apps.
- Homebrew tap is notified when a stable release is published.

## [0.2.0] - 2026-10-25

### Changed
- Project renamed to MacPocketKnife.
- Tabbed settings window with a segmented update channel picker and a Running line.
- Status menu: shorter battery line, battery time remaining and power draw.
- About tab shows the short commit, repository address and credit.
- README and user guide: clear install steps.

## [0.1.0] - 2026-10-25

### Added
- Initial release: menu bar app that shows caffeinate activity and battery status, with integration tests using real caffeinate and pty consoles.

[Unreleased]: https://github.com/fperdigon/macpocketknife/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/fperdigon/macpocketknife/compare/v0.2.2...v0.3.0
[0.2.2]: https://github.com/fperdigon/macpocketknife/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/fperdigon/macpocketknife/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/fperdigon/macpocketknife/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/fperdigon/macpocketknife/releases/tag/v0.1.0
