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

public struct AudioRecordingConfiguration: Equatable, Sendable {
    public let microphone: Bool
    public let systemAudio: Bool
    public init(microphone: Bool, systemAudio: Bool) {
        self.microphone = microphone
        self.systemAudio = systemAudio
    }
    public func validate() throws {
        guard microphone || systemAudio else { throw ScreenRecordingFailure.noAudioSources }
    }
}

@MainActor public protocol AudioRecording: AnyObject {
    var onFailure: (@MainActor (ScreenRecordingFailure?) -> Void)? { get set }
    func start(configuration: AudioRecordingConfiguration, destination: URL) async throws -> RecordingMicrophoneOutcome
    func stop() async throws -> URL?
}

@MainActor public protocol AudioRecordingFactory {
    func makeAudioRecorder() -> any AudioRecording
}

/// Held from the synchronous start request through writer finalization, including cancellation.
@MainActor public final class RecordingSessionGate {
    private var owner: UUID?
    public init() {}
    public func acquire() -> UUID? {
        guard owner == nil else { return nil }
        let token = UUID()
        owner = token
        return token
    }
    public func release(_ token: UUID) {
        if owner == token { owner = nil }
    }
}
