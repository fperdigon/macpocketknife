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

/// Presentation policy shared by the recording window and Settings.
public enum RecordingPermissionStatus: Equatable, Sendable {
    case allowed, microphoneNotAsked, microphoneDenied, screenDenied, checking, unknown

    public var statusText: String {
        switch self {
        case .allowed: return "Allowed"
        case .microphoneNotAsked: return "Not asked yet"
        case .microphoneDenied: return "Denied"
        case .screenDenied: return "Preview unavailable"
        case .checking: return "Checking…"
        case .unknown: return "Not checked yet"
        }
    }

    public var buttonTitle: String? {
        switch self {
        case .microphoneNotAsked: return "Allow microphone"
        case .microphoneDenied: return "Open Microphone settings"
        case .screenDenied: return "Open Screen Recording settings"
        case .allowed, .checking, .unknown: return nil
        }
    }
}
