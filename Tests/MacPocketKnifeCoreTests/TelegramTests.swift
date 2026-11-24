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

actor FakeTelegramTransport: HTTPTransport {
    struct Response: Sendable {
        let status: Int
        let body: String
        let delay: TimeInterval

        init(_ body: String, status: Int = 200, delay: TimeInterval = 0) {
            self.status = status
            self.body = body
            self.delay = delay
        }
    }

    private var responses: [Response]
    private let failure: (any Error)?
    private let clock: (any TelegramPollingClock)?
    private(set) var requests: [URLRequest] = []

    init(
        _ responses: [Response] = [], failure: (any Error)? = nil,
        clock: (any TelegramPollingClock)? = nil
    ) {
        self.responses = responses
        self.failure = failure
        self.clock = clock
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let failure { throw failure }
        guard !responses.isEmpty else {
            Issue.record("Unexpected Telegram request")
            throw TelegramError.network
        }
        let response = responses.removeFirst()
        if response.delay > 0, let clock { try await clock.sleep(for: response.delay) }
        let url = try #require(request.url)
        let http = try #require(HTTPURLResponse(
            url: url, statusCode: response.status,
            httpVersion: nil, headerFields: nil
        ))
        return (Data(response.body.utf8), http)
    }
}

@MainActor
final class FakeTelegramClock: TelegramPollingClock {
    private struct Sleeper {
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, any Error>
    }

    private(set) var now: TimeInterval = 0
    private(set) var sleeps: [TimeInterval] = []
    private var sleepers: [UUID: Sleeper] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    func sleep(for interval: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = Sleeper(deadline: now + interval, continuation: continuation)
                sleeps.append(interval)
                let ready = observers.filter { sleeps.count >= $0.0 }
                observers.removeAll { sleeps.count >= $0.0 }
                for (_, observer) in ready { observer.resume() }
            }
        } onCancel: {
            Task { @MainActor in
                self.sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
            }
        }
    }

    func waitForSleepCount(_ count: Int) async {
        if sleeps.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func advance(by interval: TimeInterval) {
        now += interval
        let due = sleepers.filter { $0.value.deadline <= now }
        for (id, sleeper) in due {
            sleepers.removeValue(forKey: id)
            sleeper.continuation.resume()
        }
    }
}

// Deliberately synthetic and not shaped like a real bot credential.
private let telegramTestCredential = "synthetic-credential"
private let botEnvelope = #"{"ok":true,"result":{"id":42,"username":"example_bot"}}"#
private let emptyUpdatesEnvelope = #"{"ok":true,"result":[]}"#
private let messageEnvelope = #"{"ok":true,"result":{"chat":{"id":-42},"text":"Delivered"}}"#

private func requestBody(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func telegramParsesBotAndUpdateEnvelopes() async throws {
    let transport = FakeTelegramTransport([
        .init(botEnvelope),
        .init(#"{"ok":true,"result":[{"update_id":10,"message":{"chat":{"id":-42},"text":"/start"}},{"update_id":11,"message":{"chat":{"id":42}}},{"update_id":12,"edited_message":{}}]}"#),
    ])
    let client = TelegramClient(token: telegramTestCredential, transport: transport)
    #expect(try await client.getMe() == TelegramBotInfo(username: "example_bot", id: 42))
    #expect(try await client.getUpdates(offset: 10) == [
        TelegramUpdate(updateID: 10, message: TelegramMessage(chatID: -42, text: "/start")),
        TelegramUpdate(updateID: 11, message: TelegramMessage(chatID: 42, text: nil)),
        TelegramUpdate(updateID: 12, message: nil),
    ])
    let requests = await transport.requests
    #expect(requests.map { $0.url?.lastPathComponent } == ["getMe", "getUpdates"])
    #expect(requests.allSatisfy { $0.httpMethod == "POST" })
    #expect(requests[0].value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(try requestBody(requests[1])["offset"] as? Int == 10)
}

@Test(arguments: [401, 404]) func telegramInvalidTokenForHTTPStatus(status: Int) async {
    let transport = FakeTelegramTransport([.init("unparseable", status: status)])
    let client = TelegramClient(token: telegramTestCredential, transport: transport)
    await #expect(throws: TelegramError.invalidToken) { try await client.getMe() }
}

