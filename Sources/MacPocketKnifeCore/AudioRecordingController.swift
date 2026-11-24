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

@MainActor
public final class AudioRecordingController {
    public enum State: Equatable { case idle, starting, recording, stopping, error }
    public private(set) var state: State = .idle
    public private(set) var lastError: String?
    public private(set) var lastNotice: String?
    public private(set) var lastSavedFile: URL?
    public private(set) var screenPermissionDenied = false
    public private(set) var elapsedSeconds = 0
    public var onChange: (@MainActor () -> Void)?
    public var elapsedTitle: String { String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60) }
    private let factory: any AudioRecordingFactory
    private let disk: any FreeDiskSpaceProviding
    private let files: any RecordingFileManaging
    private let scheduler: any KeepAwakeScheduling
    private let notices: any AlertNotifying
    private let gate: RecordingSessionGate
    private var token: UUID?
    private var recorder: (any AudioRecording)?
    private var operation: Task<Void, Never>?
    private var cancelTick: (@Sendable () -> Void)?
    private var startedAt: Date?
    private var folder: URL?
    private var stopRequested = false
    private var pendingFailure: ScreenRecordingFailure?

    public init(factory: any AudioRecordingFactory, disk: any FreeDiskSpaceProviding,
                files: any RecordingFileManaging, scheduler: any KeepAwakeScheduling,
                notices: any AlertNotifying, gate: RecordingSessionGate) {
        self.factory = factory
        self.disk = disk
        self.files = files
        self.scheduler = scheduler
        self.notices = notices
        self.gate = gate
    }

    public func toggle(settings: AppSettings) {
        switch state {
        case .starting:
            stopRequested = true
            state = .stopping
            onChange?()
        case .recording: finish()
        case .stopping: break
        case .idle, .error: start(settings: settings.validated())
        }
    }

    @discardableResult public func stopAndWait() async -> URL? {
        if state == .starting {
            stopRequested = true
            state = .stopping
            onChange?()
        } else if state == .recording { finish() }
        await operation?.value
        return lastSavedFile
    }

    private func start(settings: AppSettings) {
        guard let token = gate.acquire() else { report(.recordingBusy); return }
        self.token = token
        lastError = nil
        lastNotice = nil
        lastSavedFile = nil
        elapsedSeconds = 0
        stopRequested = false
        pendingFailure = nil
        state = .starting
        AppLog.shared.info(category: "recording", "Audio start requested")
        onChange?()
        operation = Task { [self] in
            do {
                let configuration = AudioRecordingConfiguration(microphone: settings.audioRecordingMicrophone,
                    systemAudio: settings.audioRecordingSystemAudio)
                try configuration.validate()
                if !stopRequested {
                    let folder = URL(fileURLWithPath: settings.screenRecordingFolder, isDirectory: true)
                    do { try files.createFolder(folder) }
                    catch { throw ScreenRecordingFailure.folderUnavailable }
                    guard try disk.availableBytes(at: folder) >= 1_000_000_000 else {
                        throw ScreenRecordingFailure.lowDiskSpace
                    }
                    self.folder = folder
                    let destination = ScreenRecordingFiles.destination(date: scheduler.now, folder: folder, audioOnly: true) {
                        self.files.exists($0)
                    }
                    let recorder = factory.makeAudioRecorder()
                    self.recorder = recorder
                    recorder.onFailure = { [weak self] failure in
                        guard let self, self.state == .starting || self.state == .recording else { return }
                        if let failure { self.pendingFailure = failure }
                        if self.state == .starting { self.stopRequested = true }
                        else if self.state == .recording { self.finish() }
                    }
                    let outcome = try await recorder.start(configuration: configuration, destination: destination)
                    lastNotice = outcome.notice
                    screenPermissionDenied = false
                    if !stopRequested {
                        startedAt = scheduler.now
                        state = .recording
                        AppLog.shared.info(category: "recording", "Audio started microphone=\(outcome)")
                        tick()
                        onChange?()
                        return
                    }
                }
                await finalize()
            } catch {
                pendingFailure = (error as? ScreenRecordingFailure) ?? .captureFailed
                await finalize()
            }
        }
    }

    private func tick() {
        cancelTick = scheduler.schedule(at: scheduler.now.addingTimeInterval(1)) { [weak self] in
            guard let self, self.state == .recording, let startedAt = self.startedAt else { return }
            self.elapsedSeconds = max(0, Int(self.scheduler.now.timeIntervalSince(startedAt)))
            do {
                if let folder = self.folder, try self.disk.availableBytes(at: folder) < 10_000_000 {
                    throw ScreenRecordingFailure.writingFailed
                }
            } catch {
                self.pendingFailure = .writingFailed
                self.finish()
                return
            }
            self.onChange?()
            self.tick()
        }
    }

    private func finish() {
        state = .stopping
        cancelTick?()
        cancelTick = nil
        onChange?()
        operation = Task { [self] in await finalize() }
    }

    private func finalize() async {
        state = .stopping
        cancelTick?()
        cancelTick = nil
        recorder?.onFailure = nil
        do { lastSavedFile = try await recorder?.stop() }
        catch { pendingFailure = (error as? ScreenRecordingFailure) ?? .writingFailed }
        recorder = nil
        if let lastSavedFile {
            await notices.deliver(NoticeComposer().composeAudioRecording(savedFile: lastSavedFile, notice: lastNotice))
        }
        let duration = startedAt.map { max(0, Int(scheduler.now.timeIntervalSince($0))) } ?? 0
        AppLog.shared.info(category: "recording", "Audio stopped durationSeconds=\(duration) fileCount=\(lastSavedFile == nil ? 0 : 1)")
        startedAt = nil
        if let token { gate.release(token) }
        token = nil
        state = .idle
        if let pendingFailure { report(pendingFailure) }
        else { onChange?() }
    }

    private func report(_ failure: ScreenRecordingFailure) {
        state = .error
        if failure == .permissionDenied { screenPermissionDenied = true }
        let message: String
        switch failure {
        case .lowDiskSpace: message = "Audio recording requires at least 1 GB of free space on the save volume."
        case .captureFailed: message = "Audio capture stopped unexpectedly. Any usable recording has been finalized."
        default: message = failure.message
        }
        lastError = message
        AppLog.shared.error(category: "recording", "Audio failed code=\(failure)")
        onChange?()
        Task { await notices.deliver(Notice(kind: .info, title: "Audio recording unavailable", body: message)) }
    }
}
