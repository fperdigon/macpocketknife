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

struct RecordingPermissionStatusTests {
    @Test func presentationForEveryStatus() {
        let cases: [(RecordingPermissionStatus, String, String?)] = [
            (.allowed, "Allowed", nil),
            (.microphoneNotAsked, "Not asked yet", "Allow microphone"),
            (.microphoneDenied, "Denied", "Open Microphone settings"),
            (.screenDenied, "Preview unavailable", "Open Screen Recording settings"),
            (.checking, "Checking…", nil),
            (.unknown, "Not checked yet", nil),
        ]
        for (status, text, button) in cases {
            #expect(status.statusText == text)
            #expect(status.buttonTitle == button)
        }
    }

    @Test func microphoneAuthorizationDecisions() {
        #expect(RecordingMicrophoneAccess.authorized.permissionStatus == .allowed)
        #expect(RecordingMicrophoneAccess.notDetermined.permissionStatus == .microphoneNotAsked)
        #expect(RecordingMicrophoneAccess.denied.permissionStatus == .microphoneDenied)
        #expect(RecordingMicrophoneAccess.restricted.permissionStatus == .microphoneDenied)
        #expect(RecordingMicrophoneAccess.unknown.permissionStatus == .unknown)
    }

    @Test func previewEvidenceSurvivesTicksAndResetsWithSession() {
        var polling = RecordingPreviewPolling()
        #expect(polling.permissionStatus == .unknown)
        polling.start(displayIDs: ["a", "b"])
        #expect(polling.permissionStatus == .unknown)
        #expect(polling.begin("a") == true)
        #expect(polling.permissionStatus == .checking)
        polling.complete("a", succeeded: true)
        #expect(polling.permissionStatus == .allowed)
        #expect(polling.begin("a") == true)
        #expect(polling.permissionStatus == .allowed)
        polling.complete("a", succeeded: true)
        #expect(polling.begin("b") == true)
        polling.complete("b", succeeded: false)
        #expect(polling.permissionStatus == .screenDenied)
        polling.resume()
        #expect(polling.permissionStatus == .unknown)
        polling.start(displayIDs: ["a"])
        #expect(polling.permissionStatus == .unknown)
        #expect(polling.begin("a") == true)
        polling.complete("a", succeeded: false)
        #expect(polling.permissionStatus == .screenDenied)
        polling.resume()
        #expect(polling.permissionStatus == .unknown)
        #expect(polling.begin("a") == true)
        #expect(polling.permissionStatus == .checking)
        polling.complete("a", succeeded: true)
        #expect(polling.permissionStatus == .allowed)
        polling.stop()
        #expect(polling.permissionStatus == .unknown)
    }
}