@Test(arguments: [401, 404, 429, 400]) func telegramParsesFailureEnvelopes(code: Int) async {
    let body = "{\"ok\":false,\"error_code\":\(code),\"description\":\"Rejected\",\"parameters\":{\"retry_after\":7}}"
    let transport = FakeTelegramTransport([.init(body)])
    let client = TelegramClient(token: telegramTestCredential, transport: transport)
    let expected: TelegramError = code == 429 ? .rateLimited(retryAfter: 7)
        : (code == 400 ? .apiFailure(code: 400) : .invalidToken)
    await #expect(throws: expected) { try await client.getMe() }
}

@Test func telegramHTTPRateLimitWithoutParameters() async {
    let transport = FakeTelegramTransport([.init("{}", status: 429)])
    let client = TelegramClient(token: telegramTestCredential, transport: transport)
    await #expect(throws: TelegramError.rateLimited(retryAfter: nil)) { try await client.getMe() }
}

@Test(arguments: [
    "not JSON", "{}", #"{"ok":true}"#, #"{"ok":true,"result":null}"#,
    #"{"ok":true,"result":{"id":"wrong","username":"example_bot"}}"#,
]) func telegramRejectsMalformedResponses(body: String) async {
    let transport = FakeTelegramTransport([.init(body)])
    let client = TelegramClient(token: telegramTestCredential, transport: transport)
    await #expect(throws: TelegramError.malformedResponse) { try await client.getMe() }
}

@Test func telegramRedactsTransportAndAPIErrorStrings() async {
    let sensitiveURL = "https://api.telegram.org/bot\(telegramTestCredential)/getMe"
    let failure = NSError(domain: "SyntheticTransport", code: 1, userInfo: [
        NSLocalizedDescriptionKey: sensitiveURL,
        NSURLErrorFailingURLStringErrorKey: sensitiveURL,
    ])
    let cases: [(FakeTelegramTransport, TelegramError)] = [
        (FakeTelegramTransport(failure: failure), .network),
        (FakeTelegramTransport([.init("invalid \(sensitiveURL)")]), .malformedResponse),
        (FakeTelegramTransport([.init("", status: 401)]), .invalidToken),
        (FakeTelegramTransport([.init("", status: 404)]), .invalidToken),
        (FakeTelegramTransport([.init("", status: 429)]), .rateLimited(retryAfter: nil)),
        (FakeTelegramTransport([.init("{\"ok\":false,\"description\":\"\(sensitiveURL)\",\"parameters\":{\"retry_after\":5}}", status: 429)]), .rateLimited(retryAfter: 5)),
        (FakeTelegramTransport([.init("{\"ok\":false,\"description\":\"\(sensitiveURL)\"}", status: 400)]), .apiFailure(code: 400)),
    ]
    for (transport, expected) in cases {
        do {
            _ = try await TelegramClient(token: telegramTestCredential, transport: transport).getMe()
            Issue.record("Expected a Telegram error")
        } catch {
            #expect(error as? TelegramError == expected)
            let strings = [String(describing: error), String(reflecting: error), error.localizedDescription,
                           (error as NSError).description, (error as? LocalizedError)?.errorDescription ?? ""]
            #expect(strings.allSatisfy { !$0.contains(telegramTestCredential) && !$0.contains(sensitiveURL) })
        }
    }
}

@Test(arguments: ["", "invalid/value", "invalid?value", "invalid value"])
func telegramRejectsUnsafeTokenBeforeTransport(token: String) async {
    let transport = FakeTelegramTransport()
    await #expect(throws: TelegramError.invalidToken) {
        try await TelegramClient(token: token, transport: transport).getMe()
    }
    #expect(await transport.requests.isEmpty)
}

@Test(arguments: [false, true]) func telegramChannelUsesNormalDeliveryAndSilentFlag(silent: Bool) async throws {
    let transport = FakeTelegramTransport([.init(messageEnvelope)])
    let channel = TelegramChannel(
        client: TelegramClient(token: telegramTestCredential, transport: transport), chatID: -42
    )
    let alert = BatteryAlert(level: .critical, batteryPercent: 12)
    try await channel.send(alert: alert, blockers: ["caffeinate"], silent: silent)
    let request = try #require(await transport.requests.first)
    let body = try requestBody(request)
    #expect(Set(body.keys) == ["chat_id", "text", "disable_notification"])
    #expect(body["chat_id"] as? Int64 == -42)
    #expect(body["disable_notification"] as? Bool == silent)
    #expect(body["text"] as? String == TelegramAlertFormatter().format(alert: alert, blockers: ["caffeinate"]))
}

