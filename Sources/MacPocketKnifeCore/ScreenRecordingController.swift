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
    public private(set) var lastNotice: String?
    public private(set) var elapsedSeconds = 0
    public private(set) var lastSavedFiles: [URL] = []
    public var lastSavedFile: URL? { lastSavedFiles.first }
    public var onChange: (@MainActor () -> Void)?

    @MainActor
    private final class Session {
        let recorder: any ScreenRecording
        let display: DisplayInfo?
        var ended = false
        var didStart = false
        var stopTask: Task<URL?, Error>?
        init(recorder: any ScreenRecording, display: DisplayInfo?) {
            self.recorder = recorder
            self.display = display
        }
        func stop() -> Task<URL?, Error> {
            if let stopTask { return stopTask }
            recorder.onFailure = nil
            let task: Task<URL?, Error> = Task { try await recorder.stop() }
            stopTask = task
            return task
        }
    }
    private let factory: any ScreenRecordingFactory
    private let displays: any ScreenRecordingDisplayProviding
    private let picker: any ScreenRecordingPicking
    private let permission: any ScreenRecordingPermissionProviding
    private let disk: any FreeDiskSpaceProviding
    private let files: any RecordingFileManaging
    private let scheduler: any KeepAwakeScheduling
    private let notices: any AlertNotifying
    private var sessions: [Session] = []
    private var interruptedDisplays: [String] = []
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
        factory: any ScreenRecordingFactory, displays: any ScreenRecordingDisplayProviding,
        picker: any ScreenRecordingPicking, permission: any ScreenRecordingPermissionProviding,
        disk: any FreeDiskSpaceProviding, files: any RecordingFileManaging, notices: any AlertNotifying
    ) -> ScreenRecordingController {
        ScreenRecordingController(factory: factory, displays: displays, picker: picker,
                                  permission: permission, disk: disk, files: files,
                                  scheduler: KeepAwakeScheduler(), notices: notices)
    }

    public init(factory: any ScreenRecordingFactory, displays: any ScreenRecordingDisplayProviding,
                picker: any ScreenRecordingPicking, permission: any ScreenRecordingPermissionProviding,
                disk: any FreeDiskSpaceProviding, files: any RecordingFileManaging,
                scheduler: any KeepAwakeScheduling, notices: any AlertNotifying) {
        self.factory = factory
        self.displays = displays
        self.picker = picker
        self.permission = permission
        self.disk = disk
        self.files = files
        self.scheduler = scheduler
        self.notices = notices
    }

    public func toggle(settings: AppSettings, target: ScreenRecordingTarget? = nil) {
        switch state {
        case .starting:
            stopRequested = true
            picker.cancel()
            state = .stopping
            onChange?()
        case .recording: finish(failure: nil)
        case .stopping: break
        case .idle, .error: start(settings: settings.validated(), target: target)
        }
    }

    @discardableResult
    public func stopAndWait() async -> [URL] {
        if state == .starting {
            stopRequested = true
            picker.cancel()
            state = .stopping
            onChange?()
        } else if state == .recording {
            finish(failure: nil)
        }
        await operation?.value
        return lastSavedFiles
    }

    public func showRecordings(folderPath: String) {
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        do {
            try files.createFolder(folder)
            files.revealFolder(folder)
        } catch { report(.folderUnavailable) }
    }

    private func start(settings: AppSettings, target: ScreenRecordingTarget?) {
        lastError = nil
        lastNotice = nil
        lastSavedFiles = []
        sessions = []
        interruptedDisplays = []
        elapsedSeconds = 0
        stopRequested = false
        pendingFailure = nil
        state = .starting
        onChange?()
        operation = Task { [self] in
            do {
                guard !stopRequested else {
                    state = .idle
                    onChange?()
                    return
                }
                var requested = target ?? settings.screenRecordingTarget
                var content: (any ScreenRecordingContent)?
                if requested == .askEachTime {
                    if picker.isSupported {
                        content = try await picker.chooseContent()
                        guard content != nil, !stopRequested else {
                            state = .idle
                            onChange?()
                            return
                        }
                    } else {
                        requested = .mainDisplay
                        lastNotice = "Choosing with preview requires macOS 14. The main display is used meanwhile."
                    }
                }
                var selected: [DisplayInfo?] = [nil]
                if content == nil {
                    guard let resolution = try ScreenRecordingTargets.resolve(requested, displays: displays.connectedDisplays()) else {
                        state = .idle
                        onChange?()
                        return
                    }
                    selected = resolution.displays.map { Optional($0) }
                    if resolution.fellBack {
                        lastNotice = "The selected display is not connected. Recording the main display instead."
                    }
                }
                guard permission.requestAccessIfNeeded() else { throw ScreenRecordingFailure.permissionDenied }
                let folder = URL(fileURLWithPath: settings.screenRecordingFolder, isDirectory: true)
                do {
                    try files.createFolder(folder)
                    guard try disk.availableBytes(at: folder) >= 1_000_000_000 else {
                        throw ScreenRecordingFailure.lowDiskSpace
                    }
                } catch let failure as ScreenRecordingFailure where failure == .lowDiskSpace {
                    throw failure
                } catch { throw ScreenRecordingFailure.folderUnavailable }
                self.folder = folder
                let configuration = ScreenRecordingConfiguration(
                    frameRate: settings.screenRecordingFrameRate, showsCursor: settings.screenRecordingShowsCursor,
                    includesMicrophone: settings.screenRecordingIncludesMicrophone
                )
                var reserved: Set<String> = []
                var starts: [Task<Void, Error>] = []
                let date = scheduler.now
                let selectedContent: (any ScreenRecordingContent)? = content
                for display in selected {
                    let session = Session(recorder: factory.makeRecorder(), display: display)
                    sessions.append(session)
                    session.recorder.onFailure = { [weak self, weak session] failure in
                        guard let self, let session else { return }
                        self.streamEnded(session, failure: failure)
                    }
                    let name: String? = selected.count > 1 ? display?.name : nil
                    let destination = ScreenRecordingFiles.destination(date: date, folder: folder, displayName: name) {
                        reserved.contains($0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()) || self.files.exists($0)
                    }
                    reserved.insert(destination.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased())
                    let task: Task<Void, Error> = Task {
                        do {
                            try await session.recorder.start(configuration: configuration,
                                destination: destination, display: display, content: selectedContent)
                            session.didStart = true
                            if stopRequested { _ = session.stop() }
                        } catch {
                            stopRequested = true
                            state = .stopping
                            _ = session.stop()
                            for started in sessions where started.didStart { _ = started.stop() }
                            onChange?()
                            throw error
                        }
                    }
                    starts.append(task)
                }
                // Launch every stream before awaiting any of them; drain every start before finalizing.
                var startFailure: ScreenRecordingFailure?
                for task in starts {
                    do { try await task.value }
                    catch { startFailure = (error as? ScreenRecordingFailure) ?? .captureFailed }
                }
                if let startFailure { await finalize(failure: startFailure); return }
                if stopRequested || sessions.allSatisfy({ $0.ended }) {
                    await finalize(failure: pendingFailure)
                    return
                }
                for session in sessions where session.ended { _ = session.stop() }
                startedAt = scheduler.now
                state = .recording
                tick()
                onChange?()
            } catch {
                await finalize(failure: (error as? ScreenRecordingFailure) ?? .captureFailed)
            }
        }
    }

    private func streamEnded(_ session: Session, failure: ScreenRecordingFailure?) {
        guard !session.ended, state == .starting || state == .recording else { return }
        session.ended = true
        if sessions.count > 1 { interruptedDisplays.append(session.display?.name ?? "Selected content") }
        if let failure { pendingFailure = failure }
        if state == .recording {
            _ = session.stop()
            if sessions.allSatisfy({ $0.ended }) { finish(failure: pendingFailure) }
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
        cancelTick?()
        cancelTick = nil
        var finalFailure = failure ?? pendingFailure
        let stops = sessions.map { $0.stop() }
        for task in stops {
            do {
                if let url = try await task.value { lastSavedFiles.append(url) }
            } catch { finalFailure = (error as? ScreenRecordingFailure) ?? .writingFailed }
        }
        if !lastSavedFiles.isEmpty || !interruptedDisplays.isEmpty {
            let notice = NoticeComposer().composeScreenRecording(savedFiles: lastSavedFiles,
                                                                interruptedDisplays: interruptedDisplays)
            await notices.deliver(notice)
        }
        sessions = []
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
