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
    @ObservedObject var thumbnails: RecordingDisplayThumbnails
    let refresh: () -> Void
    let resize: () -> Void
    let start: () -> Void
    let cancel: () -> Void

    private var screenCards: RecordingScreenCards {
        let supportsPicker: Bool
        if #available(macOS 14.0, *) { supportsPicker = true }
        else { supportsPicker = false }
        return RecordingScreenCards(displays: model.connectedRecordingDisplays,
                                    target: model.recordingTargetSelection,
                                    supportsSystemPicker: supportsPicker)
    }

    private var modeSelection: Binding<RecordingScreenMode> {
        Binding(get: { screenCards.mode }, set: { model.recordingTargetSelection = screenCards.target(for: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if screenCards.modes.count > 1 {
                Picker("Screen to record", selection: modeSelection) {
                    ForEach(screenCards.modes, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            previewCards
            previewCaption
            if let name = model.disconnectedRecordingDisplayName {
                Text("\(name) (not connected). The main display is used while the saved display is not connected.")
                    .font(.caption)
            }
            if #unavailable(macOS 14.0), model.recordingTargetSelection == .askEachTime {
                Text("Choosing with the system picker requires macOS 14. The main display is used meanwhile.")
                    .font(.caption)
            }
            Form {
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
        .frame(width: 740)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refresh()
        }
        .onChange(of: model.recordingTargetSelection) { _ in resize() }
        .onChange(of: thumbnails.polling.isDenied) { _ in resize() }
    }

    private var previewCards: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Screens").font(.headline)
                Spacer()
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(screenCards.cards, id: \.display.uuid) { card in
                        if card.isClickable {
                            Button { model.recordingTargetSelection = card.target } label: {
                                displayCard(card)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(card.display.name)
                            .accessibilityValue(card.isSelected ? "Selected" : "Not selected")
                        } else {
                            displayCard(card)
                        }
                    }
                }
                .padding(3)
            }
            .frame(height: 200)
        }
    }

    @ViewBuilder private var previewCaption: some View {
        if screenCards.mode == .systemPicker {
            Text("You will choose the screen or window in the macOS picker after pressing Start.")
                .font(.caption)
        } else if screenCards.mode == .allScreens {
            Text("All-screens mode creates one video per screen.").font(.caption)
        }
        if thumbnails.polling.isDenied {
            VStack(alignment: .leading, spacing: 6) {
                Text("Screen preview unavailable. Allow Screen Recording permission in System Settings. macOS may ask again after an app update.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Allow screen preview") { thumbnails.allowPreview() }
                    .controlSize(.small)
            }
        }
    }

    private func displayCard(_ card: RecordingScreenCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1))
                if let image = thumbnails.images[card.display.uuid] {
                    Image(decorative: image, scale: 2)
                        .resizable().aspectRatio(contentMode: .fit)
                } else if thumbnails.polling.isLoading && !thumbnails.polling.isDenied {
                    ProgressView().controlSize(.small)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "display")
                        Text(thumbnails.polling.isDenied ? "Preview unavailable" : card.display.name)
                            .font(.caption).lineLimit(2)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(width: 200, height: 125)
            .clipped()
            HStack {
                Text(card.display.name).font(.headline).lineLimit(1)
                Spacer(minLength: 2)
                if let badge = card.badge {
                    Text(badge).font(.caption).foregroundStyle(Color.accentColor)
                } else if card.isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                }
            }
            Text("\(card.display.pixelWidth) × \(card.display.pixelHeight)\(card.display.isMain ? " · Main" : "")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(width: 216)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(card.isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                          lineWidth: card.isSelected ? 2 : 1))
        .opacity(card.isDimmed ? 0.55 : 1)
    }
}

@MainActor
final class RecordingOptionsWindowController: NSWindowController, NSWindowDelegate {
    private let model: SettingsModel
    private let thumbnails: RecordingDisplayThumbnails

    init(model: SettingsModel, start: @escaping (ScreenRecordingTarget) -> Void) {
        self.model = model
        thumbnails = RecordingDisplayThumbnails()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 500),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Screen Recording"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowBecameKey(_:)),
                           name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(visibilityChanged(_:)),
                           name: NSWindow.didChangeOcclusionStateNotification, object: window)
        center.addObserver(self, selector: #selector(visibilityChanged(_:)),
                           name: NSApplication.didHideNotification, object: nil)
        center.addObserver(self, selector: #selector(visibilityChanged(_:)),
                           name: NSApplication.didUnhideNotification, object: nil)
        let view = RecordingOptionsWindow(model: model, thumbnails: thumbnails,
                                          refresh: { [weak self] in self?.refresh() },
                                          resize: { [weak self] in self?.resizeToFit() }, start: { [weak self] in
            self?.close()
            start(model.recordingTargetSelection)
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
        synchronizeVisibility()
    }

    private func refresh() {
        guard previewsAreVisible else { return }
        model.connectedRecordingDisplays = RecordingDisplays().connectedDisplays()
        thumbnails.start(displays: model.connectedRecordingDisplays)
        resizeToFit()
    }

    private var previewsAreVisible: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && !NSApp.isHidden
            && window.occlusionState.contains(.visible)
    }

    @objc private func visibilityChanged(_ notification: Notification) {
        synchronizeVisibility()
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        synchronizeVisibility()
        thumbnails.resume()
    }

    private func synchronizeVisibility() {
        if previewsAreVisible {
            if !thumbnails.polling.isActive { refresh() }
        } else {
            thumbnails.stop()
        }
    }

    private func resizeToFit() {
        guard let window, let content = window.contentView else { return }
        window.setContentSize(content.fittingSize)
    }

    override func close() {
        thumbnails.stop()
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        thumbnails.stop()
    }
}
