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
import MacPocketKnifeCore

@MainActor
private final class InMemorySettingsStore: SettingsStore {
    private(set) var data: Data?
    private(set) var saveCount = 0

    func load() -> AppSettings {
        data.flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
    }

    func save(_ settings: AppSettings) {
        data = try? JSONEncoder().encode(settings)
        saveCount += 1
    }
}

@Test func appSettingsDefaultsMatchPlan() {
    let settings = AppSettings()
    #expect(settings.alerts.urgentBelowPercent == 50)
    #expect(settings.alerts.criticalBelowPercent == 20)
    #expect(settings.alerts.normalInterval == 600)
    #expect(settings.alerts.urgentInterval == 120)
    #expect(settings.alerts.criticalInterval == 60)
    #expect(settings.policy.killThresholdPercent == 15)
    #expect(settings.keepAwakeDefaultDuration == nil)
    #expect(!settings.launchAtLogin)
    #expect(!settings.telegram.isEnabled)
    #expect(settings.telegram.chatID == nil)
    #expect(!settings.telegram.silentMode)
    #expect(!settings.telegram.includeMachineName)
    #expect(settings.validated() == settings)
}

@Test func appSettingsJSONRoundTrip() throws {
    let settings = AppSettings(
        alerts: AlertSettings(urgentBelowPercent: 60, criticalBelowPercent: 30,
                              normalInterval: 900, urgentInterval: 180, criticalInterval: 90),
        policy: PolicySettings(killThresholdPercent: 10), keepAwakeDefaultDuration: 1800,
        telegram: TelegramPreferences(isEnabled: true, chatID: "-42", silentMode: true,
                                      includeMachineName: true), launchAtLogin: true
    )
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)
}

@Test @MainActor func userDefaultsSettingsRoundTripAndCorruptFallback() throws {
    let suite = "SettingsTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsSettingsStore(defaults: defaults)
    #expect(store.load() == AppSettings())
    var settings = AppSettings()
    settings.launchAtLogin = true
    settings.telegram = TelegramPreferences(isEnabled: true, chatID: "-42")
    store.save(settings)
    #expect(UserDefaultsSettingsStore(defaults: defaults).load() == settings)
    let domain = try #require(defaults.persistentDomain(forName: suite))
    #expect(Set(domain.keys) == [UserDefaultsSettingsStore.storageKey])
    for corrupt in ["not JSON", "{}", #"{"alerts":"invalid"}"#] {
        defaults.set(Data(corrupt.utf8), forKey: UserDefaultsSettingsStore.storageKey)
        #expect(store.load() == AppSettings())
    }
    defaults.set("wrong type", forKey: UserDefaultsSettingsStore.storageKey)
    #expect(store.load() == AppSettings())
}

@Test(arguments: [0, 1, 100, Int.min, Int.max])
func appSettingsValidationClampsThresholdsAndIntervals(percent: Int) {
    let settings = AppSettings(
        alerts: AlertSettings(urgentBelowPercent: percent, criticalBelowPercent: percent,
                              normalInterval: 1, urgentInterval: 2, criticalInterval: 3),
        policy: PolicySettings(killThresholdPercent: percent, maxKillsPerWindow: -1, killWindow: 1),
        keepAwakeDefaultDuration: -1
    ).validated()
    #expect((1...100).contains(settings.alerts.criticalBelowPercent))
    #expect((1...100).contains(settings.alerts.urgentBelowPercent))
    #expect(settings.alerts.criticalBelowPercent < settings.alerts.urgentBelowPercent)
    #expect(settings.alerts.normalInterval == 10)
    #expect(settings.alerts.urgentInterval == 10)
    #expect(settings.alerts.criticalInterval == 10)
    #expect(settings.policy.killThresholdPercent == min(50, max(5, percent)))
    #expect(settings.policy.killWindow == 10)
    #expect(settings.policy.maxKillsPerWindow == 0)
    #expect(settings.keepAwakeDefaultDuration == 10)
    #expect(settings.validated() == settings)
}

