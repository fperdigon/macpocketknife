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
import MacPocketKnifeCore
import Testing

@MainActor
private final class FakeScreenRecorder: ScreenRecording {
    var onFailure: (@MainActor (ScreenRecordingFailure?) -> Void)?
    var startFailure: ScreenRecordingFailure?
    var stopFailure: ScreenRecordingFailure?
    var starts = 0
    var stops = 0
    var configuration: ScreenRecordingConfiguration?
    var destination: URL?
    var savedFile: URL? = URL(fileURLWithPath: "/Movies/Screen example.mp4")
    var holdStart = false
    var holdStop = false
    var startContinuation: CheckedContinuation<Void, Never>?
    var stopContinuation: CheckedContinuation<Void, Never>?
    var display: DisplayInfo?
    var content: (any ScreenRecordingContent)?
    func start(configuration: ScreenRecordingConfiguration, destination: URL, display: DisplayInfo?,
               content: (any ScreenRecordingContent)?) async throws {
        self.display = display
        self.content = content
        starts += 1
        self.configuration = configuration
        self.destination = destination
        if holdStart { await withCheckedContinuation { startContinuation = $0 } }
        if let startFailure { throw startFailure }
    }
    func stop() async throws -> URL? {
        stops += 1
        if holdStop { await withCheckedContinuation { stopContinuation = $0 } }
        if let stopFailure { throw stopFailure }
        return savedFile
    }
}

@MainActor
private final class ScreenDependencies: ScreenRecordingPermissionProviding, FreeDiskSpaceProviding, RecordingFileManaging, AlertNotifying {
    var allowed = true
    var bytes: Int64 = 2_000_000_000
    var diskFails = false
    var folderFails = false
    var existingCount = 0
    var existenceChecks = 0
    var folders: [URL] = []
    var revealed: [URL] = []
    var notices: [Notice] = []
    func requestAccessIfNeeded() -> Bool { allowed }
    func availableBytes(at folder: URL) throws -> Int64 {
        if diskFails { throw ScreenRecordingFailure.writingFailed }
        return bytes
    }
    func createFolder(_ folder: URL) throws {
        if folderFails { throw ScreenRecordingFailure.folderUnavailable }
        folders.append(folder)
    }
    func exists(_ file: URL) -> Bool {
        existenceChecks += 1
        return existenceChecks <= existingCount
    }
    func revealFolder(_ folder: URL) { revealed.append(folder) }
    func deliver(_ notice: Notice) async { notices.append(notice) }
}

@MainActor
private final class ScreenEnvironment: ScreenRecordingFactory, ScreenRecordingDisplayProviding, ScreenRecordingPicking {
    static let main = DisplayInfo(uuid: "11111111-1111-1111-1111-111111111111", name: "Main", pixelWidth: 1920, pixelHeight: 1080, isMain: true)
    static let other = DisplayInfo(uuid: "22222222-2222-2222-2222-222222222222", name: "Other", pixelWidth: 2560, pixelHeight: 1440, isMain: false)
    var displays: [DisplayInfo] = [main]
    var recorders: [FakeScreenRecorder]
    var nextRecorder = 0
    var isSupported = true
    var content: (any ScreenRecordingContent)?
    var pickerFailure: ScreenRecordingFailure?
    var pickerCalls = 0
    var holdPicker = false
    var pickerContinuation: CheckedContinuation<Void, Never>?
    init(recorders: [FakeScreenRecorder]) { self.recorders = recorders }
    func makeRecorder() -> any ScreenRecording {
        defer { nextRecorder += 1 }
        return recorders[nextRecorder]
    }
    func connectedDisplays() -> [DisplayInfo] { displays }
    func chooseContent() async throws -> (any ScreenRecordingContent)? {
        pickerCalls += 1
        if holdPicker { await withCheckedContinuation { pickerContinuation = $0 } }
        if let pickerFailure { throw pickerFailure }
        return content
    }
    func cancel() {
        pickerContinuation?.resume()
        pickerContinuation = nil
    }
}

