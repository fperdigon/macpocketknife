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

/// Microphone authorization policy without a dependency on AVFoundation.
public enum RecordingMicrophoneAccess: Equatable, Sendable {
    case notDetermined, restricted, denied, authorized, unknown

    /// Values correspond to AVAuthorizationStatus.rawValue.
    public init(authorizationStatusRawValue: Int) {
        switch authorizationStatusRawValue {
        case 0: self = .notDetermined
        case 1: self = .restricted
        case 2: self = .denied
        case 3: self = .authorized
        default: self = .unknown
        }
    }

    public var showsSettingsLink: Bool {
        switch self {
        case .denied, .restricted: return true
        case .notDetermined, .authorized, .unknown: return false
        }
    }

    public static let settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
}
