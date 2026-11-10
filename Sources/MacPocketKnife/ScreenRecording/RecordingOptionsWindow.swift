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
import MacPocketKnifeCore
@preconcurrency import SwiftUI

@MainActor
struct RecordingOptionsWindow: View {
    @ObservedObject var model: SettingsModel
    let start: () -> Void
    let cancel: () -> Void

    private var options: RecordingOptions {
        let supportsPreview: Bool
        if #available(macOS 14.0, *) { supportsPreview = true }
        else { supportsPreview = false }
        return RecordingOptions(displays: model.connectedRecordingDisplays,
                                target: model.settings.screenRecordingTarget,
                                supportsPreview: supportsPreview,
                                savedDisplayName: model.settings.screenRecordingDisplayName)
    }

    var body: some View {
        VStack(spacing: 16) {
            Form {
                Picker("Screen to record", selection: $model.recordingTargetSelection) {
                    ForEach(options.choices, id: \.target) { choice in
                        Text(choice.title).tag(choice.target).disabled(!choice.isEnabled)
                    }
                }
                Text("All-screens mode creates one video per screen.")
                    .font(.caption)
                if model.disconnectedRecordingDisplayName != nil {
                    Text("The main display is used while the saved display is not connected.")
                        .font(.caption)
                }
                Toggle("Include microphone", isOn: $model.settings.screenRecordingIncludesMicrophone)
                Text("Microphone capture requires macOS 15 or later.").font(.caption)
                Toggle("Show cursor", isOn: $model.settings.screenRecordingShowsCursor)
                Picker("Frame rate", selection: $model.settings.screenRecordingFrameRate) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Start recording", action: start).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 340)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            model.connectedRecordingDisplays = RecordingDisplays().connectedDisplays()
        }
    }
}

@MainActor
final class RecordingOptionsWindowController: NSWindowController {
    private let model: SettingsModel

    init(model: SettingsModel, start: @escaping (ScreenRecordingTarget) -> Void) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 340),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Screen Recording"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let view = RecordingOptionsWindow(model: model, start: { [weak self] in
            self?.close()
            start(model.recordingTargetSelection)
        }, cancel: { [weak self] in self?.close() })
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        model.connectedRecordingDisplays = RecordingDisplays().connectedDisplays()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
