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

import MacPocketKnifeCore
import Testing

struct PrivacyPaneTests {
    @Test func screenRecordingSettingsURL() {
        #expect(PrivacyPane.screenRecording.settingsURLString ==
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    @Test func microphoneSettingsURL() {
        #expect(PrivacyPane.microphone.settingsURLString ==
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    @Test func speechRecognitionSettingsURL() {
        #expect(PrivacyPane.speechRecognition.settingsURLString ==
                "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
    }

}
