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

@preconcurrency import AVFoundation
@preconcurrency import Foundation
import MacPocketKnifeCore
@preconcurrency import Speech

/// Audio buffers are handed directly to Apple's thread-safe recognition request.
private final class AudioRequest: @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
}

@MainActor
final class AppleSpeechTranscriber: SpeechTranscribing {
    var onPartial: (@MainActor (String) -> Void)?
    var onError: (@MainActor (DictationFailure) -> Void)?
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var configurationObserver: NSObjectProtocol?
    private var text = ""
    private var generation = 0
    private var finalResult: CheckedContinuation<String, any Error>?
    private var finalDeadline: Task<Void, Never>?

    static var offlineLocales: [String] {
        var identifiers: [String] = []
        for locale in SFSpeechRecognizer.supportedLocales() {
            if SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true {
                identifiers.append(locale.identifier)
            }
        }
        return identifiers.sorted()
    }

    func start(locale: Locale) async throws {
        _ = stop()
        let session = generation
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw DictationFailure.onDeviceUnavailable
        }
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        try Task.checkCancellation()
        guard session == generation else { throw CancellationError() }
        guard authorization == .authorized else {
            AppLog.shared.warning(category: "permission", "Speech recognition denied")
            throw DictationFailure.permissionDenied
        }
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        try Task.checkCancellation()
        guard session == generation else { throw CancellationError() }
        guard microphone else {
            AppLog.shared.warning(category: "permission", "Microphone denied for dictation")
            throw DictationFailure.permissionDenied
        }
        guard recognizer.isAvailable else { throw DictationFailure.recognitionFailed }
        guard AVCaptureDevice.default(for: .audio) != nil else { throw DictationFailure.microphoneUnavailable }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DictationFailure.microphoneUnavailable
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        let audio = AudioRequest(request)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            audio.request.append(buffer)
        }
        self.engine = engine
        self.request = request
        self.recognizer = recognizer
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let failed = error != nil
            let final = result?.isFinal == true
            Task { @MainActor [weak self] in
                guard let self, self.generation == session else { return }
                if failed {
                    if let continuation = self.finalResult {
                        self.finalResult = nil
                        continuation.resume(throwing: DictationFailure.recognitionFailed)
                    } else {
                        self.onError?(.recognitionFailed)
                    }
                } else if let text {
                    self.text = text
                    self.onPartial?(text)
                    if final, let continuation = self.finalResult {
                        self.finalResult = nil
                        continuation.resume(returning: text)
                    }
                }
            }
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == session else { return }
                self.onError?(.microphoneUnavailable)
            }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            _ = stop()
            throw DictationFailure.microphoneUnavailable
        }
    }

    func finish() async throws -> String {
        guard engine != nil else { return stop() }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        return try await withCheckedThrowingContinuation { continuation in
            finalResult = continuation
            request?.endAudio()
            // Speech may never produce a final callback after silence or device loss.
            finalDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, let continuation = self.finalResult else { return }
                self.finalResult = nil
                continuation.resume(returning: self.text)
            }
        }
    }

    func stop() -> String {
        generation += 1
        finalDeadline?.cancel()
        finalDeadline = nil
        if let continuation = finalResult {
            finalResult = nil
            continuation.resume(throwing: CancellationError())
        }
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer) }
        configurationObserver = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        let result = text
        text = ""
        return result
    }
}
