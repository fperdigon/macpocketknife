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
@preconcurrency import SwiftUI
import MacPocketKnifeCore

@MainActor
private struct AudioRecordingOptionsWindow: View {
    @ObservedObject var model: SettingsModel
    let screenPermissionDenied: Bool
    let resize: () -> Void
    let start: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                Toggle("Microphone", isOn: $model.settings.audioRecordingMicrophone)
                Toggle("System audio", isOn: $model.settings.audioRecordingSystemAudio)
            }
            if #unavailable(macOS 15.0) {
                Text("Microphone capture is unavailable on macOS 13/14. Enable System audio to record.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.settings.audioRecordingMicrophone && !model.settings.audioRecordingSystemAudio {
                Text("Enable at least one audio source.").font(.caption)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Permissions").font(.headline)
                Text("ScreenCaptureKit needs Screen Recording permission. macOS checks access when you start; no screen images are saved.")
                    .font(.caption).foregroundStyle(.secondary)
                if screenPermissionDenied, let title = RecordingPermissionStatus.screenDenied.buttonTitle {
                    Button(title) {
                        if let url = URL(string: PrivacyPane.screenRecording.settingsURLString) { NSWorkspace.shared.open(url) }
                    }
                    .controlSize(.small)
                }
                RecordingMicrophoneAccessNotice(accessChanged: resize)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Start recording", action: start).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: model.settings.audioRecordingMicrophone) { _ in resize() }
        .onChange(of: model.settings.audioRecordingSystemAudio) { _ in resize() }
    }
}

@MainActor
final class AudioRecordingOptionsWindowController: NSWindowController {
    init(model: SettingsModel, screenPermissionDenied: Bool, start: @escaping () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Audio Recording"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let view = AudioRecordingOptionsWindow(model: model, screenPermissionDenied: screenPermissionDenied,
            resize: { [weak self] in self?.resizeToFit() }, start: { [weak self] in
                self?.close()
                start()
            }, cancel: { [weak self] in self?.close() })
        window.contentViewController = NSHostingController(rootView: view)
        resizeToFit()
        window.center()
    }
    required init?(coder: NSCoder) { nil }
    func show() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    private func resizeToFit() {
        guard let window, let content = window.contentView else { return }
        window.setContentSize(content.fittingSize)
    }
}
