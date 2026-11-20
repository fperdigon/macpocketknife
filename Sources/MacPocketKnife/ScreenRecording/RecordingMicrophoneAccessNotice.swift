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

@preconcurrency import AppKit
@preconcurrency import AVFoundation
import MacPocketKnifeCore
@preconcurrency import SwiftUI

@MainActor
struct RecordingMicrophoneAccessNotice: View {
    var showsCaption = true
    var accessChanged: () -> Void = {}
    @State private var access = RecordingMicrophoneAccessNotice.currentAccess()

    var body: some View {
        HStack {
            if showsCaption {
                Text("Microphone")
            }
            if access.permissionStatus == .allowed {
                Label("Allowed", systemImage: "checkmark")
                    .foregroundStyle(.secondary)
            } else {
                Text(access.permissionStatus.statusText)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let title = access.permissionStatus.buttonTitle {
                Button(title) {
                    if access == .notDetermined { requestAccess() }
                    else { openSettings() }
                }
                .controlSize(.small)
            }
        }
        .onAppear(perform: refreshAccess)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAccess()
        }
        // Hosting controllers retain their views when a window is closed and reopened.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshAccess()
        }
        .onChange(of: access) { _ in
            // Let SwiftUI update the content before the options window measures it.
            Task { @MainActor in
                await Task.yield()
                accessChanged()
            }
        }
    }

    private func requestAccess() {
        Task { @MainActor in
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refreshAccess()
        }
    }

    private static func currentAccess() -> RecordingMicrophoneAccess {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return RecordingMicrophoneAccess(authorizationStatusRawValue: status.rawValue)
    }

    private func refreshAccess() {
        access = Self.currentAccess()
    }

    private func openSettings() {
        guard let url = URL(string: PrivacyPane.microphone.settingsURLString) else { return }
        NSWorkspace.shared.open(url)
    }
}
