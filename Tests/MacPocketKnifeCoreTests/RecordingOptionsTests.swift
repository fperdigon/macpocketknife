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
import Testing

struct RecordingOptionsTests {
    private let mainID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let otherID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

    @Test func connectedChoicesKeepDisplayOrderAndDescribeResolution() {
        let displays = [
            DisplayInfo(uuid: mainID, name: "Built-in", pixelWidth: 3024, pixelHeight: 1964, isMain: true),
            DisplayInfo(uuid: otherID, name: "Desk", pixelWidth: 3840, pixelHeight: 2160, isMain: false),
        ]
        let target = ScreenRecordingTarget.display(uuid: otherID)
        let options = RecordingOptions(displays: displays, target: target, supportsPreview: true)
        #expect(options.selection == target)
        #expect(options.choices.map(\.target) == [.mainDisplay, .display(uuid: mainID), target, .allDisplays, .askEachTime])
        #expect(options.choices.map(\.title) == ["Main display", "Built-in — 3024 × 1964 (Main)",
                                              "Desk — 3840 × 2160", "All screens (separate videos)", "Choose with preview…"])
        #expect(options.choices.allSatisfy { $0.isEnabled })
    }

    @Test func disconnectedChoicePreservesSelectionAndSavedName() {
        let target = ScreenRecordingTarget.display(uuid: otherID)
        let options = RecordingOptions(displays: [], target: target, supportsPreview: false, savedDisplayName: "Desk")
        #expect(options.selection == target)
        #expect(options.choices.map(\.target) == [.mainDisplay, target, .allDisplays])
        #expect(options.choices[1].title == "Desk (not connected)")
        #expect(options.choices[1].isEnabled)
        let unnamed = RecordingOptions(displays: [], target: target, supportsPreview: true)
        #expect(unnamed.choices[1].title == "Saved display (not connected)")
    }

    @Test func unavailablePreviewPreservesSavedChoiceButDisablesIt() {
        let options = RecordingOptions(displays: [], target: .askEachTime, supportsPreview: false)
        #expect(options.selection == .askEachTime)
        #expect(options.choices.map(\.target) == [.mainDisplay, .allDisplays, .askEachTime])
        #expect(options.choices.last?.title == "Choose with preview… (requires macOS 14)")
        #expect(options.choices.last?.isEnabled == false)
        let main = RecordingOptions(displays: [], target: .mainDisplay, supportsPreview: false)
        #expect(main.selection == .mainDisplay)
        #expect(main.choices.map(\.target) == [.mainDisplay, .allDisplays])
    }

    @Test func invalidSelectionFallsBackToMainAndUUIDCaseMatchesConnectedDisplay() {
        let invalid = RecordingOptions(displays: [], target: .display(uuid: "invalid"), supportsPreview: true)
        #expect(invalid.selection == .mainDisplay)
        #expect(invalid.choices.count == 3)
        let display = DisplayInfo(uuid: otherID.lowercased(), name: "Desk", pixelWidth: 1920, pixelHeight: 1080, isMain: false)
        let options = RecordingOptions(displays: [display], target: .display(uuid: otherID.lowercased()), supportsPreview: true)
        #expect(options.selection == .display(uuid: otherID))
        #expect(options.choices.count == 4)
        #expect(options.choices[1].target == options.selection)
    }

    @Test func allScreensSelectionIsKeptWithoutConnectedDisplays() {
        let options = RecordingOptions(displays: [], target: .allDisplays, supportsPreview: true)
        #expect(options.selection == .allDisplays)
        #expect(options.choices.map(\.target) == [.mainDisplay, .allDisplays, .askEachTime])
    }
}
