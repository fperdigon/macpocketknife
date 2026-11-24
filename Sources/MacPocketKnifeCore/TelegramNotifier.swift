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

@MainActor
public final class TelegramNotifier: AlertNotifying {
    private let settings: any AssistantSettingsProviding
    private let secrets: any SecretStore
    private let transport: any HTTPTransport
    private let machineName: @MainActor @Sendable () -> String?

    public init(
        settings: any AssistantSettingsProviding, secrets: any SecretStore,
        transport: any HTTPTransport = URLSessionTransport(),
        machineName: @escaping @MainActor @Sendable () -> String? = { Host.current().localizedName }
    ) {
        self.settings = settings
        self.secrets = secrets
        self.transport = transport
        self.machineName = machineName
    }

    public nonisolated var deliversRemotely: Bool { true }

    /// Coarse failure category only: never the token, URL, chat or message text.
    nonisolated static func failureCategory(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        guard let failure = error as? TelegramError else { return "unknown" }
        switch failure {
        case .invalidToken: return "invalidToken"
        case .rateLimited: return "rateLimited"
        case .network: return "network"
        case .malformedResponse: return "malformedResponse"
        case .apiFailure: return "apiFailure"
        }
    }

    public func deliver(_ notice: Notice) async {
        let preferences = settings.settings.telegram
        guard preferences.isEnabled, let value = preferences.chatID,
              let chatID = Int64(value) else { return }
        do {
            guard let token = try secrets.secret(for: .telegramBotToken), !token.isEmpty else { return }
            let channel = TelegramChannel(
                client: TelegramClient(token: token, transport: transport), chatID: chatID,
                includeMachineName: preferences.includeMachineName ? machineName() : nil
            )
            try await channel.send(notice: notice, silent: preferences.silentMode)
        } catch {
            // Log a fixed category only; arbitrary errors can carry the credential-bearing URL.
            AppLog.shared.warning(
                category: "telegram", "Delivery failed category=\(Self.failureCategory(error))"
            )
        }
    }
}