@MainActor private final class FakeRecordingContent: ScreenRecordingContent {}

@MainActor
private struct ScreenFixture {
    let recorder = FakeScreenRecorder()
    let dependencies = ScreenDependencies()
    let scheduler = FakeKeepAwakeScheduler()
    let controller: ScreenRecordingController
    let environment: ScreenEnvironment
    init() {
        environment = ScreenEnvironment(recorders: [recorder, recorder])
        controller = ScreenRecordingController(factory: environment, displays: environment, picker: environment, permission: dependencies,
                                              disk: dependencies, files: dependencies,
                                              scheduler: scheduler, notices: dependencies)
    }
    func settle() async { for _ in 0..<50 { await Task.yield() } }
    func start() async {
        controller.toggle(settings: AppSettings())
        await settle()
    }
}

@MainActor
struct ScreenRecordingTests {
    @Test func happyPathAndTicker() async {
        let f = ScreenFixture()
        var changes = 0
        f.controller.onChange = { changes += 1 }
        f.dependencies.existingCount = 2
        await f.start()
        #expect(f.controller.state == .recording)
        #expect(f.recorder.starts == 1)
        #expect(f.recorder.configuration == ScreenRecordingConfiguration(frameRate: 30, showsCursor: true, includesMicrophone: false))
        #expect(f.recorder.destination?.lastPathComponent.hasSuffix(" 3.mp4") == true)
        #expect(f.scheduler.pendingCount == 1)
        f.scheduler.advance(by: 1)
        #expect(f.controller.elapsedTitle == "00:01")
        f.scheduler.advance(by: 64)
        #expect(f.controller.elapsedTitle == "01:05")
        f.controller.toggle(settings: AppSettings())
        #expect(f.controller.state == .stopping)
        await f.settle()
        #expect(f.controller.state == .idle)
        #expect(f.controller.lastSavedFile == f.recorder.savedFile)
        #expect(f.recorder.stops == 1)
        #expect(f.scheduler.pendingCount == 0)
        #expect(f.recorder.onFailure == nil)
        let notice = f.dependencies.notices.last
        #expect(notice?.title == "Screen recording saved")
        #expect(notice?.body == "Screen example.mp4\nFolder: /Movies")
        #expect(changes >= 5)
        f.scheduler.advance(by: 1, includingCancelled: true)
        #expect(f.controller.elapsedSeconds == 65)
    }

    @Test func permissionDeniedAndRetry() async {
        let f = ScreenFixture()
        f.dependencies.allowed = false
        await f.start()
        #expect(f.recorder.starts == 0)
        #expect(f.controller.state == .error)
        #expect(f.controller.lastError == ScreenRecordingFailure.permissionDenied.message)
        #expect(f.dependencies.notices.last?.body.contains("Screen & System Audio Recording") == true)
        f.dependencies.allowed = true
        await f.start()
        #expect(f.controller.state == .recording)
        #expect(f.controller.lastError == nil)
        await f.controller.stopAndWait()
    }

    @Test func lowDiskSpace() async {
        let f = ScreenFixture()
        f.dependencies.bytes = 999_999_999
        await f.start()
        #expect(f.controller.lastError == ScreenRecordingFailure.lowDiskSpace.message)
        #expect(f.recorder.starts == 0)
        #expect(f.dependencies.notices.last?.title == "Screen recording unavailable")
        f.dependencies.bytes = 1_000_000_000
        await f.start()
        #expect(f.controller.state == .recording)
        await f.controller.stopAndWait()
    }

    @Test(arguments: [false, true]) func folderOrDiskUnavailable(disk: Bool) async {
        let f = ScreenFixture()
        f.dependencies.diskFails = disk
        f.dependencies.folderFails = !disk
        await f.start()
        #expect(f.controller.lastError == ScreenRecordingFailure.folderUnavailable.message)
        #expect(f.recorder.starts == 0)
    }

