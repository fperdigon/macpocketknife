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

@MainActor
private final class NotifierSettings: AssistantSettingsProviding {
    var settings = AppSettings()
}

@MainActor
private final class DeliveredNotices: AlertNotifying {
    var values: [Notice] = []
    var onDelivery: (@MainActor () -> Void)?
    func deliver(_ notice: Notice) async {
        values.append(notice)
        onDelivery?()
    }
}

/// Captures fire-and-forget remote deliveries so tests can await them deterministically.
private final class RemoteTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    var dispatch: CompositeNotifier.RemoteDispatch {
        { [self] work in
            let task = Task { await work() }
            lock.lock(); tasks.append(task); lock.unlock()
        }
    }
    private func take() -> [Task<Void, Never>] {
        lock.lock(); defer { lock.unlock() }
        let pending = tasks
        tasks = []
        return pending
    }
    func drain() async {
        let pending = take()
        for task in pending { await task.value }
    }
}

private let notifierNotice = Notice(kind: .info, title: "Keep-awake status", body: "Sleep assertion released.")

@Test(arguments: ["disabled", "missing token", "missing chat", "transport failure"])
@MainActor func telegramUnavailableNeverAffectsLocalDelivery(scenario: String) async throws {
    let settings = NotifierSettings()
    settings.settings.telegram = TelegramPreferences(isEnabled: scenario != "disabled", chatID: "-42")
    if scenario == "missing chat" { settings.settings.telegram.chatID = nil }
    let secrets = InMemorySecretStore()
    if scenario != "missing token" { try secrets.setSecret("synthetic-credential", for: .telegramBotToken) }
    let transport = FakeTelegramTransport(failure: TelegramError.network)
    let local = DeliveredNotices()
    let telegram = TelegramNotifier(settings: settings, secrets: secrets, transport: transport,
                                    machineName: { Issue.record("Machine name is opt-in"); return nil })
    // Telegram comes first deliberately: local must still receive every notice.
    let remote = RemoteTasks()
    await CompositeNotifier(channels: [telegram, local], dispatchRemote: remote.dispatch).deliver(notifierNotice)
    #expect(local.values == [notifierNotice])
    await remote.drain()
    #expect(await transport.requests.count == (scenario == "transport failure" ? 1 : 0))
}

@Test @MainActor func telegramUsesCurrentPreferencesAndComposedNotice() async throws {
    let settings = NotifierSettings()
    let secrets = InMemorySecretStore()
    try secrets.setSecret("synthetic-credential", for: .telegramBotToken)
    let response = #"{"ok":true,"result":{"chat":{"id":-42},"text":"Delivered"}}"#
    let transport = FakeTelegramTransport([.init(response), .init(response)])
    let notifier = TelegramNotifier(settings: settings, secrets: secrets, transport: transport,
                                   machineName: { "Example Mac" })
    await notifier.deliver(notifierNotice)
    #expect(await transport.requests.isEmpty)
    settings.settings.telegram = TelegramPreferences(isEnabled: true, chatID: "-42", silentMode: true)
    await notifier.deliver(notifierNotice)
    settings.settings.telegram.silentMode = false
    settings.settings.telegram.includeMachineName = true
    await notifier.deliver(notifierNotice)
    let requests = await transport.requests
    #expect(requests.count == 2)
    let firstData = try #require(requests[0].httpBody)
    let secondData = try #require(requests[1].httpBody)
    let first = try #require(JSONSerialization.jsonObject(with: firstData) as? [String: Any])
    let second = try #require(JSONSerialization.jsonObject(with: secondData) as? [String: Any])
    #expect(first["disable_notification"] as? Bool == true)
    #expect(first["text"] as? String == "Keep-awake status\nSleep assertion released.")
    #expect(second["disable_notification"] as? Bool == false)
    #expect(second["text"] as? String == "Keep-awake status (Example Mac)\nSleep assertion released.")
}

@MainActor
private final class SuspendedNotifier: AlertNotifying {
    var continuation: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?
    func deliver(_ notice: Notice) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started?.resume()
            started = nil
        }
    }
}

@MainActor
private final class StubRemote: AlertNotifying {
    nonisolated var deliversRemotely: Bool { true }
    var started = false
    var continuation: CheckedContinuation<Void, Never>?
    func deliver(_ notice: Notice) async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
}

@Test @MainActor func compositeNeverWaitsForSuspendedRemoteChannel() async {
    let remote = StubRemote()
    let local = DeliveredNotices()
    let tasks = RemoteTasks()
    // Returns even though the remote channel never completes (fire-and-forget).
    await CompositeNotifier(channels: [remote, local], dispatchRemote: tasks.dispatch).deliver(notifierNotice)
    #expect(local.values == [notifierNotice])
    while remote.continuation == nil { await Task.yield() }
    #expect(remote.started)
    remote.continuation?.resume()
    await tasks.drain()
}

@Test @MainActor func compositeDefaultDispatchDeliversRemoteDetached() async {
    let remote = DeliveredRemote()
    await CompositeNotifier(channels: [remote]).deliver(notifierNotice)
    while remote.values.isEmpty { await Task.yield() }
    #expect(remote.values == [notifierNotice])
}

@MainActor
private final class DeliveredRemote: AlertNotifying {
    nonisolated var deliversRemotely: Bool { true }
    var values: [Notice] = []
    func deliver(_ notice: Notice) async { values.append(notice) }
}

@Test func localChannelsAreNotRemoteByDefault() {
    #expect(LocalDefault().deliversRemotely == false)
}

private struct LocalDefault: AlertNotifying {
    func deliver(_ notice: Notice) async {}
}

@Test @MainActor func telegramNotifierIsRemote() {
    let notifier = TelegramNotifier(settings: NotifierSettings(), secrets: InMemorySecretStore())
    #expect(notifier.deliversRemotely)
}

@Test func transportTimeoutIsExplicit() throws {
    let session = URLSessionTransport.makeSession()
    #expect(session.configuration.timeoutIntervalForRequest == 10)
    #expect(session.configuration.timeoutIntervalForResource == 20)
    #expect(URLSessionTransport.defaultRequestTimeout == 10)
    let custom = URLSessionTransport.makeSession(requestTimeout: 3)
    #expect(custom.configuration.timeoutIntervalForRequest == 3)
}

@Test func transportStampsRequestTimeout() throws {
    let url = try #require(URL(string: "https://example.invalid/x"))
    let transport = URLSessionTransport(requestTimeout: 4)
    #expect(transport.timed(URLRequest(url: url)).timeoutInterval == 4)
}
