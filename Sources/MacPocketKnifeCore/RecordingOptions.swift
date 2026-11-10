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

@preconcurrency import Foundation

public struct RecordingOption: Equatable, Sendable {
    public let target: ScreenRecordingTarget
    public let title: String
    public let isEnabled: Bool
}

public struct RecordingOptions: Equatable, Sendable {
    public let choices: [RecordingOption]
    public let selection: ScreenRecordingTarget

    public init(displays: [DisplayInfo], target: ScreenRecordingTarget,
                supportsPreview: Bool, savedDisplayName: String? = nil) {
        let selected = target.validated()
        var choices = [RecordingOption(target: .mainDisplay, title: "Main display", isEnabled: true)]
        for display in displays {
            let main = display.isMain ? " (Main)" : ""
            let title = "\(display.name) — \(display.pixelWidth) × \(display.pixelHeight)\(main)"
            let displayTarget = ScreenRecordingTarget.display(uuid: display.uuid).validated()
            choices.append(RecordingOption(target: displayTarget, title: title, isEnabled: true))
        }
        if case .display = selected, !choices.contains(where: { $0.target == selected }) {
            let title = (savedDisplayName ?? "Saved display") + " (not connected)"
            choices.append(RecordingOption(target: selected, title: title, isEnabled: true))
        }
        choices.append(RecordingOption(target: .allDisplays, title: "All screens (separate videos)", isEnabled: true))
        if supportsPreview {
            choices.append(RecordingOption(target: .askEachTime, title: "Choose with preview…", isEnabled: true))
        } else if selected == .askEachTime {
            choices.append(RecordingOption(target: .askEachTime, title: "Choose with preview… (requires macOS 14)", isEnabled: false))
        }
        self.choices = choices
        selection = selected
    }
}
