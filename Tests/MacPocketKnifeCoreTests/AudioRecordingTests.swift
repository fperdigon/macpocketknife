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
import MacPocketKnifeCore
import Testing

@MainActor
private final class AudioEnvironment: AudioRecording, AudioRecordingFactory, FreeDiskSpaceProviding,
    RecordingFileManaging, AlertNotifying, ScreenRecording, ScreenRecordingFactory,
    ScreenRecordingDisplayProviding, ScreenRecordingPicking, ScreenRecordingPermissionProviding {
    var onFailure: (@MainActor (ScreenRecordingFailure?) -> Void)?
    var configuration: AudioRecordingConfiguration?
    var destination: URL?
    var outcome: RecordingMicrophoneOutcome = .included
    var startError: (any Error)?
    var stopError: (any Error)?
    var bytes: Int64 = 2_000_000_000
    var folderFails = false
    var diskFails = false
    var collisions = 0
    var starts = 0
    var stops = 0
    var notices: [Notice] = []
    var savedFile: URL? = URL(fileURLWithPath: "/Movies/Audio example.m4a")
    var holdStart = false
    var holdStop = false
    var startContinuation: CheckedContinuation<Void, Never>?
    var stopContinuation: CheckedContinuation<Void, Never>?
    func makeAudioRecorder() -> any AudioRecording { self }
    func start(configuration: AudioRecordingConfiguration, destination: URL) async throws -> RecordingMicrophoneOutcome {
        starts += 1
        self.configuration = configuration
        self.destination = destination
        if holdStart { await withCheckedContinuation { startContinuation = $0 } }
        if let startError { throw startError }
        return outcome
    }
    func stop() async throws -> URL? {
        stops += 1
        if holdStop { await withCheckedContinuation { stopContinuation = $0 } }
        if let stopError { throw stopError }
        return savedFile
    }
    func availableBytes(at folder: URL) throws -> Int64 {
        if diskFails { throw ScreenRecordingFailure.writingFailed }
        return bytes
    }
    func createFolder(_ folder: URL) throws {
        if folderFails { throw ScreenRecordingFailure.folderUnavailable }
    }
    func exists(_ file: URL) -> Bool {
        if collisions > 0 { collisions -= 1; return true }
        return false
    }
    func revealFolder(_ folder: URL) {}
    func deliver(_ notice: Notice) async { notices.append(notice) }
    func makeRecorder() -> any ScreenRecording { self }
    func start(configuration: ScreenRecordingConfiguration, destination: URL, display: DisplayInfo?,
               content: (any ScreenRecordingContent)?) async throws -> RecordingMicrophoneOutcome {
        starts += 1
        return .disabled
    }
    func connectedDisplays() -> [DisplayInfo] {
        [DisplayInfo(uuid: "11111111-1111-1111-1111-111111111111", name: "Main", pixelWidth: 100, pixelHeight: 100, isMain: true)]
    }
    var isSupported: Bool { false }
    func chooseContent() async throws -> (any ScreenRecordingContent)? { nil }
    func cancel() {}
    func requestAccessIfNeeded() -> Bool { true }
}

@MainActor
private struct AudioFixture {
    let environment = AudioEnvironment()
    let scheduler = FakeKeepAwakeScheduler()
    let gate = RecordingSessionGate()
    let controller: AudioRecordingController
    init() {
        controller = AudioRecordingController(factory: environment, disk: environment, files: environment,
            scheduler: scheduler, notices: environment, gate: gate)
    }
    func settle() async { for _ in 0..<80 { await Task.yield() } }
    func start(settings: AppSettings = AppSettings()) async {
        controller.toggle(settings: settings)
        await settle()
    }
    func video() -> ScreenRecordingController {
        ScreenRecordingController(factory: environment, displays: environment, picker: environment,
            permission: environment, disk: environment, files: environment, scheduler: scheduler,
            notices: environment, gate: gate)
    }
}

