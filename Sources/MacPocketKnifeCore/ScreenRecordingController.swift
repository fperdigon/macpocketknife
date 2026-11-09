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

@MainActor
public final class ScreenRecordingController {
    public enum State: Equatable { case idle, starting, recording, stopping, error }
    public private(set) var state: State = .idle
    public private(set) var lastError: String?
    public private(set) var elapsedSeconds = 0
    public private(set) var lastSavedFile: URL?
    public var onChange: (@MainActor () -> Void)?
    private let recorder: any ScreenRecording
    private let permission: any ScreenRecordingPermissionProviding
    private let disk: any FreeDiskSpaceProviding
    private let files: any RecordingFileManaging
    private let scheduler: any KeepAwakeScheduling
    private let notices: any AlertNotifying
    private var operation: Task<Void, Never>?
    private var cancelTick: (@Sendable () -> Void)?
    private var startedAt: Date?
    private var folder: URL?
    private var stopRequested = false
    private var pendingFailure: ScreenRecordingFailure?

    public var elapsedTitle: String {
        String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }

    public static func make(
        recorder: any ScreenRecording, permission: any ScreenRecordingPermissionProviding,
        disk: any FreeDiskSpaceProviding, files: any RecordingFileManaging, notices: any AlertNotifying
    ) -> ScreenRecordingController {
        ScreenRecordingController(recorder: recorder, permission: permission, disk: disk,
                                  files: files, scheduler: KeepAwakeScheduler(), notices: notices)
    }

    public init(recorder: any ScreenRecording, permission: any ScreenRecordingPermissionProviding,
                disk: any FreeDiskSpaceProviding, files: any RecordingFileManaging,
                scheduler: any KeepAwakeScheduling, notices: any AlertNotifying) {
        self.recorder = recorder
        self.permission = permission
        self.disk = disk
        self.files = files
        self.scheduler = scheduler
        self.notices = notices
    }

    public func toggle(settings: AppSettings) {
        switch state {
        case .starting:
            stopRequested = true
            state = .stopping
            onChange?()
        case .recording: finish(failure: nil)
        case .stopping: break
        case .idle, .error: start(settings: settings.validated())
        }
    }

    public func stopAndWait() async {
        if state == .starting {
            stopRequested = true
            state = .stopping
            onChange?()
        } else if state == .recording {
            finish(failure: nil)
        }
        await operation?.value
    }

    public func showRecordings(folderPath: String) {
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        do {
            try files.createFolder(folder)
            files.revealFolder(folder)
        } catch { report(.folderUnavailable) }
    }

    private func start(settings: AppSettings) {
        lastError = nil
        lastSavedFile = nil
        elapsedSeconds = 0
        stopRequested = false
        pendingFailure = nil
        guard permission.requestAccessIfNeeded() else { report(.permissionDenied); return }
        let folder = URL(fileURLWithPath: settings.screenRecordingFolder, isDirectory: true)
        let destination: URL
        do {
            try files.createFolder(folder)
            guard try disk.availableBytes(at: folder) >= 1_000_000_000 else { report(.lowDiskSpace); return }
            destination = ScreenRecordingFiles.destination(date: scheduler.now, folder: folder, exists: files.exists)
        } catch { report(.folderUnavailable); return }
        self.folder = folder
        state = .starting
        recorder.onFailure = { [weak self] failure in
            guard let self else { return }
            if self.state == .starting || self.state == .stopping {
                self.stopRequested = true
                self.pendingFailure = failure
            } else if self.state == .recording {
                self.finish(failure: failure)
            }
        }
        let configuration = ScreenRecordingConfiguration(
            frameRate: settings.screenRecordingFrameRate, showsCursor: settings.screenRecordingShowsCursor,
            includesMicrophone: settings.screenRecordingIncludesMicrophone
        )
        onChange?()
        operation = Task { [self] in
            do {
                try await recorder.start(configuration: configuration, destination: destination)
                if stopRequested { await finalize(failure: pendingFailure); return }
                startedAt = scheduler.now
                state = .recording
                tick()
                onChange?()
            } catch {
                await finalize(failure: (error as? ScreenRecordingFailure) ?? .captureFailed)
            }
        }
    }

    private func tick() {
        cancelTick = scheduler.schedule(at: scheduler.now.addingTimeInterval(1)) { [weak self] in
            guard let self, self.state == .recording, let startedAt = self.startedAt else { return }
            self.elapsedSeconds = max(0, Int(self.scheduler.now.timeIntervalSince(startedAt)))
            if let folder = self.folder {
                do {
                    if try self.disk.availableBytes(at: folder) < 10_000_000 {
                        self.finish(failure: .writingFailed)
                        return
                    }
                } catch {
                    self.finish(failure: .writingFailed)
                    return
                }
            }
            self.onChange?()
            self.tick()
        }
    }

    private func finish(failure: ScreenRecordingFailure?) {
        state = .stopping
        cancelTick?()
        cancelTick = nil
        onChange?()
        operation = Task { [self] in await finalize(failure: failure) }
    }

    private func finalize(failure: ScreenRecordingFailure?) async {
        state = .stopping
        recorder.onFailure = nil
        cancelTick?()
        cancelTick = nil
        var finalFailure = failure
        do {
            if let url = try await recorder.stop() {
                lastSavedFile = url
                await notices.deliver(NoticeComposer().composeScreenRecording(savedFile: url))
            }
        } catch { finalFailure = (error as? ScreenRecordingFailure) ?? .writingFailed }
        startedAt = nil
        state = .idle
        if let finalFailure { report(finalFailure) } else { onChange?() }
    }

    private func report(_ failure: ScreenRecordingFailure) {
        if state == .idle || state == .error { state = .error }
        lastError = failure.message
        onChange?()
        let notice = NoticeComposer().composeScreenRecording(failure: failure)
        Task { await notices.deliver(notice) }
    }
}