@Test(arguments: [AlertLevel.normal, .urgent, .critical])
func telegramFormatsEveryAlertLevelWithoutMachineName(level: AlertLevel) {
    let text = TelegramAlertFormatter().format(
        alert: BatteryAlert(level: level, batteryPercent: 25), blockers: ["caffeinate", "MediaPlayer"]
    )
    let wording: String
    switch level {
    case .normal: wording = "Normal"
    case .urgent: wording = "Urgent"
    case .critical: wording = "Critical"
    }
    #expect(text == "\(wording): battery at 25%. Keeping the Mac awake: caffeinate.")
}

@Test func telegramMachineNameIsExplicitOptInAndMissingBlockersHaveFallback() {
    let formatter = TelegramAlertFormatter()
    let alert = BatteryAlert(level: .normal, batteryPercent: 80)
    #expect(formatter.format(alert: alert) == "Normal: battery at 80%. Keeping the Mac awake: caffeinate or the app's own keep-awake.")
    #expect(formatter.format(alert: alert, blockers: []) == formatter.format(alert: alert))
    #expect(formatter.format(alert: alert, includeMachineName: "Example Mac").contains("(Example Mac)"))
}

@Test @MainActor func telegramDiscoverySkipsBacklogAndAdvancesEveryUpdate() async throws {
    let transport = FakeTelegramTransport([
        .init(botEnvelope),
        .init(#"{"ok":true,"result":[{"update_id":10,"message":{"chat":{"id":1},"text":"/start"}}]}"#),
        .init(#"{"ok":true,"result":[{"update_id":10,"message":{"chat":{"id":1},"text":"/start"}},{"update_id":11,"message":{"chat":{"id":1},"text":"hello"}},{"update_id":12}]}"#),
        .init(#"{"ok":true,"result":[{"update_id":13,"message":{"chat":{"id":-42},"text":"/start"}}]}"#),
        .init(messageEnvelope),
    ])
    let clock = FakeTelegramClock()
    let flow = TelegramSetupFlow(transport: transport, clock: clock)
    #expect(try await flow.validate(token: telegramTestCredential).id == 42)
    let discovery = Task { try await flow.discoverChatID(timeout: 10) }
    await clock.waitForSleepCount(2)
    clock.advance(by: 1)
    #expect(try await discovery.value == -42)
    try await flow.sendTestMessage(chatID: -42)
    let requests = await transport.requests
    let offsets = try requests.filter { $0.url?.lastPathComponent == "getUpdates" }.map {
        try requestBody($0)["offset"] as? Int
    }
    #expect(offsets == [-1, 11, 13])
    #expect(clock.sleeps.sorted() == [1, 10])
    let testBody = try requestBody(#require(requests.last))
    #expect(testBody["chat_id"] as? Int64 == -42)
    #expect(testBody["disable_notification"] as? Bool == false)
}

@Test @MainActor func telegramDiscoveryTimesOutUsingInjectedClock() async throws {
    let transport = FakeTelegramTransport([
        .init(botEnvelope), .init(emptyUpdatesEnvelope),
        .init(#"{"ok":true,"result":[{"update_id":1,"message":{"chat":{"id":1},"text":"/start extra"}}]}"#),
        .init(emptyUpdatesEnvelope), .init(emptyUpdatesEnvelope),
    ])
    let clock = FakeTelegramClock()
    let flow = TelegramSetupFlow(transport: transport, clock: clock)
    try await flow.validate(token: telegramTestCredential)
    let discovery = Task { try await flow.discoverChatID(timeout: 2.5) }
    await clock.waitForSleepCount(2)
    clock.advance(by: 1)
    await clock.waitForSleepCount(3)
    clock.advance(by: 1)
    await clock.waitForSleepCount(4)
    clock.advance(by: 0.5)
    await #expect(throws: TelegramSetupError.timedOut) { try await discovery.value }
    #expect(clock.now == 2.5)
    #expect(clock.sleeps.sorted() == [0.5, 1, 1, 2.5])
    let requests = await transport.requests
    #expect(requests.count == 5)
    #expect(try requestBody(requests[3])["offset"] as? Int == 2)
}

@Test @MainActor func telegramSetupRequiresValidationAndClearsFailedCredentials() async throws {
    let transport = FakeTelegramTransport([.init(botEnvelope), .init("", status: 401)])
    let flow = TelegramSetupFlow(transport: transport, clock: FakeTelegramClock())
    await #expect(throws: TelegramSetupError.notValidated) { try await flow.discoverChatID() }
    await #expect(throws: TelegramSetupError.notValidated) { try await flow.sendTestMessage(chatID: 1) }
    try await flow.validate(token: telegramTestCredential)
    await #expect(throws: TelegramError.invalidToken) { try await flow.validate(token: telegramTestCredential) }
    await #expect(throws: TelegramSetupError.notValidated) { try await flow.sendTestMessage(chatID: 1) }
}

@Test @MainActor func telegramDiscoveryDeadlineCancelsAnInFlightRequest() async throws {
    let clock = FakeTelegramClock()
    let transport = FakeTelegramTransport([
        .init(botEnvelope), .init(emptyUpdatesEnvelope, delay: 100),
    ], clock: clock)
    let flow = TelegramSetupFlow(transport: transport, clock: clock)
    try await flow.validate(token: telegramTestCredential)
    let discovery = Task { try await flow.discoverChatID(timeout: 10) }
    await clock.waitForSleepCount(2)
    clock.advance(by: 10)
    await #expect(throws: TelegramSetupError.timedOut) { try await discovery.value }
    #expect(clock.sleeps.sorted() == [10, 100])
    #expect(await transport.requests.count == 2)
}

@Test @MainActor func telegramDiscoveryPropagatesCancellation() async throws {
    let clock = FakeTelegramClock()
    let transport = FakeTelegramTransport([
        .init(botEnvelope), .init(emptyUpdatesEnvelope), .init(emptyUpdatesEnvelope),
    ])
    let flow = TelegramSetupFlow(transport: transport, clock: clock)
    try await flow.validate(token: telegramTestCredential)
    let discovery = Task { try await flow.discoverChatID() }
    await clock.waitForSleepCount(2)
    discovery.cancel()
    await #expect(throws: CancellationError.self) { try await discovery.value }
    #expect(clock.now == 0)
}

@Test(arguments: [0.0, -1, Double.nan, Double.infinity])
@MainActor func telegramDiscoveryRejectsInvalidTimeout(timeout: TimeInterval) async throws {
    let transport = FakeTelegramTransport([.init(botEnvelope)])
    let flow = TelegramSetupFlow(transport: transport, clock: FakeTelegramClock())
    try await flow.validate(token: telegramTestCredential)
    await #expect(throws: TelegramSetupError.timedOut) { try await flow.discoverChatID(timeout: timeout) }
    #expect(await transport.requests.count == 1)
}

@Test @MainActor func telegramDiscoveryWithStartCodeIgnoresStrangers() async throws {
    let code = "pair-" + String(UUID().uuidString.prefix(6))
    let first = #"{"ok":true,"result":[{"update_id":1,"message":{"chat":{"id":5},"text":"/start"}},{"update_id":2,"message":{"chat":{"id":6},"text":"/start wrong"}}]}"#
    let second = #"{"ok":true,"result":[{"update_id":3,"message":{"chat":{"id":7},"text":"/start \#(code)"}}]}"#
    let transport = FakeTelegramTransport([
        .init(botEnvelope), .init(emptyUpdatesEnvelope), .init(first), .init(second),
    ])
    let clock = FakeTelegramClock()
    let flow = TelegramSetupFlow(transport: transport, clock: clock)
    try await flow.validate(token: telegramTestCredential)
    let discovery = Task { try await flow.discoverChatID(timeout: 10, expectedStartCode: code) }
    await clock.waitForSleepCount(2)
    clock.advance(by: 1)
    #expect(try await discovery.value == 7)
    #expect(TelegramSetupFlow.startText(nil) == "/start")
    #expect(TelegramSetupFlow.startText("") == "/start")
}