@MainActor
struct AudioRecordingTests {
    @Test func settingsMigrationAndRoundTrip() throws {
        let current = try JSONEncoder().encode(AppSettings())
        var object = try #require(JSONSerialization.jsonObject(with: current) as? [String: Any])
        object.removeValue(forKey: "audioRecordingMicrophone")
        object.removeValue(forKey: "audioRecordingSystemAudio")
        let oldData = try JSONSerialization.data(withJSONObject: object)
        let old = try JSONDecoder().decode(AppSettings.self, from: oldData)
        #expect(old.audioRecordingMicrophone && old.audioRecordingSystemAudio)
        for mic in [false, true] {
            for system in [false, true] {
                var settings = old
                settings.audioRecordingMicrophone = mic
                settings.audioRecordingSystemAudio = system
                let data = try JSONEncoder().encode(settings)
                #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)
                let config = AudioRecordingConfiguration(microphone: mic, systemAudio: system)
                #expect(config.microphone == mic && config.systemAudio == system)
                if mic || system { try config.validate() }
                else { #expect(throws: ScreenRecordingFailure.noAudioSources) { try config.validate() } }
            }
        }
    }

    @Test func audioNamesAndNotice() {
        let date = Date(timeIntervalSince1970: 0)
        let zone = TimeZone(secondsFromGMT: 0)!
        #expect(ScreenRecordingFiles.name(date: date, timeZone: zone, audioOnly: true) == "Audio 1970-01-01 00.00.00.m4a")
        #expect(ScreenRecordingFiles.name(date: date, timeZone: zone, collision: 2, audioOnly: true) == "Audio 1970-01-01 00.00.00 2.m4a")
        let file = URL(fileURLWithPath: "/Movies/Audio example.m4a")
        let notice = NoticeComposer().composeAudioRecording(savedFile: file, notice: "Microphone unavailable.")
        #expect(notice.title == "Audio recording saved")
        #expect(notice.recordingFile == file)
        #expect(notice.body.hasSuffix("Microphone unavailable."))
    }

    @Test func happyPathElapsedAndRepeatStop() async {
        let f = AudioFixture()
        var changes = 0
        f.controller.onChange = { changes += 1 }
        f.environment.collisions = 2
        var settings = AppSettings()
        settings.audioRecordingMicrophone = false
        await f.start(settings: settings)
        #expect(f.controller.state == .recording)
        #expect(f.environment.configuration == AudioRecordingConfiguration(microphone: false, systemAudio: true))
        #expect(f.environment.destination?.lastPathComponent.hasSuffix(" 3.m4a") == true)
        f.scheduler.advance(by: 65)
        #expect(f.controller.elapsedTitle == "01:05")
        f.environment.holdStop = true
        f.controller.toggle(settings: settings)
        f.controller.toggle(settings: settings)
        await f.settle()
        #expect(f.controller.state == .stopping)
        f.environment.stopContinuation?.resume()
        #expect(await f.controller.stopAndWait() == f.environment.savedFile)
        #expect(await f.controller.stopAndWait() == f.environment.savedFile)
        #expect(f.environment.stops == 1)
        #expect(f.controller.state == .idle)
        #expect(f.scheduler.pendingCount == 0)
        #expect(changes >= 4)
        #expect(f.environment.notices.first?.recordingFile == f.environment.savedFile)
        #expect(f.gate.acquire() != nil)
    }

    @Test(arguments: [RecordingMicrophoneOutcome.denied, .unsupported, .unavailable, .included, .disabled])
    func microphoneFallback(_ outcome: RecordingMicrophoneOutcome) async {
        let f = AudioFixture()
        f.environment.outcome = outcome
        await f.start()
        #expect(f.controller.lastNotice == outcome.notice)
        #expect(f.controller.state == .recording)
        await f.controller.stopAndWait()
        if let notice = outcome.notice { #expect(f.environment.notices.first?.body.contains(notice) == true) }
        f.environment.outcome = .included
        await f.start()
        #expect(f.controller.lastNotice == nil)
        await f.controller.stopAndWait()
    }

    @Test(arguments: [0, 1, 2, 3, 4, 5, 6]) func startFailures(_ scenario: Int) async {
        let f = AudioFixture()
        var settings = AppSettings()
        switch scenario {
        case 0: settings.audioRecordingMicrophone = false; settings.audioRecordingSystemAudio = false
        case 1: f.environment.folderFails = true
        case 2: f.environment.bytes = 999_999_999
        case 3: f.environment.diskFails = true
        case 4: f.environment.startError = ScreenRecordingFailure.permissionDenied
        case 5: f.environment.startError = CocoaError(.fileReadUnknown)
        default: f.environment.startError = ScreenRecordingFailure.microphoneUnavailable
        }
        await f.start(settings: settings)
        #expect(f.controller.state == .error)
        #expect(f.controller.lastError != nil)
        #expect(f.controller.screenPermissionDenied == (scenario == 4))
        if scenario == 0 { #expect(f.environment.starts == 0) }
        #expect(f.gate.acquire() != nil)
        #expect(f.environment.notices.last?.title == "Audio recording unavailable")
    }

    @Test(arguments: [false, true]) func stopFailure(_ typed: Bool) async {
        let f = AudioFixture()
        await f.start()
        f.environment.stopError = typed ? ScreenRecordingFailure.writingFailed : CocoaError(.fileWriteUnknown)
        #expect(await f.controller.stopAndWait() == nil)
        #expect(f.controller.state == .error)
        #expect(f.controller.lastError == ScreenRecordingFailure.writingFailed.message)
        #expect(f.gate.acquire() != nil)
    }

    @Test(arguments: [false, true]) func diskBecomesUnavailable(_ throwsError: Bool) async {
        let f = AudioFixture()
        await f.start()
        f.environment.bytes = 0
        f.environment.diskFails = throwsError
        f.scheduler.advance(by: 1)
        await f.controller.stopAndWait()
        #expect(f.controller.state == .error)
        #expect(f.environment.stops == 1)
        #expect(f.controller.lastSavedFile != nil)
    }

    @Test(arguments: [false, true]) func streamEnds(_ failure: Bool) async {
        let f = AudioFixture()
        await f.start()
        f.environment.onFailure?(failure ? .captureFailed : nil)
        await f.controller.stopAndWait()
        #expect(f.controller.state == (failure ? .error : .idle))
        #expect(f.environment.stops == 1)
    }

    @Test(arguments: [0, 1, 2, 3]) func cancellationDuringStart(_ scenario: Int) async {
        let f = AudioFixture()
        if scenario == 0 {
            f.controller.toggle(settings: AppSettings())
            await f.controller.stopAndWait()
            #expect(f.environment.starts == 0)
            #expect(f.controller.state == .idle)
            return
        }
        f.environment.holdStart = true
        await f.start()
        #expect(f.controller.state == .starting)
        if scenario == 1 { f.controller.toggle(settings: AppSettings()) }
        else { f.environment.onFailure?(scenario == 2 ? nil : .captureFailed) }
        f.environment.startContinuation?.resume()
        await f.controller.stopAndWait()
        #expect(f.environment.stops == 1)
        #expect(f.controller.state == (scenario == 3 ? .error : .idle))
        #expect(f.gate.acquire() != nil)
    }

    @Test func noUsableAudioAndPermissionRecovery() async {
        let f = AudioFixture()
        f.environment.startError = ScreenRecordingFailure.permissionDenied
        f.environment.savedFile = nil
        await f.start()
        #expect(f.controller.screenPermissionDenied)
        f.environment.startError = nil
        await f.start()
        #expect(!f.controller.screenPermissionDenied)
        #expect(f.controller.lastError == nil)
        #expect(await f.controller.stopAndWait() == nil)
        #expect(f.controller.state == .idle)
    }

    @Test(arguments: [false, true]) func mutuallyExclusiveControllers(_ audioFirst: Bool) async {
        let f = AudioFixture()
        let video = f.video()
        if audioFirst {
            await f.start()
            video.toggle(settings: AppSettings())
            #expect(video.state == .error)
            #expect(video.lastError == ScreenRecordingFailure.recordingBusy.message)
            await f.controller.stopAndWait()
            video.toggle(settings: AppSettings())
            await f.settle()
            #expect(video.state == .recording)
            await video.stopAndWait()
        } else {
            video.toggle(settings: AppSettings())
            await f.start()
            #expect(f.controller.state == .error)
            #expect(f.controller.lastError == ScreenRecordingFailure.recordingBusy.message)
            await video.stopAndWait()
            await f.start()
            #expect(f.controller.state == .recording)
            await f.controller.stopAndWait()
        }
        #expect(f.gate.acquire() != nil)
    }

    @Test func exclusionDuringStartupAndFinalization() async {
        let f = AudioFixture()
        let video = f.video()
        f.environment.holdStart = true
        await f.start()
        video.toggle(settings: AppSettings())
        #expect(video.lastError == ScreenRecordingFailure.recordingBusy.message)
        f.environment.startContinuation?.resume()
        await f.settle()
        f.environment.holdStop = true
        f.controller.toggle(settings: AppSettings())
        await f.settle()
        video.toggle(settings: AppSettings())
        #expect(video.lastError == ScreenRecordingFailure.recordingBusy.message)
        #expect(f.environment.starts == 1)
        f.environment.stopContinuation?.resume()
        await f.controller.stopAndWait()
        #expect(f.gate.acquire() != nil)
    }

    @Test func gateRejectsStaleRelease() throws {
        let gate = RecordingSessionGate()
        let first = try #require(gate.acquire())
        #expect(gate.acquire() == nil)
        gate.release(UUID())
        #expect(gate.acquire() == nil)
        gate.release(first)
        #expect(gate.acquire() != nil)
    }
}
