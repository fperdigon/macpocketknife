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

/// Privacy settings destinations shared by recording and dictation shortcuts.
public enum PrivacyPane: Equatable, Sendable {
    case screenRecording, microphone, speechRecognition

    public var settingsURLString: String {
        switch self {
        case .screenRecording:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .microphone:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .speechRecognition:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        }
    }
}

extension ScreenRecordingFailure {
    /// The settings pane that can resolve a permission failure, if applicable.
    public var privacyPane: PrivacyPane? {
        switch self {
        case .permissionDenied: return .screenRecording
        case .microphoneDenied: return .microphone
        case .lowDiskSpace, .noDisplay, .captureFailed, .writingFailed, .folderUnavailable:
            return nil
        }
    }
}
