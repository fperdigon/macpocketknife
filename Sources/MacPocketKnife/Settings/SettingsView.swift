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
import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let checkForUpdates: () -> Void
    // The hosting controller retains this view for the lifetime of the session.
    @ObservedObject var selection: SettingsTabSelection
    @State private var token = ""
    @State private var createBot = false
    @State private var isBusy = false
    @State private var status: String?
    @State private var operation: Task<Void, Never>?

    enum Tab: String, CaseIterable, Identifiable {
        case general, tools, protection, telegram, updates, about

        var id: String { rawValue }

        var label: String {
            switch self {
            case .general: return "General"
            case .tools: return "Tools"
            case .protection: return "Protection"
            case .telegram: return "Telegram"
            case .updates: return "Updates"
            case .about: return "About"
            }
        }

        var systemImage: String {
            switch self {
            case .general: return "gearshape"
            case .tools: return "wrench.and.screwdriver"
            case .protection: return "battery.50"
            case .telegram: return "paperplane"
            case .updates: return "arrow.down.circle"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 560, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear {
            operation?.cancel()
            token = ""
        }
        .onReceive(model.$settings) { settings in
            if !settings.telegram.isEnabled { operation?.cancel() }
        }
        .onReceive(model.$launchAtLoginStatus) { message in
            if let message { status = message }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            ForEach(Tab.allCases) { tab in
                TabButton(tab: tab, selected: selection.selectedTab == tab) { selection.selectedTab = tab }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selection.selectedTab {
        case .general: GeneralPane(model: model, status: status)
        case .tools: ToolsPane(model: model)
        case .protection: ProtectionPane(model: model)
        case .telegram:
            TelegramPane(
                model: model, token: $token, createBot: $createBot, isBusy: isBusy,
                status: status, run: run, cancel: { operation?.cancel() }
            )
        case .updates: UpdatesPane(model: model, checkForUpdates: checkForUpdates)
        case .about: AboutPane()
        }
    }

    private func run(_ success: String, action: @escaping @MainActor () async throws -> Void) {
        isBusy = true
        status = nil
        operation = Task { @MainActor in
            defer { isBusy = false }
            do {
                try await action()
                try Task.checkCancellation()
                status = success
            } catch is CancellationError {
                status = "Telegram setup cancelled."
            } catch {
                // Avoid displaying transport or credential-bearing error descriptions.
                status = "Telegram setup failed. Check the bot token, chat ID, and connection, then try again."
            }
        }
    }
}

@MainActor
private struct TabButton: View {
    let tab: SettingsView.Tab
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 18))
                Text(tab.label)
                    .font(.system(size: 11))
            }
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .frame(width: 78, height: 50)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor
private struct GeneralPane: View {
    @ObservedObject var model: SettingsModel
    let status: String?

    var body: some View {
        Form {
            generalSection
            if let status { Text(status).font(.callout).accessibilityLabel(status) }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var generalSection: some View {
        Section("General") {
            Toggle("Keep awake indefinitely by default", isOn: $model.keepAwakeIndefinitely)
            if model.settings.keepAwakeDefaultDuration != nil {
                TextField("Default keep-awake duration (seconds)", value: Binding(
                    get: { model.settings.keepAwakeDefaultDuration ?? 3600 },
                    set: { model.settings.keepAwakeDefaultDuration = $0 }
                ), format: .number)
            }
            Toggle("Launch at login", isOn: $model.launchAtLogin)
            Text("Local notifications are always enabled.")
                .font(.caption)
        }
    }
}

@MainActor
private struct ToolsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            dictationSection
            screenRecordingSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            model.connectedRecordingDisplays = RecordingDisplays().connectedDisplays()
        }
    }

    private var dictationSection: some View {
        Section("Dictation") {
            Toggle("Enable global shortcut (Control-Option-Command)", isOn: $model.settings.dictationHotkeyEnabled)
            Picker("Shortcut key", selection: $model.settings.dictationHotkeyKey) {
                ForEach(AppSettings.dictationKeys, id: \.self) { key in Text(key).tag(key) }
            }
            .disabled(!model.settings.dictationHotkeyEnabled)
            Picker("Dictation language", selection: $model.dictationLanguageSelection) {
                Text("System default").tag("")
                ForEach(AppleSpeechTranscriber.offlineLocales, id: \.self) { identifier in
                    Text(Locale(identifier: "en").localizedString(forIdentifier: identifier) ?? identifier).tag(identifier)
                }
            }
            if let error = model.dictationHotkeyError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Text("Speech is processed on device. Microphone and speech recognition access are requested on first use. Text is copied to the clipboard.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var screenRecordingSection: some View {
        Section("Screen recording") {
            Picker("Screen to record", selection: $model.recordingTargetSelection) {
                Text("Main display").tag(ScreenRecordingTarget.mainDisplay)
                ForEach(model.connectedRecordingDisplays, id: \.uuid) { display in
                    Text(display.name).tag(ScreenRecordingTarget.display(uuid: display.uuid))
                }
                if let name = model.disconnectedRecordingDisplayName {
                    Text(name + " (not connected)").tag(model.settings.screenRecordingTarget)
                }
                Text("All screens (separate videos)").tag(ScreenRecordingTarget.allDisplays)
                if #available(macOS 14.0, *) {
                    Text("Ask each time").tag(ScreenRecordingTarget.askEachTime)
                } else if model.settings.screenRecordingTarget == .askEachTime {
                    Text("Ask each time (requires macOS 14)").tag(ScreenRecordingTarget.askEachTime).disabled(true)
                }
            }
            if model.disconnectedRecordingDisplayName != nil {
                Text("The main display is used while the saved display is not connected.").font(.caption)
            }
            if #unavailable(macOS 14.0) {
                Text("Choosing with preview and Ask each time require macOS 14. The main display is used meanwhile.").font(.caption)
            }
            Toggle("Enable global shortcut (Control-Option-Command)", isOn: $model.settings.screenRecordingHotkeyEnabled)
            Picker("Shortcut key", selection: $model.settings.screenRecordingHotkeyKey) {
                ForEach(AppSettings.dictationKeys, id: \.self) { key in Text(key).tag(key) }
            }
            .disabled(!model.settings.screenRecordingHotkeyEnabled)
            if model.settings.screenRecordingHotkeyConflicts {
                Text("Choose a key different from the Dictation key. The screen recording shortcut is disabled until then.")
                    .font(.caption).foregroundStyle(.red)
            } else if let error = model.screenRecordingHotkeyError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Picker("Frame rate", selection: $model.settings.screenRecordingFrameRate) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            Toggle("Show cursor", isOn: $model.settings.screenRecordingShowsCursor)
            if #available(macOS 15.0, *) {
                Toggle("Include microphone", isOn: $model.settings.screenRecordingIncludesMicrophone)
            } else {
                Text("Include microphone requires macOS 15 or later.").font(.caption)
            }
            Text("System audio is included. The app's own audio is excluded.").font(.caption)
            LabeledContent("Save folder") {
                Text(model.settings.screenRecordingFolder).font(.caption).textSelection(.enabled)
            }
            HStack {
                Button("Choose…", action: chooseFolder)
                Button("Reset") { model.settings.screenRecordingFolder = ScreenRecordingFiles.defaultFolder }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: model.settings.screenRecordingFolder, isDirectory: true)
        if panel.runModal() == .OK, let folder = panel.url {
            model.settings.screenRecordingFolder = folder.path
        }
    }
}

