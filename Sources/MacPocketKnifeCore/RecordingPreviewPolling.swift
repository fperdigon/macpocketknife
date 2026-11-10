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

/// Scheduling policy shared by all display previews. A failure pauses the entire
/// session until an explicit retry or window activation, avoiding permission spam.
public struct RecordingPreviewPolling: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle, loading, loaded, denied
    }

    public private(set) var states: [String: State] = [:]
    public private(set) var isActive = false

    public init() {}

    public var isDenied: Bool { states.values.contains(.denied) }
    public var isLoading: Bool { states.values.contains(.loading) }
    public var shouldPoll: Bool { isActive && !states.isEmpty && !isDenied }

    public mutating func start(displayIDs: [String]) {
        states = Dictionary(uniqueKeysWithValues: Set(displayIDs).map { ($0, State.idle) })
        isActive = true
    }

    /// Returns false for a tick while this display is already capturing.
    public mutating func begin(_ displayID: String) -> Bool {
        guard shouldPoll, let state = states[displayID], state != .loading else { return false }
        states[displayID] = .loading
        return true
    }

    public mutating func complete(_ displayID: String, succeeded: Bool) {
        guard isActive, states[displayID] == .loading else { return }
        states[displayID] = succeeded ? .loaded : .denied
    }

    public mutating func resume() {
        guard isActive else { return }
        for (id, state) in states where state == .denied {
            states[id] = .idle
        }
    }

    public mutating func stop() {
        isActive = false
        states = [:]
    }
}
