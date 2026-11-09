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
    func start(configuration: ScreenRecordingConfiguration, destination: URL) async throws {
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
private struct ScreenFixture {
    let recorder = FakeScreenRecorder()
    let dependencies = ScreenDependencies()
    let scheduler = FakeKeepAwakeScheduler()
    let controller: ScreenRecordingController
    init() {
        controller = ScreenRecordingController(recorder: recorder, permission: dependencies,
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
        let controller = ScreenRecordingController.make(recorder: recorder, permission: dependencies,
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
}