@MainActor
private struct ProtectionPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            alertsSection
            killRuleSection
            Toggle(
                "Also list other apps that keep the Mac awake (information only)",
                isOn: $model.settings.showOtherSleepBlockers
            )
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
    }

    private var killRuleSection: some View {
        Section("Kill rule") {
            Stepper(
                "Release keep-awake and stop eligible caffeinate processes at: \(model.settings.policy.killThresholdPercent)%",
                value: Binding(
                    get: { model.settings.policy.killThresholdPercent },
                    set: { value in
                        let policy = model.settings.policy
                        model.settings.policy = PolicySettings(
                            killThresholdPercent: value,
                            maxKillsPerWindow: policy.maxKillsPerWindow,
                            killWindow: policy.killWindow
                        )
                    }
                ), in: 5...50
            )
        }
    }

    private var alertsSection: some View {
        Section("Alerts") {
            Stepper("Urgent below: \(model.settings.alerts.urgentBelowPercent)%", value: Binding(
                get: { model.settings.alerts.urgentBelowPercent },
                set: { updateAlerts(urgent: $0) }
            ), in: 2...100)
            Stepper("Critical below: \(model.settings.alerts.criticalBelowPercent)%", value: Binding(
                get: { model.settings.alerts.criticalBelowPercent },
                set: { updateAlerts(critical: $0) }
            ), in: 1...(model.settings.alerts.urgentBelowPercent - 1))
            TextField("Normal interval (seconds)", value: Binding(
                get: { model.settings.alerts.normalInterval },
                set: { updateAlerts(normalInterval: $0) }
            ), format: .number)
            TextField("Urgent interval (seconds)", value: Binding(
                get: { model.settings.alerts.urgentInterval },
                set: { updateAlerts(urgentInterval: $0) }
            ), format: .number)
            TextField("Critical interval (seconds)", value: Binding(
                get: { model.settings.alerts.criticalInterval },
                set: { updateAlerts(criticalInterval: $0) }
            ), format: .number)
            Text("Intervals must be at least 10 seconds.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button("Reset to defaults") { model.resetAlertsToDefaults() }
        }
    }

    private func updateAlerts(
        urgent: Int? = nil, critical: Int? = nil, normalInterval: Double? = nil,
        urgentInterval: Double? = nil, criticalInterval: Double? = nil
    ) {
        let alerts = model.settings.alerts
        model.settings.alerts = AlertSettings(
            urgentBelowPercent: urgent ?? alerts.urgentBelowPercent,
            criticalBelowPercent: critical ?? alerts.criticalBelowPercent,
            normalInterval: normalInterval ?? alerts.normalInterval,
            urgentInterval: urgentInterval ?? alerts.urgentInterval,
            criticalInterval: criticalInterval ?? alerts.criticalInterval
        )
    }
}

