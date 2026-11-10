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

import Foundation

public protocol NoticeComposing: Sendable {
    func compose(alert: BatteryAlert, blockers: [String], estimate: BatteryEstimate) -> Notice
    func compose(action: PolicyAction) -> Notice
}

public extension NoticeComposing {
    func compose(alert: BatteryAlert, blockers: [String]) -> Notice {
        compose(alert: alert, blockers: blockers, estimate: BatteryEstimate())
    }
}

public struct NoticeComposer: NoticeComposing {
    public init() {}

    public func compose(
        alert: BatteryAlert, blockers: [String] = [], estimate: BatteryEstimate = BatteryEstimate()
    ) -> Notice {
        let title: String
        switch alert.level {
        case .normal: title = "Battery alert"
        case .urgent: title = "Urgent battery alert"
        case .critical: title = "Critical battery alert"
        }
        let names = SleepBlockerSummary.alertNames(blockers)
        let keepingAwake = names.isEmpty ? "caffeinate or the app's own keep-awake" : names.joined(separator: ", ")
        let remaining = StatusLineFormatter.alertEstimate(estimate)
        return Notice(
            kind: .batteryAlert, title: title,
            body: "Battery at \(alert.batteryPercent)%\(remaining). Keeping the Mac awake: \(keepingAwake).",
            level: alert.level
        )
    }

    /// Keep recognized text out of notifications and their persistent history.
    public func composeDictation(wordCount: Int) -> Notice {
        if wordCount == 0 {
            return Notice(kind: .info, title: "No speech detected", body: "The clipboard was left unchanged.")
        }
        return Notice(
            kind: .info, title: "Dictation copied to the clipboard",
            body: "\(wordCount) words. Paste with Command-V."
        )
    }

    public func composeDictation(failure: DictationFailure) -> Notice {
        Notice(kind: .info, title: "Dictation unavailable", body: failure.message)
    }

    public func composeScreenRecording(savedFile: URL) -> Notice {
        Notice(kind: .info, title: "Screen recording saved",
               body: "\(savedFile.lastPathComponent)\nFolder: \(savedFile.deletingLastPathComponent().path)")
    }

    public func composeScreenRecording(savedFiles: [URL], interruptedDisplays: [String] = [], notice: String? = nil) -> Notice {
        let title: String
        var body: String
        if let first = savedFiles.first {
            let single = composeScreenRecording(savedFile: first)
            title = savedFiles.count == 1 ? single.title : "\(savedFiles.count) screen recordings saved"
            body = single.body
        } else {
            title = "Screen recording ended"
            body = "No usable video was saved."
        }
        if !interruptedDisplays.isEmpty {
            body += "\nSharing ended early: " + interruptedDisplays.joined(separator: ", ") + "."
        }
        if let notice { body += "\n" + notice }
        return Notice(kind: .info, title: title, body: body)
    }

    public func composeScreenRecording(failure: ScreenRecordingFailure) -> Notice {
        Notice(kind: .info, title: "Screen recording unavailable", body: failure.message)
    }

    /// Compose termination notices only after the corresponding action succeeds.
    public func compose(action: PolicyAction) -> Notice {
        switch action {
        case .notifyDetected(let classified):
            let process = classified.assertion
            let name = SleepBlockerSummary.displayName(for: process.processName) ?? "an active sleep assertion"
            return Notice(
                kind: .keepAwakeDetected, title: "Keep-awake process detected",
                body: "\(name) (PID \(process.pid)) is keeping the Mac awake."
            )
        case .terminate(let pid, let processName, let reason):
            let explanation: String
            switch reason {
            case .consoleStarted: explanation = "started from a console"
            case .batteryThreshold: explanation = "battery threshold reached"
            }
            return Notice(
                kind: .processTerminated, title: "Keep-awake process terminated",
                body: "\(processName) (PID \(pid)) terminated: \(explanation)."
            )
        case .notifyTerminationSkipped(let pid, let reason):
            let explanation: String
            switch reason {
            case .notOwnedByCurrentUser: explanation = "not owned by the current user"
            case .killLoopLimit: explanation = "termination retry limit reached"
            }
            return Notice(
                kind: .terminationSkipped, title: "Termination skipped",
                body: "PID \(pid): \(explanation)."
            )
        case .releaseOwnAssertion:
            return Notice(
                kind: .info, title: "Keep-awake released",
                body: "The app's sleep assertion was released: battery threshold reached."
            )
        }
    }
}
