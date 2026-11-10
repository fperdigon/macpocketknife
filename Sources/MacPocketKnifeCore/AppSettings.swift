// Copyright 2026 Francisco Perdigon Romero and contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

public struct TelegramPreferences: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var chatID: String?
    public var silentMode: Bool
    public var includeMachineName: Bool

    public init(
        isEnabled: Bool = false, chatID: String? = nil,
        silentMode: Bool = false, includeMachineName: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.chatID = chatID
        self.silentMode = silentMode
        self.includeMachineName = includeMachineName
    }
}

/// Non-secret preferences only. Bot credentials belong in SecretStore.
public struct AppSettings: Codable, Equatable, Sendable {
    public var alerts: AlertSettings
    public var policy: PolicySettings
    public var keepAwakeDefaultDuration: TimeInterval?
    public var telegram: TelegramPreferences
    public var launchAtLogin: Bool
    public var showOtherSleepBlockers: Bool
    public var updateChannel: UpdateChannel
    public var checkForUpdatesAutomatically: Bool
    public var dictationHotkeyEnabled: Bool = true
    public var dictationHotkeyKey: String = "T"
    public var dictationLanguage: String?
    public var screenRecordingHotkeyEnabled = true
    public var screenRecordingHotkeyKey = "R"
    public var screenRecordingFrameRate = 30
    public var screenRecordingShowsCursor = true
    public var screenRecordingIncludesMicrophone = false
    public var screenRecordingTarget: ScreenRecordingTarget = .mainDisplay
    public var screenRecordingDisplayName: String?
    public var screenRecordingFolder = ScreenRecordingFiles.defaultFolder
    public var skippedVersion: String?

    public init(
        alerts: AlertSettings = AlertSettings(), policy: PolicySettings = PolicySettings(),
        keepAwakeDefaultDuration: TimeInterval? = nil,
        telegram: TelegramPreferences = TelegramPreferences(), launchAtLogin: Bool = false,
        updateChannel: UpdateChannel = .stable, checkForUpdatesAutomatically: Bool = true,
        skippedVersion: String? = nil, showOtherSleepBlockers: Bool = false
    ) {
        self.alerts = alerts
        self.policy = policy
        self.keepAwakeDefaultDuration = keepAwakeDefaultDuration
        self.telegram = telegram
        self.launchAtLogin = launchAtLogin
        self.showOtherSleepBlockers = showOtherSleepBlockers
        self.updateChannel = updateChannel
        self.checkForUpdatesAutomatically = checkForUpdatesAutomatically
        self.skippedVersion = skippedVersion
    }

    public static let dictationKeys = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)

    public var screenRecordingHotkeyConflicts: Bool {
        screenRecordingHotkeyEnabled && dictationHotkeyEnabled && screenRecordingHotkeyKey == dictationHotkeyKey
    }

    private enum CodingKeys: String, CodingKey {
        case screenRecordingTarget, screenRecordingDisplayName
        case screenRecordingHotkeyEnabled, screenRecordingHotkeyKey, screenRecordingFrameRate
        case screenRecordingShowsCursor, screenRecordingIncludesMicrophone, screenRecordingFolder
        case dictationHotkeyEnabled, dictationHotkeyKey, dictationLanguage
        case alerts, policy, keepAwakeDefaultDuration, telegram, launchAtLogin
        case updateChannel, checkForUpdatesAutomatically, skippedVersion, showOtherSleepBlockers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Existing fields remain required so corrupt settings still use the store's fallback.
        alerts = try container.decode(AlertSettings.self, forKey: .alerts)
        policy = try container.decode(PolicySettings.self, forKey: .policy)
        keepAwakeDefaultDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .keepAwakeDefaultDuration)
        telegram = try container.decode(TelegramPreferences.self, forKey: .telegram)
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        showOtherSleepBlockers = try container.decodeIfPresent(Bool.self, forKey: .showOtherSleepBlockers) ?? false
        updateChannel = try container.decodeIfPresent(UpdateChannel.self, forKey: .updateChannel) ?? .stable
        checkForUpdatesAutomatically = try container.decodeIfPresent(Bool.self, forKey: .checkForUpdatesAutomatically) ?? true
        dictationHotkeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .dictationHotkeyEnabled) ?? true
        dictationHotkeyKey = try container.decodeIfPresent(String.self, forKey: .dictationHotkeyKey) ?? "T"
        dictationLanguage = try container.decodeIfPresent(String.self, forKey: .dictationLanguage)
        screenRecordingHotkeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .screenRecordingHotkeyEnabled) ?? true
        screenRecordingHotkeyKey = try container.decodeIfPresent(String.self, forKey: .screenRecordingHotkeyKey) ?? "R"
        screenRecordingFrameRate = try container.decodeIfPresent(Int.self, forKey: .screenRecordingFrameRate) ?? 30
        screenRecordingShowsCursor = try container.decodeIfPresent(Bool.self, forKey: .screenRecordingShowsCursor) ?? true
        screenRecordingIncludesMicrophone = try container.decodeIfPresent(Bool.self, forKey: .screenRecordingIncludesMicrophone) ?? false
        screenRecordingTarget = try container.decodeIfPresent(ScreenRecordingTarget.self, forKey: .screenRecordingTarget) ?? .mainDisplay
        screenRecordingDisplayName = try container.decodeIfPresent(String.self, forKey: .screenRecordingDisplayName)
        screenRecordingFolder = try container.decodeIfPresent(String.self, forKey: .screenRecordingFolder) ?? ScreenRecordingFiles.defaultFolder
        skippedVersion = try container.decodeIfPresent(String.self, forKey: .skippedVersion)
    }

    /// Keep thresholds strictly ordered and intervals finite and at least ten seconds.
    public func validated() -> AppSettings {
        var result = self
        let urgent = min(100, max(2, alerts.urgentBelowPercent))
        let critical = min(urgent - 1, max(1, alerts.criticalBelowPercent))
        func interval(_ value: TimeInterval, fallback: TimeInterval) -> TimeInterval {
            value.isFinite ? max(10, value) : fallback
        }
        result.alerts = AlertSettings(
            urgentBelowPercent: urgent, criticalBelowPercent: critical,
            normalInterval: interval(alerts.normalInterval, fallback: 600),
            urgentInterval: interval(alerts.urgentInterval, fallback: 120),
            criticalInterval: interval(alerts.criticalInterval, fallback: 60)
        )
        result.policy = PolicySettings(
            killThresholdPercent: min(50, max(5, policy.killThresholdPercent)),
            maxKillsPerWindow: policy.maxKillsPerWindow,
            killWindow: interval(policy.killWindow, fallback: 60)
        )
        if let duration = keepAwakeDefaultDuration {
            result.keepAwakeDefaultDuration = duration.isFinite ? max(10, duration) : nil
        }
        let key = dictationHotkeyKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        result.dictationHotkeyKey = Self.dictationKeys.contains(key) ? key : "T"
        let screenKey = screenRecordingHotkeyKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        result.screenRecordingHotkeyKey = Self.dictationKeys.contains(screenKey) ? screenKey : "R"
        result.screenRecordingTarget = screenRecordingTarget.validated()
        result.screenRecordingFrameRate = screenRecordingFrameRate == 60 ? 60 : 30
        let folder = screenRecordingFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        result.screenRecordingFolder = folder.isEmpty ? ScreenRecordingFiles.defaultFolder : NSString(string: folder).expandingTildeInPath
        return result
    }
}