    @Test(arguments: [ScreenRecordingFailure.captureFailed, .writingFailed, .noDisplay, .microphoneDenied])
    func startFailureAlwaysFinalizes(_ failure: ScreenRecordingFailure) async {
        let f = ScreenFixture()
        f.recorder.startFailure = failure
        f.recorder.savedFile = nil
        await f.start()
        #expect(f.controller.state == .error)
        #expect(f.controller.lastError == failure.message)
        #expect(f.recorder.stops == 1)
        #expect(f.controller.lastSavedFile == nil)
        #expect(f.dependencies.notices.count == 1)
        #expect(f.dependencies.notices.last?.body == failure.message)
    }

    @Test func recorderFailureFinalizesPartialFile() async {
        let f = ScreenFixture()
        await f.start()
        f.recorder.onFailure?(.captureFailed)
        await f.settle()
        #expect(f.recorder.stops == 1)
        #expect(f.controller.state == .error)
        #expect(f.dependencies.notices.map(\.title) == ["Screen recording saved", "Screen recording unavailable"])
        #expect(f.controller.lastSavedFile == f.recorder.savedFile)
        #expect(f.scheduler.pendingCount == 0)
    }

    @Test func systemStopAndEmptyOutput() async {
        let f = ScreenFixture()
        await f.start()
        f.recorder.onFailure?(nil)
        await f.settle()
        #expect(f.controller.state == .idle)
        #expect(f.dependencies.notices.last?.title == "Screen recording saved")
        f.recorder.savedFile = nil
        await f.start()
        await f.controller.stopAndWait()
        #expect(f.controller.state == .idle)
        #expect(f.controller.lastSavedFile == nil)
        #expect(f.dependencies.notices.count == 1)
    }

    @Test func writingFailureRemovesUsableResult() async {
        let f = ScreenFixture()
        await f.start()
        f.recorder.stopFailure = .writingFailed
        await f.controller.stopAndWait()
        await f.settle()
        #expect(f.controller.lastSavedFile == nil)
        #expect(f.controller.lastError == ScreenRecordingFailure.writingFailed.message)
        #expect(f.dependencies.notices.count == 1)
    }

    @Test func doubleToggleDuringStartAndStop() async {
        let f = ScreenFixture()
        f.recorder.holdStart = true
        await f.start()
        #expect(f.controller.state == .starting)
        f.controller.toggle(settings: AppSettings())
        f.controller.toggle(settings: AppSettings())
        #expect(f.controller.state == .stopping)
        #expect(f.recorder.stops == 0)
        f.recorder.holdStop = true
        f.recorder.startContinuation?.resume()
        await f.settle()
        f.controller.toggle(settings: AppSettings())
        #expect(f.recorder.starts == 1)
        #expect(f.recorder.stops == 1)
        f.recorder.stopContinuation?.resume()
        await f.settle()
        #expect(f.controller.state == .idle)
        #expect(f.scheduler.pendingCount == 0)
    }

    @Test func failureDuringStartupAndTerminationWait() async {
        let f = ScreenFixture()
        f.recorder.holdStart = true
        await f.start()
        f.recorder.onFailure?(.captureFailed)
        let stop = Task { await f.controller.stopAndWait() }
        await f.settle()
        #expect(f.controller.state == .stopping)
        f.recorder.startContinuation?.resume()
        await stop.value
        await f.settle()
        #expect(f.recorder.stops == 1)
        #expect(f.controller.lastError == ScreenRecordingFailure.captureFailed.message)
    }

    @Test(arguments: [false, true]) func diskFillsOrDisappears(throwsError: Bool) async {
        let f = ScreenFixture()
        await f.start()
        f.dependencies.diskFails = throwsError
        f.dependencies.bytes = 0
        f.scheduler.advance(by: 1)
        await f.settle()
        #expect(f.recorder.stops == 1)
        #expect(f.controller.lastError == ScreenRecordingFailure.writingFailed.message)
        #expect(f.scheduler.pendingCount == 0)
    }

