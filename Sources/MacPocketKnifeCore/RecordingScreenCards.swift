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

public enum RecordingScreenMode: String, CaseIterable, Sendable {
    case oneScreen = "One screen"
    case allScreens = "All screens (separate videos)"
    case systemPicker = "Choose with system picker…"
}

public struct RecordingScreenCard: Equatable, Sendable {
    public let display: DisplayInfo
    public let isSelected: Bool
    public let isDimmed: Bool
    public let badge: String?
    public let isClickable: Bool

    public var target: ScreenRecordingTarget {
        ScreenRecordingTarget.display(uuid: display.uuid).validated()
    }
}

public struct RecordingScreenCards: Equatable, Sendable {
    public let modes: [RecordingScreenMode]
    public let mode: RecordingScreenMode
    public let cards: [RecordingScreenCard]
    private let target: ScreenRecordingTarget

    public init(displays: [DisplayInfo], target: ScreenRecordingTarget, supportsSystemPicker: Bool) {
        self.target = target.validated()
        var modes: [RecordingScreenMode] = [.oneScreen]
        if displays.count > 1 { modes.append(.allScreens) }
        if supportsSystemPicker { modes.append(.systemPicker) }
        self.modes = modes
        let requestedMode: RecordingScreenMode
        switch self.target {
        case .allDisplays: requestedMode = .allScreens
        case .askEachTime: requestedMode = .systemPicker
        case .mainDisplay, .display: requestedMode = .oneScreen
        }
        let mode = modes.contains(requestedMode) ? requestedMode : .oneScreen
        self.mode = mode
        let effectiveTarget = mode == .oneScreen ? Self.singleScreenTarget(for: self.target) : self.target
        let resolution = try? ScreenRecordingTargets.resolve(effectiveTarget, displays: displays)
        let selectedIDs = resolution?.displays.map(\.uuid) ?? []
        cards = displays.map { display in
            let index = selectedIDs.firstIndex(of: display.uuid)
            let selected = index != nil && mode != .systemPicker
            let badge = mode == .allScreens ? index.map { "Video \($0 + 1)" } : nil
            return RecordingScreenCard(display: display, isSelected: selected,
                                       isDimmed: !selected, badge: badge, isClickable: mode == .oneScreen)
        }
    }

    private static func singleScreenTarget(for target: ScreenRecordingTarget) -> ScreenRecordingTarget {
        switch target {
        case .mainDisplay, .display: return target
        case .allDisplays, .askEachTime: return .mainDisplay
        }
    }

    public func target(for mode: RecordingScreenMode) -> ScreenRecordingTarget {
        switch mode {
        case .oneScreen: return Self.singleScreenTarget(for: target)
        case .allScreens: return .allDisplays
        case .systemPicker: return .askEachTime
        }
    }
}
