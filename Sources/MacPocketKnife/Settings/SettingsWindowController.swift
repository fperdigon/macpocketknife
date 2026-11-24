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

import AppKit
import MacPocketKnifeCore
import SwiftUI

@MainActor
final class SettingsTabSelection: ObservableObject {
    @Published var selectedTab: SettingsView.Tab = .general
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let selection = SettingsTabSelection()

    init(model: SettingsModel, checkForUpdates: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "MacPocketKnife Settings"
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model, checkForUpdates: checkForUpdates, selection: selection))
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func show(tab: SettingsView.Tab? = nil) {
        if let tab { selection.selectedTab = tab }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