    @Test func revealFolderAndFactory() async {
        let recorder = FakeScreenRecorder()
        let dependencies = ScreenDependencies()
        let environment = ScreenEnvironment(recorders: [recorder])
        let controller = ScreenRecordingController.make(factory: environment, displays: environment, picker: environment, permission: dependencies,
                                                        disk: dependencies, files: dependencies, notices: dependencies)
        await controller.stopAndWait()
        controller.showRecordings(folderPath: "/Movies")
        #expect(dependencies.folders == dependencies.revealed)
        #expect(dependencies.revealed.count == 1)
        dependencies.folderFails = true
        controller.showRecordings(folderPath: "/Unavailable")
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.lastError == ScreenRecordingFailure.folderUnavailable.message)
    }

    @Test func folderErrorDoesNotInterruptRecording() async {
        let f = ScreenFixture()
        await f.start()
        f.dependencies.folderFails = true
        f.controller.showRecordings(folderPath: "/Unavailable")
        #expect(f.controller.state == .recording)
        #expect(f.controller.lastError == ScreenRecordingFailure.folderUnavailable.message)
        await f.controller.stopAndWait()
        #expect(f.recorder.stops == 1)
    }

    @Test func filenamesAndBitrate() {
        let date = Date(timeIntervalSince1970: 0)
        let zone = TimeZone(secondsFromGMT: 0)!
        #expect(ScreenRecordingFiles.name(date: date, timeZone: zone) == "Screen 1970-01-01 00.00.00.mp4")
        #expect(ScreenRecordingFiles.name(date: date, timeZone: zone, collision: 2) == "Screen 1970-01-01 00.00.00 2.mp4")
        #expect(ScreenRecordingFiles.name(date: date, timeZone: TimeZone(secondsFromGMT: 3600)!) == "Screen 1970-01-01 01.00.00.mp4")
        #expect(ScreenRecordingFiles.bitrate(width: 1, height: 1, frameRate: 30) == 4_000_000)
        #expect(ScreenRecordingFiles.bitrate(width: -1, height: 1, frameRate: 30) == 4_000_000)
        #expect(ScreenRecordingFiles.bitrate(width: 1920, height: 1080, frameRate: 60) == 8_709_120)
        #expect(ScreenRecordingFiles.bitrate(width: 7680, height: 4320, frameRate: 60) == 40_000_000)
        #expect(ScreenRecordingFiles.bitrate(width: Int.max, height: Int.max, frameRate: Int.max) == 40_000_000)
        #expect(ScreenRecordingConfiguration(frameRate: 45, showsCursor: false, includesMicrophone: true).frameRate == 30)
    }

    @Test func oldSettingsAndSanitizing() throws {
        let data = try JSONEncoder().encode(AppSettings())
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in object.keys where key.hasPrefix("screenRecording") { object.removeValue(forKey: key) }
        let old = try JSONSerialization.data(withJSONObject: object)
        let settings = try JSONDecoder().decode(AppSettings.self, from: old)
        #expect(settings.screenRecordingTarget == .mainDisplay)
        #expect(settings.screenRecordingHotkeyEnabled)
        #expect(settings.screenRecordingHotkeyKey == "R")
        #expect(settings.screenRecordingFrameRate == 30)
        #expect(settings.screenRecordingShowsCursor)
        #expect(!settings.screenRecordingIncludesMicrophone)
        #expect(settings.screenRecordingFolder == ScreenRecordingFiles.defaultFolder)
        var invalid = settings
        invalid.screenRecordingHotkeyKey = " rr "
        invalid.screenRecordingFrameRate = 45
        invalid.screenRecordingFolder = "  "
        let valid = invalid.validated()
        #expect(valid == settings)
        invalid.screenRecordingHotkeyKey = " a "
        invalid.screenRecordingFrameRate = 60
        invalid.screenRecordingFolder = "~/Movies/Custom"
        invalid.screenRecordingShowsCursor = false
        invalid.screenRecordingIncludesMicrophone = true
        let custom = invalid.validated()
        #expect(custom.screenRecordingHotkeyKey == "A")
        #expect(custom.screenRecordingFrameRate == 60)
        #expect(custom.screenRecordingFolder.hasSuffix("/Movies/Custom"))
        #expect(!custom.screenRecordingFolder.hasPrefix("~"))
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(custom))
        #expect(decoded == custom)
        invalid.screenRecordingHotkeyKey = "t"
        #expect(invalid.validated().screenRecordingHotkeyConflicts)
        invalid.dictationHotkeyEnabled = false
        #expect(!invalid.validated().screenRecordingHotkeyConflicts)
        invalid.dictationHotkeyEnabled = true
        invalid.screenRecordingHotkeyEnabled = false
        #expect(!invalid.validated().screenRecordingHotkeyConflicts)
    }
    @Test func resolutionAndTargetCoding() throws {
        let main = ScreenEnvironment.main
        let other = ScreenEnvironment.other
        let displays = [other, main]
        #expect(try ScreenRecordingTargets.resolve(.mainDisplay, displays: displays)?.displays == [main])
        #expect(try ScreenRecordingTargets.resolve(.display(uuid: other.uuid), displays: displays)?.displays == [other])
        let fallback = try ScreenRecordingTargets.resolve(.display(uuid: "missing"), displays: displays)
        #expect(fallback?.fellBack == true)
        #expect(fallback?.displays == [main])
        #expect(try ScreenRecordingTargets.resolve(.allDisplays, displays: displays)?.displays == [main, other])
        #expect(try ScreenRecordingTargets.resolve(.mainDisplay, displays: [other])?.displays == [other])
        #expect(try ScreenRecordingTargets.resolve(.askEachTime, displays: displays) == nil)
        #expect(try ScreenRecordingTargets.resolve(.askEachTime, displays: displays, chosenTarget: .askEachTime) == nil)
        #expect(try ScreenRecordingTargets.resolve(.askEachTime, displays: displays, chosenTarget: .allDisplays)?.displays == [main, other])
        #expect(throws: ScreenRecordingFailure.noDisplay) { try ScreenRecordingTargets.resolve(.allDisplays, displays: []) }
        let targets: [ScreenRecordingTarget] = [.mainDisplay, .allDisplays, .askEachTime, .display(uuid: other.uuid)]
        for target in targets {
            var settings = AppSettings()
            settings.screenRecordingTarget = target
            #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).screenRecordingTarget == target)
            #expect(settings.validated().screenRecordingTarget == target)
        }
        #expect(ScreenRecordingTarget.display(uuid: "  ").validated() == .mainDisplay)
        let lower = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        #expect(ScreenRecordingTarget.display(uuid: lower).validated() == .display(uuid: lower.uppercased()))
        #expect(try JSONDecoder().decode(DisplayInfo.self, from: JSONEncoder().encode(main)) == main)
    }

    @Test func multiFileNamesAndNotices() {
        let date = Date(timeIntervalSince1970: 0)
        let zone = TimeZone(secondsFromGMT: 0)!
        let name = ScreenRecordingFiles.name(date: date, timeZone: zone, displayName: "Desk/Screen: 1")
        #expect(name == "Screen 1970-01-01 00.00.00 - Desk-Screen- 1.mp4")
        #expect(ScreenRecordingFiles.name(date: date, timeZone: zone, collision: 2, displayName: "Desk") == "Screen 1970-01-01 00.00.00 - Desk 2.mp4")
        #expect(ScreenRecordingFiles.sanitizedDisplayName(" .. ") == "Display")
        #expect(ScreenRecordingFiles.sanitizedDisplayName("A\nB\\C*?\"<>|") == "A-B-C------")
        #expect(ScreenRecordingFiles.sanitizedDisplayName(String(repeating: "x", count: 200)).count == 80)
        #expect(ScreenRecordingFiles.sanitizedDisplayName(String(repeating: "🖥️", count: 200)).utf8.count <= 160)
        let first = URL(fileURLWithPath: "/Movies/first.mp4")
        let second = URL(fileURLWithPath: "/Movies/second.mp4")
        let notice = NoticeComposer().composeScreenRecording(savedFiles: [first, second])
        #expect(notice.title == "2 screen recordings saved")
        #expect(notice.body == "first.mp4\nFolder: /Movies")
        #expect(NoticeComposer().composeScreenRecording(savedFiles: [first]) == NoticeComposer().composeScreenRecording(savedFile: first))
        #expect(NoticeComposer().composeScreenRecording(savedFiles: []).body == "No usable video was saved.")
    }

    @Test(arguments: [0, 1, 2, 3]) func multipleRecorders(scenario: Int) async {
        let first = FakeScreenRecorder()
        let second = FakeScreenRecorder()
        first.savedFile = URL(fileURLWithPath: "/Movies/first.mp4")
        second.savedFile = URL(fileURLWithPath: "/Movies/second.mp4")
        let environment = ScreenEnvironment(recorders: [first, second])
        // Duplicate names must still get distinct destinations before either file exists.
        let duplicateName = scenario == 0 ? "MAIN" : "Main"
        let duplicate = DisplayInfo(uuid: ScreenEnvironment.other.uuid, name: duplicateName, pixelWidth: 100, pixelHeight: 100, isMain: false)
        environment.displays = [duplicate, ScreenEnvironment.main]
        let dependencies = ScreenDependencies()
        let controller = ScreenRecordingController(factory: environment, displays: environment, picker: environment,
            permission: dependencies, disk: dependencies, files: dependencies,
            scheduler: FakeKeepAwakeScheduler(), notices: dependencies)
        if scenario == 1 { second.startFailure = .captureFailed; second.savedFile = nil }
        controller.toggle(settings: AppSettings(), target: .allDisplays)
        for _ in 0..<80 { await Task.yield() }
        #expect(first.starts == 1 && second.starts == 1)
        #expect(first.display == ScreenEnvironment.main)
        #expect(second.display == duplicate)
        #expect(first.destination != second.destination)
        #expect(second.destination?.lastPathComponent.hasSuffix(" - " + duplicateName + " 2.mp4") == true)
        if scenario == 1 {
            #expect(controller.state == .error)
            #expect(first.stops == 1 && second.stops == 1)
            #expect(controller.lastSavedFiles == [first.savedFile!])
            return
        }
        #expect(controller.state == .recording)
        if scenario >= 2 {
            first.onFailure?(.captureFailed)
            for _ in 0..<80 { await Task.yield() }
            #expect(controller.state == .recording)
            #expect(first.stops == 1)
            #expect(second.stops == 0)
            #expect(dependencies.notices.isEmpty)
            if scenario == 3 {
                second.onFailure?(nil)
                for _ in 0..<80 { await Task.yield() }
                #expect(controller.state == .error)
            }
        }
        let saved = await controller.stopAndWait()
        #expect(saved == [first.savedFile!, second.savedFile!])
        #expect(first.stops == 1 && second.stops == 1)
        #expect(dependencies.notices.first?.title == "2 screen recordings saved")
        if scenario >= 2 { #expect(dependencies.notices.first?.body.contains("Sharing ended early: Main") == true) }
    }

    @Test func fallbackAndNoDisplay() async {
        let f = ScreenFixture()
        f.controller.toggle(settings: AppSettings(), target: .display(uuid: ScreenEnvironment.other.uuid))
        await f.settle()
        #expect(f.recorder.display == ScreenEnvironment.main)
        #expect(f.controller.lastNotice?.contains("not connected") == true)
        await f.controller.stopAndWait()
        f.environment.displays = []
        await f.start()
        #expect(f.controller.lastError == ScreenRecordingFailure.noDisplay.message)
        #expect(f.recorder.starts == 1)
    }

    @Test(arguments: [0, 1, 2, 3, 4]) func pickerPaths(scenario: Int) async {
        let f = ScreenFixture()
        if scenario == 1 { f.environment.content = FakeRecordingContent() }
        if scenario == 2 { f.environment.isSupported = false }
        if scenario == 3 { f.environment.pickerFailure = .captureFailed }
        if scenario == 4 { f.environment.holdPicker = true }
        var settings = AppSettings()
        settings.screenRecordingTarget = .askEachTime
        f.controller.toggle(settings: settings)
        await f.settle()
        switch scenario {
        case 0:
            #expect(f.controller.state == .idle)
            #expect(f.recorder.starts == 0)
            #expect(f.dependencies.notices.isEmpty)
            #expect(f.dependencies.folders.isEmpty)
            #expect(f.controller.lastError == nil)
        case 1:
            #expect(f.recorder.content != nil)
            #expect(f.recorder.display == nil)
            #expect(f.controller.state == .recording)
        case 2:
            #expect(f.environment.pickerCalls == 0)
            #expect(f.recorder.display == ScreenEnvironment.main)
            #expect(f.controller.lastNotice?.contains("macOS 14") == true)
        case 3:
            #expect(f.controller.state == .error)
        default:
            #expect(f.controller.state == .starting)
        }
        await f.controller.stopAndWait()
        if scenario == 4 {
            #expect(f.recorder.starts == 0)
            #expect(f.controller.state == .idle)
        }
    }

    @Test(arguments: [0, 1, 2]) func streamsDuringStartup(scenario: Int) async {
        let first = FakeScreenRecorder()
        let second = FakeScreenRecorder()
        first.holdStart = true
        second.holdStart = true
        let environment = ScreenEnvironment(recorders: [first, second])
        environment.displays = [ScreenEnvironment.main, ScreenEnvironment.other]
        let dependencies = ScreenDependencies()
        let controller = ScreenRecordingController(factory: environment, displays: environment, picker: environment,
            permission: dependencies, disk: dependencies, files: dependencies,
            scheduler: FakeKeepAwakeScheduler(), notices: dependencies)
        controller.toggle(settings: AppSettings(), target: .allDisplays)
        for _ in 0..<60 { await Task.yield() }
        #expect(first.starts == 1 && second.starts == 1)
        #expect(controller.state == .starting)
        if scenario == 2 {
            first.startContinuation?.resume()
            for _ in 0..<60 { await Task.yield() }
            second.startFailure = .captureFailed
            second.startContinuation?.resume()
        } else {
            first.onFailure?(nil)
            if scenario == 1 {
                second.onFailure?(nil)
                first.savedFile = nil
                second.savedFile = nil
            }
            first.startContinuation?.resume()
            second.startContinuation?.resume()
        }
        for _ in 0..<80 { await Task.yield() }
        if scenario == 0 {
            #expect(controller.state == .recording)
            #expect(first.stops == 1 && second.stops == 0)
        } else if scenario == 1 {
            #expect(controller.state == .idle)
            #expect(dependencies.notices.first?.title == "Screen recording ended")
            #expect(dependencies.notices.first?.body.contains("Main, Other") == true)
        } else { #expect(controller.state == .error) }
        await controller.stopAndWait()
        #expect(first.stops == 1 && second.stops == 1)
    }

    @Test func stopBeforePickerTaskRuns() async {
        let f = ScreenFixture()
        f.controller.toggle(settings: AppSettings(), target: .askEachTime)
        await f.controller.stopAndWait()
        #expect(f.environment.pickerCalls == 0)
        #expect(f.recorder.starts == 0)
        #expect(f.controller.state == .idle)
    }

}
