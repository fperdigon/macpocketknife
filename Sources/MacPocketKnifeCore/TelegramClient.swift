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

public enum TelegramError: Error, Sendable, Equatable, LocalizedError, CustomStringConvertible {
    case invalidToken
    case rateLimited(retryAfter: Int?)
    case network
    case malformedResponse
    case apiFailure(code: Int?)

    public var description: String {
        switch self {
        case .invalidToken: return "The Telegram bot token is invalid."
        case .rateLimited(let seconds):
            if let seconds { return "Telegram rate limit reached. Retry after \(seconds) seconds." }
            return "Telegram rate limit reached."
        case .network: return "The Telegram request could not be completed."
        case .malformedResponse: return "Telegram returned a malformed response."
        case .apiFailure: return "Telegram rejected the request."
        }
    }

    public var errorDescription: String? { description }
}

public struct TelegramBotInfo: Decodable, Sendable, Equatable {
    public let username: String
    public let id: Int64

    public init(username: String, id: Int64) {
        self.username = username
        self.id = id
    }
}

public struct TelegramMessage: Decodable, Sendable, Equatable {
    public let chatID: Int64
    public let text: String?

    private enum CodingKeys: String, CodingKey { case chat, text }
    private struct Chat: Decodable { let id: Int64 }

    public init(chatID: Int64, text: String?) {
        self.chatID = chatID
        self.text = text
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chatID = try container.decode(Chat.self, forKey: .chat).id
        text = try container.decodeIfPresent(String.self, forKey: .text)
    }
}

public struct TelegramUpdate: Decodable, Sendable, Equatable {
    public let updateID: Int64
    public let message: TelegramMessage?

    private enum CodingKeys: String, CodingKey {
        case updateID = "update_id"
        case message
    }

    public init(updateID: Int64, message: TelegramMessage?) {
        self.updateID = updateID
        self.message = message
    }
}

public protocol TelegramServing: Sendable {
    func getMe() async throws -> TelegramBotInfo
    func getUpdates(offset: Int64?) async throws -> [TelegramUpdate]
    func sendMessage(chatID: Int64, text: String, silent: Bool) async throws
}

public struct TelegramClient: TelegramServing {
    private let token: String
    private let transport: any HTTPTransport

    public init(token: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.token = token
        self.transport = transport
    }

    public func getMe() async throws -> TelegramBotInfo {
        try await call("getMe", body: EmptyBody())
    }

    public func getUpdates(offset: Int64? = nil) async throws -> [TelegramUpdate] {
        try await call("getUpdates", body: UpdatesBody(offset: offset))
    }

    public func sendMessage(chatID: Int64, text: String, silent: Bool = false) async throws {
        do {
            let _: TelegramMessage = try await call(
                "sendMessage", body: MessageBody(chatID: chatID, text: text, disableNotification: silent)
            )
            AppLog.shared.info(category: "telegram", "Send succeeded status=ok")
        } catch {
            // TelegramError contains safe categories; never inspect arbitrary error descriptions.
            let status: String
            switch error {
            case TelegramError.invalidToken: status = "invalidToken"
            case TelegramError.rateLimited: status = "rateLimited"
            case TelegramError.network: status = "network"
            case TelegramError.malformedResponse: status = "malformedResponse"
            case TelegramError.apiFailure: status = "apiFailure"
            case is CancellationError: status = "cancelled"
            default: status = "unknown"
            }
            AppLog.shared.warning(category: "telegram", "Send failed status=\(status)")
            throw error
        }
    }

    private struct EmptyBody: Encodable {}
    private struct UpdatesBody: Encodable { let offset: Int64? }
    private struct MessageBody: Encodable {
        let chatID: Int64
        let text: String
        let disableNotification: Bool

        private enum CodingKeys: String, CodingKey {
            case chatID = "chat_id"
            case text
            case disableNotification = "disable_notification"
        }
    }
    private struct Envelope<Result: Decodable>: Decodable {
        let ok: Bool
        let result: Result?
    }
    private struct Parameters: Decodable {
        let retryAfter: Int?

        private enum CodingKeys: String, CodingKey {
            case retryAfter = "retry_after"
        }
    }
    private struct FailureEnvelope: Decodable {
        let ok: Bool
        let errorCode: Int?
        let description: String?
        let parameters: Parameters?

        private enum CodingKeys: String, CodingKey {
            case ok, description, parameters
            case errorCode = "error_code"
        }
    }

    private func call<Result: Decodable, Body: Encodable>(
        _ method: String, body: Body
    ) async throws -> Result {
        // Restrict the token to one URL path component. Never return the URL in an error.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_:-")
        guard !token.isEmpty, token.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
            throw TelegramError.invalidToken
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TelegramError {
            throw error
        } catch {
            // Do not retain arbitrary transport errors or their credential-bearing URLs.
            throw TelegramError.network
        }
        let decoder = JSONDecoder()
        let failure = try? decoder.decode(FailureEnvelope.self, from: data)
        let code = failure?.errorCode
        if response.statusCode == 401 || response.statusCode == 404 || code == 401 || code == 404 {
            throw TelegramError.invalidToken
        }
        if response.statusCode == 429 || code == 429 {
            throw TelegramError.rateLimited(retryAfter: failure?.parameters?.retryAfter)
        }
        guard let failure else { throw TelegramError.malformedResponse }
        guard (200..<300).contains(response.statusCode), failure.ok else {
            throw TelegramError.apiFailure(code: code ?? response.statusCode)
        }
        guard let envelope = try? decoder.decode(Envelope<Result>.self, from: data) else {
            throw TelegramError.malformedResponse
        }
        guard let result = envelope.result else { throw TelegramError.malformedResponse }
        return result
    }
}