@MainActor
private struct TelegramPane: View {
    @ObservedObject var model: SettingsModel
    @Binding var token: String
    @Binding var createBot: Bool
    let isBusy: Bool
    let status: String?
    let run: (String, @escaping @MainActor () async throws -> Void) -> Void
    let cancel: () -> Void

    var body: some View {
        // The guided instructions and operation status can expand this pane.
        Form { telegramSection }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
    }

    private var telegramSection: some View {
        Section("Telegram") {
            Toggle("Enable Telegram", isOn: $model.settings.telegram.isEnabled)
            Group {
                botSetup
                chatSetup
                deliveryOptions
            }
            .disabled(!model.settings.telegram.isEnabled)
            if let status { Text(status).font(.callout).accessibilityLabel(status) }
        }
    }

    private var botSetup: some View {
        Group {
            Picker("Bot setup", selection: $createBot) {
                Text("Use existing bot").tag(false)
                Text("Create a new bot").tag(true)
            }
            if createBot {
                Text("1. Open Telegram and find the verified @BotFather.\n2. Send /newbot and follow the instructions to choose a name and username.\n3. Paste the bot token below, then validate and save it.")
                    .font(.callout)
            }
            HStack {
                SecureField("Bot token", text: $token)
                Button("Validate and save token") {
                    let candidate = token
                    token = ""
                    run("Bot validated. Token saved securely.") {
                        _ = try await model.validateAndSaveTelegramToken(candidate)
                    }
                }
                .disabled(token.isEmpty || isBusy)
            }
        }
    }

    private var chatSetup: some View {
        Group {
            TextField("Chat ID", text: Binding(
                get: { model.settings.telegram.chatID ?? "" },
                set: { model.settings.telegram.chatID = $0.isEmpty ? nil : $0 }
            ))
            Text("Start discovery, then open your bot in Telegram and send /start. Discovery waits up to 60 seconds for a new message.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Discover chat ID") {
                    run("Chat ID discovered.") { _ = try await model.discoverTelegramChatID() }
                }
                .disabled(isBusy)
                Button("Send test message") {
                    run("Test message sent.") { try await model.sendTelegramTestMessage() }
                }
                .disabled(isBusy)
                if isBusy {
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: cancel)
                }
            }
        }
    }

    private var deliveryOptions: some View {
        Group {
            HStack {
                Toggle("Silent mode", isOn: $model.settings.telegram.silentMode)
                Toggle("Include machine name", isOn: $model.settings.telegram.includeMachineName)
            }
            Text("Messages respect the phone’s silent and Do Not Disturb settings. The token is stored only in the Keychain.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
private struct UpdatesPane: View {
    @ObservedObject var model: SettingsModel
    let checkForUpdates: () -> Void

    var body: some View {
        Form {
            UpdatesSettingsSection(
                channel: Binding(
                    get: { model.settings.updateChannel },
                    set: { model.settings.updateChannel = $0; model.settings.skippedVersion = nil }
                ),
                automatically: $model.settings.checkForUpdatesAutomatically,
                checkNow: checkForUpdates
            )
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
    }
}

@MainActor
private struct AboutPane: View {
    private let build = BuildInfo.current

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                Text(AppInfo.name)
                    .font(.title2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            Form {
                Section {
                    Text("A personal pocket multi-tool for the Mac menu bar. Its first tool is a battery guard for forgotten caffeinate processes and other sleep blockers.")
                        .font(.callout)
                    LabeledContent(
                        "Version",
                        value: BuildInfo.aboutVersion(version: build.version, sha: build.sha, channel: build.channel)
                    )
                    LabeledContent("Build SHA", value: build.sha)
                    LabeledContent("Channel", value: build.channel)
                    LabeledContent("License", value: "Apache-2.0")
                    Link(
                        "fperdigon/macpocketknife",
                        destination: URL(string: "https://github.com/fperdigon/macpocketknife")!
                    )
                    Link("Developed by Francisco Perdigon Romero | Founder of Core AI", destination: URL(string: "https://core-ai.net")!)
                    Link("Francisco Perdigon Romero on GitHub", destination: URL(string: "https://github.com/fperdigon")!)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
        }
    }
}
