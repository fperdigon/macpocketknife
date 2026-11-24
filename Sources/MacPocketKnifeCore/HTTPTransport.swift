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

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public static let defaultRequestTimeout: TimeInterval = 10

    private let session: URLSession
    private let requestTimeout: TimeInterval

    /// Dedicated, cache-free session so one slow endpoint cannot hold a request for 60 s.
    public static func makeSession(requestTimeout: TimeInterval = defaultRequestTimeout) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 2
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    public init(
        session: URLSession? = nil, requestTimeout: TimeInterval = URLSessionTransport.defaultRequestTimeout
    ) {
        self.requestTimeout = requestTimeout
        self.session = session ?? Self.makeSession(requestTimeout: requestTimeout)
    }

    func timed(_ request: URLRequest) -> URLRequest {
        var copy = request
        copy.timeoutInterval = requestTimeout
        return copy
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: timed(request))
            guard let response = response as? HTTPURLResponse else {
                throw TelegramError.malformedResponse
            }
            return (data, response)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TelegramError {
            throw error
        } catch {
            // Underlying errors can contain the credential-bearing request URL.
            throw TelegramError.network
        }
    }
}
