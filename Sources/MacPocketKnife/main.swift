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
import Combine
import MacPocketKnifeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let controller = CaffeinateController.makeKeepAwake()
    private let unlockController = CaffeinateController.makeKeepUnlocked()
    private let localNotifier = LocalNotifier()
    private let settings = SettingsModel(
        store: UserDefaultsSettingsStore(defaults: .standard), secrets: KeychainSecretStore()
    )
    private lazy var updates = UpdateController(
        preferences: { [unowned self] in
            UpdatePreferences(channel: settings.settings.updateChannel,
                              automatically: settings.settings.checkForUpdatesAutomatically,
                              skippedVersion: settings.settings.skippedVersion)
        },
        skipVersion: { [unowned self] in settings.settings.skippedVersion = $0 },
        beforeQuit: { [unowned self] in
            // The controller saves every state change. Re-save the current deadline and flush
            // before quitting so the replacement restores precisely the same assertion state.
            let defaults = UserDefaults.standard
            let store = UserDefaultsKeepAwakeStateStore(defaults: defaults)
            store.save(controller.isActive ? KeepAwakeState(isActive: true, expiryDate: controller.expiryDate) : nil)
            let unlockStore = UserDefaultsKeepAwakeStateStore(
                defaults: defaults, key: CaffeinateController.keepUnlockedStateKey
            )
            let unlockState = KeepAwakeState(isActive: true, expiryDate: unlockController.expiryDate)
            unlockStore.save(unlockController.isActive ? unlockState : nil)
            defaults.synchronize()
        }
    )
    private lazy var dictation = DictationController.make(
        speech: AppleSpeechTranscriber(), pasteboard: SystemPasteboard(), notices: localNotifier
    )
    private lazy var screenRecording = ScreenRecordingController.make(
        factory: RecordingFactory(), displays: RecordingDisplays(), picker: RecordingPicker(), permission: ScreenRecordingPermission(),
        disk: RecordingDiskSpace(), files: RecordingFiles(), notices: localNotifier
    )
    private var isTerminating = false
    private lazy var hotkey = GlobalHotkey()
    private var settingsSubscription: AnyCancellable?
    private var hotkeyPreferences: String?
    private var engine: AssistantEngine?
    private var settingsWindow: SettingsWindowController?
    private let statusLine = NSMenuItem(title: "Reading power state…", action: nil, keyEquivalent: "")
    private let blockersLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let keepAwake = NSMenuItem(title: "Keep awake", action: nil, keyEquivalent: "")
    private let keepUnlocked = NSMenuItem(title: "Keep unlocked", action: nil, keyEquivalent: "")
    private let dictate = NSMenuItem(title: "Dictate", action: nil, keyEquivalent: "")
    private let recordScreen = NSMenuItem(title: "Record screen", action: nil, keyEquivalent: "")
    private let recordWithMicrophone = NSMenuItem(title: "Record with microphone", action: nil, keyEquivalent: "")
    private let screenRecordingStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let dictationStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let authorization = NSMenuItem(title: "Notifications: checking…", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let engine = AssistantEngine(
            powerMonitor: IOKitPowerMonitor(), assertionProvider: IOKitAssertionProvider(),
            classifier: ProcessClassifier(processTable: SysctlProcessTable()),
            caffeinateController: controller, keepUnlockedController: unlockController,
            channels: [localNotifier, TelegramNotifier(settings: settings, secrets: KeychainSecretStore())],
            terminator: SignalProcessTerminator(), settings: settings
        )
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(named: "MenuBarIcon") {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            item.button?.image = image
        } else {
            let image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: AppInfo.name)
            image?.isTemplate = true
            item.button?.image = image
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        blockersLine.isEnabled = false
        blockersLine.isHidden = true
        menu.addItem(blockersLine)
        keepAwake.target = self
        keepAwake.action = #selector(toggleKeepAwake)
        menu.addItem(keepAwake)
        keepUnlocked.target = self
        keepUnlocked.action = #selector(toggleKeepUnlocked)
        keepUnlocked.toolTip = "Keeps the display awake so the Mac does not lock from inactivity. Manual lock (Ctrl-Cmd-Q), closing the lid and password policies still apply."
        menu.addItem(keepUnlocked)
        dictate.target = self
        dictate.action = #selector(toggleDictation)
        menu.addItem(dictate)
        recordScreen.target = self
        recordScreen.action = #selector(toggleScreenRecording)
        menu.addItem(recordScreen)
        if #available(macOS 15.0, *) {
            recordWithMicrophone.target = self
            recordWithMicrophone.action = #selector(toggleRecordingMicrophone)
            menu.addItem(recordWithMicrophone)
        }
        let recordings = NSMenuItem(title: "Show recordings in Finder", action: #selector(showRecordings), keyEquivalent: "")
        recordings.target = self
        menu.addItem(recordings)
        screenRecordingStatus.target = self
        screenRecordingStatus.action = #selector(openScreenRecordingPrivacy)
        screenRecordingStatus.isHidden = true
        menu.addItem(screenRecordingStatus)
        dictationStatus.target = self
        dictationStatus.action = #selector(openDictationPrivacy)
        dictationStatus.isHidden = true
        menu.addItem(dictationStatus)
        authorization.isEnabled = false
        menu.addItem(authorization)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let aboutItem = NSMenuItem(title: "About MacPocketKnife", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(updates.menuItem())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
        statusItem = item

        dictation.onChange = { [weak self] in self?.refreshStatus() }
        screenRecording.onChange = { [weak self] in self?.refreshStatus() }
        hotkey.actions[1] = { [weak self] in self?.toggleDictation() }
        hotkey.actions[2] = { [weak self] in self?.toggleScreenRecording() }
        settingsSubscription = settings.$settings.sink { [weak self] value in
            self?.configureHotkey(value)
        }
        self.engine = engine
        engine.onChange = { [weak self] in self?.refreshStatus() }
        controller.restoreIfNeeded()
        unlockController.restoreIfNeeded()
        updates.checkInBackgroundIfDue()
        if CommandLine.arguments.contains("--show-settings") { showSettings() }
        if let argumentIndex = CommandLine.arguments.firstIndex(of: "--snapshot-settings"),
           CommandLine.arguments.indices.contains(argumentIndex + 1) {
            let directory = URL(fileURLWithPath: CommandLine.arguments[argumentIndex + 1], isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            showSettings()
            settingsWindow?.captureSnapshots(in: directory) { NSApp.terminate(nil) }
        }
        for controller in [controller, unlockController] {
            controller.onChange = { [weak self] _ in
                self?.refreshStatus()
                Task { @MainActor [weak self] in await self?.engine?.evaluate() }
            }
        }
        Task { @MainActor in
            await engine.start()
            // The system authorization state persists across launches.
            updateAuthorization(await localNotifier.requestAuthorizationIfNeeded())
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateLater }
        isTerminating = true
        Task { @MainActor in
            await screenRecording.stopAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictation.discard()
        hotkey.shutdown()
        engine?.stop()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshStatus()
        Task { @MainActor in updateAuthorization(await localNotifier.authorizationState()) }
    }

    private func refreshStatus() {
        statusLine.title = engine?.statusText ?? "Reading power state…"
        let blockers = engine?.blockersText
        blockersLine.title = blockers ?? ""
        blockersLine.isHidden = blockers == nil
        keepAwake.state = controller.isActive ? .on : .off
        keepUnlocked.state = unlockController.isActive ? .on : .off
        let recording = dictation.state == .recording
        let active = recording || dictation.state == .starting
        let label = active ? "Stop dictation" : "Dictate"
        let shortcut = settings.settings.dictationHotkeyEnabled ? " (⌃⌥⌘\(settings.settings.dictationHotkeyKey))" : ""
        dictate.title = label + shortcut
        dictate.state = active ? .on : .off
        dictate.toolTip = recording ? "\(dictation.wordCount) words transcribed" : "Transcribe speech on this Mac and copy it to the clipboard."
        let screenActive = screenRecording.state == .recording
        let screenBusy = screenActive || screenRecording.state == .starting || screenRecording.state == .stopping
        recordWithMicrophone.state = settings.settings.screenRecordingIncludesMicrophone ? .on : .off
        recordWithMicrophone.isEnabled = !screenBusy
        let screenLabel = screenBusy ? "Stop recording" : "Record screen"
        let screenKey = settings.settings.screenRecordingHotkeyKey
        let screenShortcut = settings.settings.screenRecordingHotkeyEnabled ? " (⌃⌥⌘\(screenKey))" : ""
        recordScreen.title = screenLabel + screenShortcut
        recordScreen.state = screenBusy ? .on : .off
        recordScreen.isEnabled = screenRecording.state != .stopping
        rebuildRecordingMenu(busy: screenBusy)
        let screenError = screenRecording.lastError ?? settings.screenRecordingHotkeyError ?? screenRecording.lastNotice
        screenRecordingStatus.title = screenError ?? ""
        screenRecordingStatus.isHidden = screenError == nil
        var indicators = recording ? " ●" : ""
        if screenActive { indicators += " ⏺ " + screenRecording.elapsedTitle }
        statusItem?.length = (recording || screenActive) ? NSStatusItem.variableLength : NSStatusItem.squareLength
        statusItem?.button?.attributedTitle = NSAttributedString(
            string: indicators, attributes: [.foregroundColor: NSColor.systemRed]
        )
        statusItem?.button?.imagePosition = .imageLeading
        let error = dictation.lastError ?? settings.dictationHotkeyError
        dictationStatus.title = error ?? ""
        dictationStatus.isHidden = error == nil
    }

    private func rebuildRecordingMenu(busy: Bool) {
        recordScreen.submenu = nil
        recordScreen.action = #selector(toggleScreenRecording)
        guard !busy else { return }
        let displays = RecordingDisplays().connectedDisplays()
        settings.connectedRecordingDisplays = displays
        guard displays.count >= 2 else { return }
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let defaultTarget = settings.settings.screenRecordingTarget
        for display in displays {
            let mainLabel = display.isMain ? " (Main)" : ""
            let title = "\(display.name) — \(display.pixelWidth) × \(display.pixelHeight)\(mainLabel)"
            let item = NSMenuItem(title: title, action: #selector(recordSelectedScreen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = display.uuid
            let selected = defaultTarget == .display(uuid: display.uuid) || (defaultTarget == .mainDisplay && display.isMain)
            item.state = selected ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let all = NSMenuItem(title: "All screens (separate videos)", action: #selector(recordAllScreens), keyEquivalent: "")
        all.target = self
        all.state = defaultTarget == .allDisplays ? .on : .off
        submenu.addItem(all)
        if #available(macOS 14.0, *) {
            let preview = NSMenuItem(title: "Choose with preview…", action: #selector(recordWithPreview), keyEquivalent: "")
            preview.target = self
            preview.state = defaultTarget == .askEachTime ? .on : .off
            submenu.addItem(preview)
        }
        recordScreen.action = nil
        recordScreen.submenu = submenu
    }

    @objc private func recordSelectedScreen(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        screenRecording.toggle(settings: settings.settings, target: .display(uuid: uuid))
    }
    @objc private func recordAllScreens() {
        screenRecording.toggle(settings: settings.settings, target: .allDisplays)
    }
    @objc private func recordWithPreview() {
        screenRecording.toggle(settings: settings.settings, target: .askEachTime)
    }

    private func updateAuthorization(_ state: AuthorizationState) {
        authorization.target = self
        authorization.action = nil
        authorization.isEnabled = false
        switch state {
        case .authorized: authorization.title = "Notifications: authorized"
        case .notDetermined: authorization.title = "Notifications: not requested"
        case .unavailable: authorization.title = "Notifications: unavailable"
        case .denied:
            authorization.title = "Notifications denied — Open System Settings…"
            authorization.action = #selector(openNotificationSettings)
            authorization.isEnabled = true
        }
    }

    @objc private func toggleKeepAwake() {
        if controller.isActive {
            controller.deactivate()
        } else {
            controller.activate(duration: settings.settings.keepAwakeDefaultDuration)
        }
    }

    @objc private func toggleKeepUnlocked() {
        if unlockController.isActive {
            unlockController.deactivate()
        } else {
            unlockController.activate(duration: settings.settings.keepAwakeDefaultDuration)
        }
    }

    private func configureHotkey(_ value: AppSettings) {
        let dictationSignature = "\(value.dictationHotkeyEnabled)-\(value.dictationHotkeyKey)"
        let screenSignature = "\(value.screenRecordingHotkeyEnabled)-\(value.screenRecordingHotkeyKey)"
        let signature = dictationSignature + screenSignature
        guard signature != hotkeyPreferences else { return }
        hotkeyPreferences = signature
        hotkey.unregister()
        let registered = hotkey.register(id: 1, enabled: value.dictationHotkeyEnabled, key: value.dictationHotkeyKey)
        settings.dictationHotkeyError = registered ? nil : "Dictation shortcut is unavailable. Choose another key in Settings > Tools > Dictation."
        if let message = settings.dictationHotkeyError {
            Task { await localNotifier.deliver(Notice(kind: .info, title: "Dictation shortcut unavailable", body: message)) }
        }
        let screenRegistered: Bool
        if value.screenRecordingHotkeyConflicts {
            screenRegistered = false
            settings.screenRecordingHotkeyError = "Choose a screen recording key different from the Dictation key."
        } else {
            screenRegistered = hotkey.register(id: 2, enabled: value.screenRecordingHotkeyEnabled, key: value.screenRecordingHotkeyKey)
            settings.screenRecordingHotkeyError = screenRegistered ? nil : "Screen recording shortcut is unavailable. Choose another key in Settings > Tools."
        }
        if !screenRegistered, let message = settings.screenRecordingHotkeyError {
            Task { await localNotifier.deliver(Notice(kind: .info, title: "Screen recording shortcut unavailable", body: message)) }
        }
        // Published settings arrive before the stored value changes.
        Task { @MainActor [weak self] in self?.refreshStatus() }
    }

    @objc private func toggleDictation() {
        let locale: Locale
        if let identifier = settings.settings.dictationLanguage {
            locale = Locale(identifier: identifier)
        } else {
            locale = Locale.current
        }
        dictation.toggle(locale: locale)
    }

    @objc private func toggleRecordingMicrophone() {
        settings.settings.screenRecordingIncludesMicrophone.toggle()
        refreshStatus()
    }

    @objc private func toggleScreenRecording() {
        screenRecording.toggle(settings: settings.settings)
    }

    @objc private func showRecordings() {
        screenRecording.showRecordings(folderPath: settings.settings.screenRecordingFolder)
    }

    @objc private func openScreenRecordingPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openDictationPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showSettings() {
        openSettings(tab: nil)
    }

    @objc private func showAbout() {
        openSettings(tab: .about)
    }

    private func openSettings(tab: SettingsView.Tab?) {
        settings.connectedRecordingDisplays = RecordingDisplays().connectedDisplays()
        if settingsWindow == nil { settingsWindow = SettingsWindowController(model: settings, checkForUpdates: { [weak self] in self?.updates.checkNow() }) }
        settingsWindow?.show(tab: tab)
    }

    @objc private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

RecordingSelfTest.runIfRequested()

// Read-only CLI output must not depend on the AppKit launch event loop.
if CommandLine.arguments.contains("--print-status") {
    let power = IOKitPowerMonitor().current
    let estimate = IOKitBatteryEstimator().currentEstimate()
    let assertions = IOKitAssertionProvider().currentAssertions()
    let blockers = SleepBlockerSummary.names(assertions: assertions, ownPID: getpid())
    print(StatusLineFormatter.format(power: power, estimate: estimate))
    if let line = StatusLineFormatter.blockersLine(blockers: blockers) { print(line) }
    exit(0)
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
NSApp.setActivationPolicy(.accessory)
application.run()
