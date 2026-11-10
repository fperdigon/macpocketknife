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

/// AppKit presentation only; comparisons, installation, and scheduling live in Core.
@MainActor
final class UpdateController: NSObject {
    private let preferences: () -> UpdatePreferences
    private let skipVersion: (String) -> Void
    private let beforeQuit: () -> Void
    private let checker: any UpdateChecking
    private let downloader: any UpdateDownloading
    private let installer: UpdateInstaller
    private let defaults: UserDefaults
    private let policy: UpdateCheckPolicy
    private var busy = false
    private var progressWindow: NSWindow?
    private var progressLabel: NSTextField?

    init(preferences: @escaping () -> UpdatePreferences, skipVersion: @escaping (String) -> Void,
         beforeQuit: @escaping () -> Void, checker: any UpdateChecking = UpdateChecker(),
         downloader: any UpdateDownloading = UpdateDownloader(), installer: UpdateInstaller = UpdateInstaller(),
         defaults: UserDefaults = .standard, policy: UpdateCheckPolicy = UpdateCheckPolicy()) {
        self.preferences = preferences
        self.skipVersion = skipVersion
        self.beforeQuit = beforeQuit
        self.checker = checker
        self.downloader = downloader
        self.installer = installer
        self.defaults = defaults
        self.policy = policy
    }

    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(checkNow), keyEquivalent: "")
        item.target = self
        return item
    }

    func checkInBackgroundIfDue() {
        Task { await run(userInitiated: false) }
    }

    @objc func checkNow() {
        Task { await run(userInitiated: true) }
    }

    private func run(userInitiated: Bool) async {
        guard !busy else { return }
        let prefs = preferences()
        let lastAttempt = defaults.object(forKey: "lastUpdateCheck") as? Date
        guard userInitiated || policy.isDue(preferences: prefs, lastAttempt: lastAttempt) else { return }
        busy = true
        defer { busy = false }
        // Record attempts, including failures, so rate limits do not cause repeated launch requests.
        defaults.set(policy.now, forKey: "lastUpdateCheck")
        let build = BuildInfo.current
        do {
            switch try await checker.check(channel: prefs.channel, build: build) {
            case .upToDate(let current):
                if userInitiated { Self.alert("You're up to date", "MacPocketKnife \(current) is current on the selected channel.") }
            case .available(let update):
                guard policy.shouldOffer(tag: update.release.tag, preferences: prefs, userInitiated: userInitiated) else { return }
                await offer(update)
            }
        } catch {
            if userInitiated { Self.alert("Could not check for updates", "The update check failed. Try again later.\n" + safeMessage(error)) }
        }
    }

    private func offer(_ update: AvailableUpdate) async {
        let alert = NSAlert()
        alert.messageText = "Update available"
        alert.informativeText = "\(update.label) is available on the \(update.channel.displayName.lowercased()) channel.\n\n"
            + update.release.notesExcerpt() + "\n\nInstallation quits the app and reopens it. Your keep-awake state will be restored."
        alert.addButton(withTitle: "Install and relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip this version")
        switch alert.runModal() {
        case .alertFirstButtonReturn: await install(update)
        case .alertThirdButtonReturn: skipVersion(update.release.tag)
        default: break
        }
    }

    private func install(_ update: AvailableUpdate) async {
        showProgress("Downloading…")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cam-update-" + UUID().uuidString)
        defer {
            progressWindow?.orderOut(nil)
            progressWindow = nil
            progressLabel = nil
            try? FileManager.default.removeItem(at: work)
        }
        do {
            let dmg = try await downloader.download(update.asset, to: work) { [weak self] fraction in
                Task { @MainActor in self?.progressLabel?.stringValue = "Downloading… \(Int(min(1, max(0, fraction)) * 100))%" }
            }
            progressLabel?.stringValue = "Verifying and installing…"
            let app = Bundle.main.bundleURL
            let installer = installer
            try await Task.detached(priority: .userInitiated) {
                try installer.install(dmg: dmg, expectedDigest: update.asset.digest, over: app, work: work)
            }.value
            let helper = UpdateInstaller.relaunchProcess(appURL: app)
            beforeQuit()
            try helper.run()
            // Schedule before terminate(), which may enter a nested modal loop.
            // beforeQuit has already flushed the state needed by the replacement.
            let fallback = Timer(timeInterval: 5, repeats: false) { _ in exit(0) }
            RunLoop.main.add(fallback, forMode: .common)
            NSApp.terminate(nil)
        } catch {
            Self.alert("Update failed", safeMessage(error))
        }
    }

    private func safeMessage(_ error: any Error) -> String {
        if let error = error as? UpdateChecker.CheckError { return error.localizedDescription }
        if let error = error as? UpdateInstallError { return error.localizedDescription }
        return "The update could not be completed. Check your connection and the app folder's permissions, then try again."
    }

    private func showProgress(_ text: String) {
        let label = NSTextField(labelWithString: text)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.startAnimation(nil)
        let stack = NSStackView(views: [spinner, label])
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Updating MacPocketKnife"
        window.contentView = stack
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        progressWindow = window
        progressLabel = label
    }

    private static func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
