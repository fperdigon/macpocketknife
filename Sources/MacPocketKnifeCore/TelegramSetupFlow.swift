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
public protocol TelegramPollingClock: Sendable {
    /// Monotonic seconds from an arbitrary origin.
    var now: TimeInterval { get }
    func sleep(for interval: TimeInterval) async throws
}

@MainActor
public struct TelegramSystemClock: TelegramPollingClock {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    public init() { origin = clock.now }

    public var now: TimeInterval {
        let elapsed = origin.duration(to: clock.now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    public func sleep(for interval: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(interval))
    }
}

public enum TelegramSetupError: Error, Sendable, Equatable, LocalizedError {
    case notValidated
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .notValidated: return "Validate the Telegram bot before continuing."
        case .timedOut: return "Timed out waiting for a new /start message."
        }
    }
}

@MainActor
public final class TelegramSetupFlow {
    private let transport: any HTTPTransport
    private let clock: any TelegramPollingClock
    private var client: TelegramClient?

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        clock: any TelegramPollingClock = TelegramSystemClock()
    ) {
        self.transport = transport
        self.clock = clock
    }

    @discardableResult
    public func validate(token: String) async throws -> TelegramBotInfo {
        client = nil
        let candidate = TelegramClient(token: token, transport: transport)
        let info = try await candidate.getMe()
        client = candidate
        return info
    }

    /// Discards the existing backlog, then accepts only a new, exact /start command.
    /// The deadline cancels in-flight transport requests as well as polling sleeps.
    /// When `expectedStartCode` is set, only `/start <code>` is accepted, so a stranger who finds
    /// the bot cannot claim ownership during setup. Without it, any exact `/start` is accepted.
    public func discoverChatID(timeout: TimeInterval = 60, expectedStartCode: String? = nil) async throws -> Int64 {
        guard let client else { throw TelegramSetupError.notValidated }
        guard timeout.isFinite, timeout > 0 else { throw TelegramSetupError.timedOut }
        let deadline = clock.now + timeout
        return try await withThrowingTaskGroup(of: Int64.self) { group in
            group.addTask {
                try await self.poll(client: client, deadline: deadline, expectedText: Self.startText(expectedStartCode))
            }
            group.addTask {
                try await self.waitForDeadline(deadline)
            }
            defer { group.cancelAll() }
            guard let chatID = try await group.next() else { throw TelegramSetupError.timedOut }
            return chatID
        }
    }

    private func waitForDeadline(_ deadline: TimeInterval) async throws -> Int64 {
        try await clock.sleep(for: max(0, deadline - clock.now))
        throw TelegramSetupError.timedOut
    }

    static func startText(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "/start" }
        return "/start " + code
    }

    private func poll(client: TelegramClient, deadline: TimeInterval, expectedText: String) async throws -> Int64 {
        try Task.checkCancellation()
        // Negative offset fetches the last pending update and forgets earlier backlog.
        let backlog = try await client.getUpdates(offset: -1)
        var offset = try nextOffset(backlog, after: nil)
        while clock.now < deadline {
            try Task.checkCancellation()
            let updates = try await client.getUpdates(offset: offset)
            guard clock.now < deadline else { throw TelegramSetupError.timedOut }
            let fresh = updates.filter { update in
                offset.map { update.updateID >= $0 } ?? true
            }
            offset = try nextOffset(updates, after: offset)
            if let message = fresh.compactMap(\.message).first(where: { $0.text == expectedText }) {
                return message.chatID
            }
            try await clock.sleep(for: min(1, max(0, deadline - clock.now)))
        }
        throw TelegramSetupError.timedOut
    }

    public func sendTestMessage(chatID: Int64) async throws {
        guard let client else { throw TelegramSetupError.notValidated }
        try await client.sendMessage(
            chatID: chatID, text: "MacPocketKnife Telegram test message.", silent: false
        )
    }

    private func nextOffset(_ updates: [TelegramUpdate], after offset: Int64?) throws -> Int64? {
        guard let last = updates.map(\.updateID).max() else { return offset }
        guard last < Int64.max else { throw TelegramError.malformedResponse }
        return max(offset ?? Int64.min, last + 1)
    }
}
