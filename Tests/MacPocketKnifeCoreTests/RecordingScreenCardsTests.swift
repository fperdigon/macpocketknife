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

struct RecordingScreenCardsTests {
    private let mainID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let otherID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

    private var displays: [DisplayInfo] {
        [DisplayInfo(uuid: otherID, name: "Desk", pixelWidth: 3840, pixelHeight: 2160, isMain: false),
         DisplayInfo(uuid: mainID, name: "Built-in", pixelWidth: 3024, pixelHeight: 1964, isMain: true)]
    }

    @Test func mainDisplayIsSelectedByDefaultAndCardsKeepDisplayOrder() {
        let options = RecordingScreenCards(displays: displays, target: .mainDisplay, supportsSystemPicker: true)
        #expect(options.modes == [.oneScreen, .allScreens, .systemPicker])
        #expect(options.mode == .oneScreen)
        #expect(options.cards.map(\.display) == displays)
        #expect(options.cards.map(\.isSelected) == [false, true])
        #expect(options.cards.map(\.isDimmed) == [true, false])
        #expect(options.cards.allSatisfy { $0.isClickable && $0.badge == nil })
        #expect(options.target(for: .oneScreen) == .mainDisplay)
        #expect(options.target(for: .allScreens) == .allDisplays)
        #expect(options.target(for: .systemPicker) == .askEachTime)
    }

    @Test func selectingDisplayUsesValidatedUUIDAndRoundTrips() {
        let target = ScreenRecordingTarget.display(uuid: otherID.lowercased())
        let options = RecordingScreenCards(displays: displays, target: target, supportsSystemPicker: false)
        #expect(options.modes == [.oneScreen, .allScreens])
        #expect(options.cards.map(\.isSelected) == [true, false])
        #expect(options.target(for: .oneScreen) == .display(uuid: otherID))
        #expect(options.cards[0].target == .display(uuid: otherID))
        let lowercaseDisplay = DisplayInfo(uuid: mainID.lowercased(), name: "Main", pixelWidth: 1, pixelHeight: 1, isMain: true)
        let lowercase = RecordingScreenCards(displays: [lowercaseDisplay], target: .display(uuid: mainID), supportsSystemPicker: true)
        #expect(lowercase.cards[0].isSelected)
        #expect(lowercase.cards[0].target == .display(uuid: mainID))
    }

    @Test func disconnectedAndInvalidSelectionsHighlightMainWithoutLosingSavedTarget() {
        let missing = ScreenRecordingTarget.display(uuid: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
        let options = RecordingScreenCards(displays: displays, target: missing, supportsSystemPicker: true)
        #expect(options.cards.map(\.isSelected) == [false, true])
        #expect(options.target(for: .oneScreen) == missing)
        let invalid = RecordingScreenCards(displays: displays, target: .display(uuid: "invalid"), supportsSystemPicker: true)
        #expect(invalid.cards.map(\.isSelected) == [false, true])
        #expect(invalid.target(for: .oneScreen) == .mainDisplay)
    }

    @Test func allScreensHighlightsEveryCardAndNumbersInRecorderOrder() {
        let options = RecordingScreenCards(displays: displays, target: .allDisplays, supportsSystemPicker: true)
        #expect(options.mode == .allScreens)
        #expect(options.cards.allSatisfy { $0.isSelected && !$0.isDimmed && !$0.isClickable })
        #expect(options.cards.map(\.badge) == ["Video 2", "Video 1"])
        #expect(options.target(for: .oneScreen) == .mainDisplay)
    }

    @Test func systemPickerDimsEveryCardAndDisablesClicks() {
        let options = RecordingScreenCards(displays: displays, target: .askEachTime, supportsSystemPicker: true)
        #expect(options.mode == .systemPicker)
        #expect(options.cards.allSatisfy { !$0.isSelected && $0.isDimmed && !$0.isClickable && $0.badge == nil })
        #expect(options.target(for: .oneScreen) == .mainDisplay)
        let unsupported = RecordingScreenCards(displays: displays, target: .askEachTime, supportsSystemPicker: false)
        #expect(unsupported.mode == .oneScreen)
        #expect(unsupported.cards.map(\.isSelected) == [false, true])
    }

    @Test func singleDisplayHidesAllScreensAndShowsSelectedCardEvenForSavedAllScreens() {
        for target in [ScreenRecordingTarget.mainDisplay, .allDisplays] {
            let options = RecordingScreenCards(displays: [displays[1]], target: target, supportsSystemPicker: true)
            #expect(options.modes == [.oneScreen, .systemPicker])
            #expect(options.mode == .oneScreen)
            #expect(options.cards.count == 1)
            #expect(options.cards[0].isSelected && !options.cards[0].isDimmed && options.cards[0].isClickable)
            #expect(options.cards[0].badge == nil)
        }
        let legacy = RecordingScreenCards(displays: [displays[0]], target: .mainDisplay, supportsSystemPicker: false)
        #expect(legacy.modes == [.oneScreen])
        #expect(legacy.cards[0].isSelected)
    }

    @Test func emptyDisplaysAndMissingMainAreHandledLikeRecorder() {
        for target in [ScreenRecordingTarget.mainDisplay, .allDisplays, .askEachTime] {
            let options = RecordingScreenCards(displays: [], target: target, supportsSystemPicker: true)
            #expect(options.cards.isEmpty)
            #expect(!options.modes.contains(.allScreens))
        }
        let noMain = DisplayInfo(uuid: mainID, name: "Other", pixelWidth: 10, pixelHeight: 10, isMain: false)
        let options = RecordingScreenCards(displays: [displays[0], noMain], target: .allDisplays, supportsSystemPicker: true)
        #expect(options.cards.map(\.badge) == ["Video 1", "Video 2"])
    }
}
