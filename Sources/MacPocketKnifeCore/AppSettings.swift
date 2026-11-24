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

@preconcurrency import Foundation

extension KeyedDecodingContainer {
    /// nil when the key is absent, null, mistyped or holds an unknown enum value.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

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

    private enum CodingKeys: String, CodingKey { case isEnabled, chatID, silentMode, includeMachineName }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = container.lenient(Bool.self, .isEnabled) ?? false
        chatID = container.lenient(String.self, .chatID)
        silentMode = container.lenient(Bool.self, .silentMode) ?? false
        includeMachineName = container.lenient(Bool.self, .includeMachineName) ?? false
    }
}

/// Non-secret preferences only. Bot credentials belong in SecretStore.
public struct AppSettings: Codable, Equatable, Sendable {
    public var alerts: AlertSettings
    public var policy: PolicySettings
    public var keepAwakeDefaultDuration: TimeInterval?
    public var telegram: TelegramPreferences
    public var resetPermissionsAfterUpdates = true
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
    public var audioRecordingMicrophone = true
    public var audioRecordingSystemAudio = true
    public var screenRecordingIncludesMicrophone = true
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
        case audioRecordingMicrophone, audioRecordingSystemAudio
        case screenRecordingTarget, screenRecordingDisplayName
        case screenRecordingHotkeyEnabled, screenRecordingHotkeyKey, screenRecordingFrameRate
        case screenRecordingShowsCursor, screenRecordingIncludesMicrophone, screenRecordingFolder
        case dictationHotkeyEnabled, dictationHotkeyKey, dictationLanguage
        case resetPermissionsAfterUpdates
        case alerts, policy, keepAwakeDefaultDuration, telegram, launchAtLogin
        case updateChannel, checkForUpdatesAutomatically, skippedVersion, showOtherSleepBlockers
    }

    /// Every field decodes independently: a missing, mistyped or unknown value only resets that field.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        alerts = container.lenient(AlertSettings.self, .alerts) ?? AlertSettings()
        policy = container.lenient(PolicySettings.self, .policy) ?? PolicySettings()
        keepAwakeDefaultDuration = container.lenient(TimeInterval.self, .keepAwakeDefaultDuration)
        telegram = container.lenient(TelegramPreferences.self, .telegram) ?? TelegramPreferences()
        resetPermissionsAfterUpdates = container.lenient(Bool.self, .resetPermissionsAfterUpdates) ?? true
        launchAtLogin = container.lenient(Bool.self, .launchAtLogin) ?? false
        showOtherSleepBlockers = container.lenient(Bool.self, .showOtherSleepBlockers) ?? false
        updateChannel = container.lenient(UpdateChannel.self, .updateChannel) ?? .stable
        checkForUpdatesAutomatically = container.lenient(Bool.self, .checkForUpdatesAutomatically) ?? true
        dictationHotkeyEnabled = container.lenient(Bool.self, .dictationHotkeyEnabled) ?? true
        dictationHotkeyKey = container.lenient(String.self, .dictationHotkeyKey) ?? "T"
        dictationLanguage = container.lenient(String.self, .dictationLanguage)
        screenRecordingHotkeyEnabled = container.lenient(Bool.self, .screenRecordingHotkeyEnabled) ?? true
        screenRecordingHotkeyKey = container.lenient(String.self, .screenRecordingHotkeyKey) ?? "R"
        screenRecordingFrameRate = container.lenient(Int.self, .screenRecordingFrameRate) ?? 30
        screenRecordingShowsCursor = container.lenient(Bool.self, .screenRecordingShowsCursor) ?? true
        audioRecordingMicrophone = container.lenient(Bool.self, .audioRecordingMicrophone) ?? true
        audioRecordingSystemAudio = container.lenient(Bool.self, .audioRecordingSystemAudio) ?? true
        screenRecordingIncludesMicrophone = container.lenient(Bool.self, .screenRecordingIncludesMicrophone) ?? true
        screenRecordingTarget = container.lenient(ScreenRecordingTarget.self, .screenRecordingTarget) ?? .mainDisplay
        screenRecordingDisplayName = container.lenient(String.self, .screenRecordingDisplayName)
        screenRecordingFolder = container.lenient(String.self, .screenRecordingFolder) ?? ScreenRecordingFiles.defaultFolder
        skippedVersion = container.lenient(String.self, .skippedVersion)
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

// Compare encoded settings so the log contains schema names only, including nested keys.
extension AppSettings {
    func changedKeys(from previous: AppSettings) -> [String] {
        guard let before = try? JSONEncoder().encode(previous),
              let after = try? JSONEncoder().encode(self),
              let old = try? JSONSerialization.jsonObject(with: before) as? NSDictionary,
              let new = try? JSONSerialization.jsonObject(with: after) as? NSDictionary else { return [] }
        func changes(_ old: NSDictionary, _ new: NSDictionary, prefix: String) -> [String] {
            let oldKeys = old.allKeys.compactMap { $0 as? String }
            let newKeys = new.allKeys.compactMap { $0 as? String }
            var changed: [String] = []
            for key in Set(oldKeys + newKeys).sorted() {
                let path = prefix + key
                if let oldChild = old[key] as? NSDictionary, let newChild = new[key] as? NSDictionary {
                    changed.append(contentsOf: changes(oldChild, newChild, prefix: path + "."))
                } else if !((old[key] as? NSObject)?.isEqual(new[key]) ?? (new[key] == nil)) {
                    changed.append(path)
                }
            }
            return changed
        }
        return changes(old, new, prefix: "")
    }
}
