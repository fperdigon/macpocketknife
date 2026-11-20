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

public enum DictationFailure: Error, Sendable, Equatable {
    case permissionDenied, onDeviceUnavailable, microphoneUnavailable, recognitionFailed

    public var message: String {
        switch self {
        case .permissionDenied:
            return "Allow microphone and speech recognition access in System Settings > Privacy & Security."
        case .onDeviceUnavailable:
            return "Enable offline dictation for this language in System Settings > Keyboard > Dictation, then try again."
        case .microphoneUnavailable:
            return "The default microphone is unavailable. Check your audio input in System Settings > Sound."
        case .recognitionFailed:
            return "Dictation stopped because audio or speech recognition failed. Please try again."
        }
    }
}

@MainActor
public protocol SpeechTranscribing: AnyObject {
    var onPartial: (@MainActor (String) -> Void)? { get set }
    var onError: (@MainActor (DictationFailure) -> Void)? { get set }
    func start(locale: Locale) async throws
    /// Stops capture and returns the most recent recognition result, without persisting it.
    func stop() -> String
    /// Ends audio input and waits for final recognition, with a bounded adapter timeout.
    func finish() async throws -> String
}

public extension SpeechTranscribing {
    func finish() async throws -> String { stop() }
}

@MainActor
public protocol PasteboardWriting {
    func write(_ text: String)
}

@MainActor
public final class DictationController {
    public enum State: Equatable { case idle, starting, recording, error }
    public private(set) var state: State = .idle
    public private(set) var lastError: String?
    public private(set) var wordCount = 0
    public var onChange: (@MainActor () -> Void)?
    private let speech: any SpeechTranscribing
    private let pasteboard: any PasteboardWriting
    private let scheduler: any KeepAwakeScheduling
    private let notices: any AlertNotifying
    private var startTask: Task<Void, Never>?
    private var cancelDeadline: (@Sendable () -> Void)?
    private var generation = 0
    private var isFinishing = false
    private var finishTask: Task<Void, Never>?
    private var startedAt: Date?

    public static func make(
        speech: any SpeechTranscribing, pasteboard: any PasteboardWriting,
        notices: any AlertNotifying
    ) -> DictationController {
        DictationController(speech: speech, pasteboard: pasteboard,
                            scheduler: KeepAwakeScheduler(), notices: notices)
    }

    public init(speech: any SpeechTranscribing, pasteboard: any PasteboardWriting,
                scheduler: any KeepAwakeScheduling, notices: any AlertNotifying) {
        self.speech = speech
        self.pasteboard = pasteboard
        self.scheduler = scheduler
        self.notices = notices
    }

    public func toggle(locale: Locale) {
        guard !isFinishing else { return }
        if state == .starting || state == .recording {
            finish(copy: state == .recording)
            return
        }
        generation += 1
        let session = generation
        state = .starting
        lastError = nil
        wordCount = 0
        speech.onPartial = { [weak self] text in
            guard let self, self.generation == session else { return }
            self.wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
            self.onChange?()
        }
        speech.onError = { [weak self] failure in
            guard let self, self.generation == session else { return }
            self.fail(failure)
        }
        onChange?()
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await speech.start(locale: locale)
                guard generation == session, !Task.isCancelled else { return }
                state = .recording
                startedAt = scheduler.now
                AppLog.shared.info(category: "dictation", "Started language=\(locale.languageCode ?? "default")")
                cancelDeadline = scheduler.schedule(at: scheduler.now.addingTimeInterval(600)) { [weak self] in
                    guard let self, self.generation == session else { return }
                    self.finish(copy: true)
                }
                onChange?()
            } catch {
                guard generation == session else { return }
                fail((error as? DictationFailure) ?? .recognitionFailed)
            }
        }
    }

    public func discard() { finish(copy: false) }

    private func finish(copy: Bool) {
        if copy {
            guard !isFinishing else { return }
            isFinishing = true
            cancelDeadline?()
            cancelDeadline = nil
            let session = generation
            finishTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let text = try await speech.finish()
                    guard generation == session, !Task.isCancelled else { return }
                    finish(copy: false)
                    copyTranscript(text)
                } catch {
                    guard generation == session else { return }
                    fail((error as? DictationFailure) ?? .recognitionFailed)
                }
            }
            return
        }
        if let startedAt {
            let duration = max(0, scheduler.now.timeIntervalSince(startedAt))
            AppLog.shared.info(category: "dictation", "Stopped durationSeconds=\(Int(duration)) wordCount=\(wordCount)")
            self.startedAt = nil
        }
        generation += 1
        isFinishing = false
        finishTask?.cancel()
        finishTask = nil
        startTask?.cancel()
        startTask = nil
        cancelDeadline?()
        cancelDeadline = nil
        speech.onPartial = nil
        speech.onError = nil
        _ = speech.stop()
        wordCount = 0
        state = .idle
        onChange?()
    }

    private func copyTranscript(_ transcript: String) {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { pasteboard.write(text) }
        let count = text.split(whereSeparator: { $0.isWhitespace }).count
        AppLog.shared.info(category: "dictation", "Finalized wordCount=\(count)")
        send(NoticeComposer().composeDictation(wordCount: count))
    }

    private func fail(_ failure: DictationFailure) {
        AppLog.shared.error(category: "dictation", "Failed code=\(failure)")
        if failure == .permissionDenied {
            AppLog.shared.warning(category: "permission", "Dictation access denied")
        }
        finish(copy: false)
        state = failure == .onDeviceUnavailable ? .idle : .error
        lastError = failure.message
        onChange?()
        send(NoticeComposer().composeDictation(failure: failure))
    }

    private func send(_ notice: Notice) {
        Task { await notices.deliver(notice) }
    }
}