@Test(arguments: [Double.nan, Double.infinity, -Double.infinity])
func appSettingsValidationHandlesNonfiniteDuration(duration: Double) {
    #expect(AppSettings(keepAwakeDefaultDuration: duration).validated().keepAwakeDefaultDuration == nil)
}

@Test func appSettingsValidationRepairsDecodedValues() throws {
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any])
    json["alerts"] = ["urgentBelowPercent": -100, "criticalBelowPercent": 200,
                      "normalInterval": -10, "urgentInterval": 0, "criticalInterval": 1]
    json["policy"] = ["killThresholdPercent": 200, "maxKillsPerWindow": -3, "killWindow": -1]
    let settings = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json)).validated()
    #expect(settings.alerts.urgentBelowPercent == 2)
    #expect(settings.alerts.criticalBelowPercent == 1)
    #expect(settings.alerts.normalInterval == 10)
    #expect(settings.policy.killThresholdPercent == 50)
    #expect(settings.policy.maxKillsPerWindow == 0)
}

@Test @MainActor func settingsModelPersistsValidatedChangesAndResetsAlerts() {
    let store = InMemorySettingsStore()
    let model = SettingsModel(store: store, secrets: InMemorySecretStore(),
                              transport: FakeTelegramTransport(), clock: FakeTelegramClock())
    #expect(store.saveCount == 0)
    model.settings.launchAtLogin = true
    #expect(store.load().launchAtLogin)
    model.settings.alerts = AlertSettings(normalInterval: 1)
    #expect(model.settings.alerts.normalInterval == 10)
    #expect(store.load() == model.settings)
    model.resetAlertsToDefaults()
    #expect(store.load().alerts == AlertSettings())
    #expect(store.load().launchAtLogin)
}

@Test @MainActor func settingsModelKeepAwakeTogglePersistsDuration() {
    let store = InMemorySettingsStore()
    let model = SettingsModel(store: store, secrets: InMemorySecretStore(),
                              transport: FakeTelegramTransport(), clock: FakeTelegramClock())
    #expect(model.keepAwakeIndefinitely)
    model.keepAwakeIndefinitely = false
    #expect(model.settings.keepAwakeDefaultDuration == 3600)
    #expect(store.load().keepAwakeDefaultDuration == 3600)
    model.settings.keepAwakeDefaultDuration = 1800
    #expect(!model.keepAwakeIndefinitely)
    model.keepAwakeIndefinitely = true
    #expect(model.settings.keepAwakeDefaultDuration == nil)
    #expect(store.load().keepAwakeDefaultDuration == nil)
}

