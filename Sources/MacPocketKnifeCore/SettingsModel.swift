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

import Combine
import Foundation
import ServiceManagement

public enum SettingsSetupError: Error, Sendable, Equatable, LocalizedError {
    case telegramDisabled
    case missingToken
    case missingChatID

    public var errorDescription: String? {
        switch self {
        case .telegramDisabled: return "Enable Telegram before setting up the bot."
        case .missingToken: return "Validate and save a bot token first."
        case .missingChatID: return "Discover or enter a valid chat ID first."
        }
    }
}

@MainActor
public final class SettingsModel: ObservableObject {
    @Published public var settings: AppSettings {
        didSet {
            let validated = settings.validated()
            if settings != validated { settings = validated }
            store.save(settings)
        }
    }

    @Published public var dictationHotkeyError: String?
    @Published public var screenRecordingHotkeyError: String?

    public var dictationLanguageSelection: String {
        get { settings.dictationLanguage ?? "" }
        set { settings.dictationLanguage = newValue.isEmpty ? nil : newValue }
    }

    @Published public private(set) var launchAtLoginStatus: String?

    // Computed properties let SwiftUI use key-path bindings without converting
    // actor-isolated Bool setters into Binding closures on older compilers.
    public var keepAwakeIndefinitely: Bool {
        get { settings.keepAwakeDefaultDuration == nil }
        set { settings.keepAwakeDefaultDuration = newValue ? nil : 3600 }
    }

    public var launchAtLogin: Bool {
        get { settings.launchAtLogin }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                settings.launchAtLogin = newValue
                if SMAppService.mainApp.status == .requiresApproval {
                    launchAtLoginStatus = "Allow launch at login in System Settings > General > Login Items."
                }
            } catch {
                settings.launchAtLogin = SMAppService.mainApp.status == .enabled
                launchAtLoginStatus = "Could not change launch at login. Check System Settings > General > Login Items."
            }
        }
    }

    private let store: any SettingsStore
    private let secrets: any SecretStore
    private let transport: any HTTPTransport
    private let setupFlow: TelegramSetupFlow

    public init(
        store: any SettingsStore, secrets: any SecretStore,
        transport: any HTTPTransport = URLSessionTransport(),
        clock: any TelegramPollingClock = TelegramSystemClock()
    ) {
        self.store = store
        self.secrets = secrets
        self.transport = transport
        self.setupFlow = TelegramSetupFlow(transport: transport, clock: clock)
        self.settings = store.load().validated()
    }

    public func resetAlertsToDefaults() {
        settings.alerts = AlertSettings()
    }

    @discardableResult
    public func validateAndSaveTelegramToken(_ token: String) async throws -> TelegramBotInfo {
        try requireTelegramEnabled()
        let info = try await setupFlow.validate(token: token)
        try Task.checkCancellation()
        try requireTelegramEnabled()
        try secrets.setSecret(token, for: .telegramBotToken)
        settings.telegram.chatID = nil
        return info
    }

    /// Revalidates the saved credential so discovery also works after restarting.
    @discardableResult
    public func discoverTelegramChatID(timeout: TimeInterval = 60) async throws -> String {
        try requireTelegramEnabled()
        let token = try savedToken()
        try await setupFlow.validate(token: token)
        let chatID = try await setupFlow.discoverChatID(timeout: timeout)
        try Task.checkCancellation()
        try requireTelegramEnabled()
        let value = String(chatID)
        settings.telegram.chatID = value
        return value
    }

    public func sendTelegramTestMessage() async throws {
        try requireTelegramEnabled()
        guard let value = settings.telegram.chatID, let chatID = Int64(value) else {
            throw SettingsSetupError.missingChatID
        }
        let client = TelegramClient(token: try savedToken(), transport: transport)
        try await client.sendMessage(
            chatID: chatID, text: "MacPocketKnife Telegram test message.",
            silent: settings.telegram.silentMode
        )
    }

    private func savedToken() throws -> String {
        guard let token = try secrets.secret(for: .telegramBotToken), !token.isEmpty else {
            throw SettingsSetupError.missingToken
        }
        return token
    }

    private func requireTelegramEnabled() throws {
        guard settings.telegram.isEnabled else { throw SettingsSetupError.telegramDisabled }
    }
}
