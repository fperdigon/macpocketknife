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
import Testing
@testable import MacPocketKnifeCore

private func decode(_ json: String) throws -> AppSettings {
    try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
}

@Test func unknownEnumValueOnlyResetsThatField() throws {
    let json = """
    {"updateChannel":"beta","launchAtLogin":true,"screenRecordingTarget":{"hologram":{}},
     "telegram":{"isEnabled":true,"chatID":"-42"},"screenRecordingFrameRate":60}
    """
    let settings = try decode(json)
    #expect(settings.updateChannel == .stable)
    #expect(settings.screenRecordingTarget == .mainDisplay)
    #expect(settings.launchAtLogin)
    #expect(settings.telegram.isEnabled && settings.telegram.chatID == "-42")
    #expect(settings.screenRecordingFrameRate == 60)
}

@Test func mistypedAndMissingFieldsFallBackIndividually() throws {
    let json = #"{"launchAtLogin":"yes","alerts":{"urgentBelowPercent":40,"criticalBelowPercent":"x"},"policy":5,"dictationHotkeyKey":"K"}"#
    let settings = try decode(json)
    #expect(!settings.launchAtLogin)
    #expect(settings.alerts.urgentBelowPercent == 40)
    #expect(settings.alerts.criticalBelowPercent == 20)
    #expect(settings.policy == PolicySettings())
    #expect(settings.dictationHotkeyKey == "K")
    #expect(settings.telegram == TelegramPreferences())
}

@Test func emptyObjectDecodesToDefaults() throws {
    #expect(try decode("{}") == AppSettings())
}

@Test func legacyShapesStillLoad() throws {
    // Original shape: only the first-release fields.
    let legacy = """
    {"alerts":{"urgentBelowPercent":50,"criticalBelowPercent":20,"normalInterval":600,"urgentInterval":120,"criticalInterval":60},
     "policy":{"killThresholdPercent":15,"maxKillsPerWindow":3,"killWindow":60},
     "telegram":{"isEnabled":true,"chatID":"7","silentMode":true,"includeMachineName":false},
     "launchAtLogin":true}
    """
    var expected = AppSettings()
    expected.launchAtLogin = true
    expected.telegram = TelegramPreferences(isEnabled: true, chatID: "7", silentMode: true)
    #expect(try decode(legacy) == expected)
    #expect(try decode(legacy).resetPermissionsAfterUpdates)
    // Telegram block predating the extra toggles.
    let oldTelegram = #"{"telegram":{"isEnabled":true}}"#
    #expect(try decode(oldTelegram).telegram == TelegramPreferences(isEnabled: true))
}

@Test func fullSettingsRoundTripAfterLeniency() throws {
    var settings = AppSettings()
    settings.updateChannel = .nightly
    settings.screenRecordingTarget = .allDisplays
    settings.screenRecordingFrameRate = 60
    settings.audioRecordingMicrophone = false
    settings.resetPermissionsAfterUpdates = false
    settings.keepAwakeDefaultDuration = 900
    settings.skippedVersion = "1.2.3"
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)
}

@Test @MainActor func storeKeepsPartiallyValidSettingsInsteadOfDroppingAll() throws {
    let suite = "SettingsDecodeTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let json = #"{"launchAtLogin":true,"updateChannel":"future"}"#
    defaults.set(Data(json.utf8), forKey: UserDefaultsSettingsStore.storageKey)
    let loaded = UserDefaultsSettingsStore(defaults: defaults).load()
    #expect(loaded.launchAtLogin)
    #expect(loaded.updateChannel == .stable)
}

@Test @MainActor func undecodableSettingsAreBackedUpBeforeDefaults() throws {
    let suite = "SettingsBackupTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsSettingsStore(defaults: defaults)
    let garbage = Data("not JSON".utf8)
    defaults.set(garbage, forKey: UserDefaultsSettingsStore.storageKey)
    #expect(store.load() == AppSettings())
    let domain = try #require(defaults.persistentDomain(forName: suite))
    let backups = domain.filter { $0.key.hasPrefix(UserDefaultsSettingsStore.storageKey + ".corrupt-") }
    #expect(backups.count == 1)
    #expect(backups.values.first as? Data == garbage)
    // A later save must not remove the backup.
    store.save(AppSettings())
    let after = try #require(defaults.persistentDomain(forName: suite))
    #expect(after.keys.contains { $0.hasPrefix(UserDefaultsSettingsStore.storageKey + ".corrupt-") })
}

@Test func telegramFailureCategoriesNeverIncludeDetails() {
    #expect(TelegramNotifier.failureCategory(TelegramError.invalidToken) == "invalidToken")
    #expect(TelegramNotifier.failureCategory(TelegramError.rateLimited(retryAfter: 5)) == "rateLimited")
    #expect(TelegramNotifier.failureCategory(TelegramError.network) == "network")
    #expect(TelegramNotifier.failureCategory(TelegramError.malformedResponse) == "malformedResponse")
    #expect(TelegramNotifier.failureCategory(TelegramError.apiFailure(code: 400)) == "apiFailure")
    #expect(TelegramNotifier.failureCategory(CancellationError()) == "cancelled")
    struct Other: Error, CustomStringConvertible { var description: String { "https://api/botSECRET" } }
    #expect(TelegramNotifier.failureCategory(Other()) == "unknown")
}