@Test @MainActor func settingsModelSavesTokenOnlyInSecretStoreAndSendsSilently() async throws {
    let credential = "synthetic-settings-credential"
    let transport = FakeTelegramTransport([
        .init(#"{"ok":true,"result":{"id":42,"username":"example_bot"}}"#),
        .init(#"{"ok":true,"result":{"chat":{"id":-42},"text":"Delivered"}}"#),
    ])
    let store = InMemorySettingsStore()
    let secrets = InMemorySecretStore()
    let model = SettingsModel(store: store, secrets: secrets, transport: transport, clock: FakeTelegramClock())
    model.settings.telegram.isEnabled = true
    try await model.validateAndSaveTelegramToken(credential)
    #expect(try secrets.secret(for: .telegramBotToken) == credential)
    model.settings.telegram.chatID = "-42"
    model.settings.telegram.silentMode = true
    try await model.sendTelegramTestMessage()
    let json = String(decoding: try #require(store.data), as: UTF8.self)
    #expect(!json.contains(credential))
    #expect(!json.lowercased().contains("token"))
    let request = try #require(await transport.requests.last)
    let requestData = try #require(request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
    #expect(body["disable_notification"] as? Bool == true)
    #expect(body["chat_id"] as? Int == -42)
}

@Test @MainActor func settingsModelFailedValidationPreservesSavedSecret() async throws {
    let secrets = InMemorySecretStore()
    try secrets.setSecret("previous-synthetic-credential", for: .telegramBotToken)
    let model = SettingsModel(store: InMemorySettingsStore(), secrets: secrets,
                              transport: FakeTelegramTransport([.init("", status: 401)]), clock: FakeTelegramClock())
    model.settings.telegram.isEnabled = true
    await #expect(throws: TelegramError.invalidToken) {
        try await model.validateAndSaveTelegramToken("rejected-synthetic-credential")
    }
    #expect(try secrets.secret(for: .telegramBotToken) == "previous-synthetic-credential")
}

@Test @MainActor func settingsModelDisabledTelegramDoesNotUseTransport() async {
    let transport = FakeTelegramTransport()
    let model = SettingsModel(store: InMemorySettingsStore(), secrets: InMemorySecretStore(),
                              transport: transport, clock: FakeTelegramClock())
    await #expect(throws: SettingsSetupError.telegramDisabled) {
        try await model.validateAndSaveTelegramToken("synthetic-credential")
    }
    await #expect(throws: SettingsSetupError.telegramDisabled) { try await model.discoverTelegramChatID() }
    await #expect(throws: SettingsSetupError.telegramDisabled) { try await model.sendTelegramTestMessage() }
    #expect(await transport.requests.isEmpty)
}

@Test @MainActor func settingsModelDiscoversAndPersistsChatAfterRestart() async throws {
    let secrets = InMemorySecretStore()
    try secrets.setSecret("synthetic-credential", for: .telegramBotToken)
    let store = InMemorySettingsStore()
    var settings = AppSettings()
    settings.telegram.isEnabled = true
    store.save(settings)
    let transport = FakeTelegramTransport([
        .init(#"{"ok":true,"result":{"id":42,"username":"example_bot"}}"#),
        .init(#"{"ok":true,"result":[]}"#),
        .init(#"{"ok":true,"result":[{"update_id":1,"message":{"chat":{"id":-42},"text":"/start"}}]}"#),
    ])
    let model = SettingsModel(store: store, secrets: secrets, transport: transport, clock: FakeTelegramClock())
    #expect(try await model.discoverTelegramChatID() == "-42")
    #expect(store.load().telegram.chatID == "-42")
}

@Test func otherSleepBlockersSettingMigratesAndRoundTrips() throws {
    let original = AppSettings()
    #expect(!original.showOtherSleepBlockers)
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    json.removeValue(forKey: "showOtherSleepBlockers")
    let legacy = try JSONSerialization.data(withJSONObject: json)
    #expect(try JSONDecoder().decode(AppSettings.self, from: legacy) == original)
    json["showOtherSleepBlockers"] = NSNull()
    let null = try JSONSerialization.data(withJSONObject: json)
    #expect(try JSONDecoder().decode(AppSettings.self, from: null) == original)
    let enabled = AppSettings(showOtherSleepBlockers: true)
    let encoded = try JSONEncoder().encode(enabled)
    #expect(try JSONDecoder().decode(AppSettings.self, from: encoded) == enabled)
}

@Test @MainActor func screenRecordingDisplayPreferences() {
    let store = InMemorySettingsStore()
    let model = SettingsModel(store: store, secrets: InMemorySecretStore())
    let display = DisplayInfo(uuid: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", name: "Studio",
                              pixelWidth: 1920, pixelHeight: 1080, isMain: false)
    model.connectedRecordingDisplays = [display]
    model.recordingTargetSelection = .display(uuid: display.uuid)
    #expect(model.recordingTargetSelection == .display(uuid: display.uuid))
    #expect(model.settings.screenRecordingDisplayName == "Studio")
    #expect(model.disconnectedRecordingDisplayName == nil)
    model.connectedRecordingDisplays = []
    #expect(model.disconnectedRecordingDisplayName == "Studio")
    model.settings.screenRecordingDisplayName = nil
    #expect(model.disconnectedRecordingDisplayName == "Saved display")
    model.recordingTargetSelection = .allDisplays
    #expect(model.settings.screenRecordingDisplayName == nil)
    #expect(model.disconnectedRecordingDisplayName == nil)
    model.recordingTargetSelection = .display(uuid: display.uuid)
    #expect(model.settings.screenRecordingDisplayName == nil)
}
