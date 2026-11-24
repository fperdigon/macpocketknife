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
@preconcurrency import CoreGraphics
@preconcurrency import ScreenCaptureKit
import MacPocketKnifeCore

@MainActor
struct AudioRecordingFactoryImpl: AudioRecordingFactory {
    func makeAudioRecorder() -> any AudioRecording { AudioCaptureKitRecorder() }
}

/// Only this serial queue owns the writer, converter and bounded PCM accumulation.
private final class AudioRecordingOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "MacPocketKnife.audio-recording")
    private let writer: AVAssetWriter
    private let audio: AVAssetWriterInput
    private let converter: RecordingPCMConverter
    private var mixer: PCMMixer
    private let destination: URL
    private let workingFile: URL
    private let failure: @Sendable (ScreenRecordingFailure?) -> Void
    private var base: CMTime?
    private var closing = false
    private var wroteAudio = false
    private var reportedFailure = false
    private var activeStream: ObjectIdentifier?
    private var flushAttempts = 0

    init(destination: URL, failure: @escaping @Sendable (ScreenRecordingFailure?) -> Void) throws {
        self.destination = destination
        self.failure = failure
        converter = RecordingPCMConverter()
        mixer = PCMMixer()
        workingFile = destination.deletingLastPathComponent().appendingPathComponent(".Recording-\(UUID().uuidString).m4a")
        writer = try AVAssetWriter(outputURL: workingFile, fileType: .m4a)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000]
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        super.init()
        audio.expectsMediaDataInRealTime = true
        guard writer.canAdd(audio) else {
            try? FileManager.default.removeItem(at: workingFile)
            throw ScreenRecordingFailure.writingFailed
        }
        writer.add(audio)
        guard writer.startWriting() else {
            try? FileManager.default.removeItem(at: workingFile)
            throw ScreenRecordingFailure.writingFailed
        }
    }

    func activate(_ stream: SCStream) async {
        let id = ObjectIdentifier(stream)
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                activeStream = id
                continuation.resume()
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        // Tiny video frames are discarded immediately; no video input or screenshot exists.
        guard !closing, type != .screen, sample.isValid else { return }
        let source: Int
        if type == .audio { source = 0 }
        else if #available(macOS 15.0, *), type == .microphone { source = 1 }
        else { return }
        let time = sample.presentationTimeStamp
        guard time.isNumeric, let samples = converter.samples(sample, source: source), !samples.isEmpty else { return }
        guard writer.status == .writing else { fail(); return }
        if base == nil {
            base = time
            writer.startSession(atSourceTime: time)
        }
        guard let base else { return }
        let seconds = CMTimeSubtract(time, base).seconds
        guard seconds.isFinite else { return }
        let frame = Int((seconds * 48_000).rounded())
        mixer.add(samples, at: frame)
        drain(upTo: mixer.endPosition - 48_000, flushing: false)
    }

    private func drain(upTo frame: Int, flushing: Bool) {
        guard let base else { return }
        while mixer.position < frame && !reportedFailure {
            if flushing && !audio.isReadyForMoreMediaData { return }
            let position = mixer.position
            let samples = mixer.drain(upTo: frame)
            let time = CMTimeAdd(base, CMTime(value: Int64(position), timescale: 48_000))
            guard let buffer = RecordingPCMConverter.buffer(samples, time: time) else { fail(); return }
            // Same real-time backpressure policy as the video mixer: drop rather than accumulate.
            guard audio.isReadyForMoreMediaData else { continue }
            if audio.append(buffer) { wroteAudio = true }
            else { fail(); return }
        }
    }

    private func fail() {
        guard !reportedFailure else { return }
        reportedFailure = true
        failure(.writingFailed)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let id = ObjectIdentifier(stream)
        let error = error as NSError
        let userStopped = error.domain == SCStreamErrorDomain && error.code == SCStreamError.userStopped.rawValue
        queue.async { [self] in
            guard !closing, activeStream == id else { return }
            failure(userStopped ? nil : .captureFailed)
        }
    }

    func finish() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                closing = true
                finishWhenReady(continuation)
            }
        }
    }

    private func finishWhenReady(_ continuation: CheckedContinuation<URL?, Error>) {
        if base == nil {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: workingFile)
            continuation.resume(returning: nil)
            return
        }
        if writer.status == .writing && !reportedFailure {
            drain(upTo: mixer.endPosition, flushing: true)
            if mixer.position < mixer.endPosition {
                flushAttempts += 1
                if flushAttempts < 500 {
                    queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [self] in finishWhenReady(continuation) }
                    return
                }
                fail()
            }
        }
        if writer.status == .writing { audio.markAsFinished() }
        writer.finishWriting { [self] in
            queue.async { [self] in
                if writer.status == .completed, wroteAudio {
                    do {
                        try FileManager.default.moveItem(at: workingFile, to: destination)
                        continuation.resume(returning: destination)
                    } catch {
                        try? FileManager.default.removeItem(at: workingFile)
                        continuation.resume(throwing: ScreenRecordingFailure.writingFailed)
                    }
                } else {
                    try? FileManager.default.removeItem(at: workingFile)
                    continuation.resume(throwing: ScreenRecordingFailure.writingFailed)
                }
            }
        }
    }
}

@MainActor
final class AudioCaptureKitRecorder: AudioRecording {
    var onFailure: (@MainActor (ScreenRecordingFailure?) -> Void)?
    private var stream: SCStream?
    private var output: AudioRecordingOutput?
    private var generation = 0

    func start(configuration: AudioRecordingConfiguration, destination: URL) async throws -> RecordingMicrophoneOutcome {
        try configuration.validate()
        var outcome: RecordingMicrophoneOutcome = .disabled
        if configuration.microphone {
            if #available(macOS 15.0, *) {
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                if !allowed { outcome = .denied }
                else { outcome = AVCaptureDevice.default(for: .audio) == nil ? .unavailable : .included }
            } else { outcome = .unsupported }
        }
        if !configuration.systemAudio && outcome != .included {
            throw outcome == .denied ? ScreenRecordingFailure.microphoneDenied : .microphoneUnavailable
        }
        // Do not trust Screen Recording preflight: ScreenCaptureKit's start attempt is authoritative.
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw Self.captureFailure(error) }
        guard let display = content.displays.first else { throw ScreenRecordingFailure.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = configuration.systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        if #available(macOS 15.0, *) { config.captureMicrophone = outcome == .included }
        generation += 1
        let session = generation
        let output = try AudioRecordingOutput(destination: destination) { [weak self] failure in
            Task { @MainActor [weak self] in
                guard let self, self.generation == session else { return }
                self.onFailure?(failure)
            }
        }
        self.output = output
        do {
            try await startStream(filter: filter, config: config, output: output, microphone: outcome == .included)
        } catch {
            let failure = Self.captureFailure(error)
            guard outcome == .included, configuration.systemAudio, failure != .permissionDenied else { throw failure }
            try? await stream?.stopCapture()
            if #available(macOS 15.0, *) { config.captureMicrophone = false }
            do { try await startStream(filter: filter, config: config, output: output, microphone: false) }
            catch { throw Self.captureFailure(error) }
            outcome = .unavailable
        }
        return outcome
    }

    private static func captureFailure(_ error: any Error) -> ScreenRecordingFailure {
        let error = error as NSError
        if error.domain == SCStreamErrorDomain && error.code == SCStreamError.userDeclined.rawValue { return .permissionDenied }
        return .captureFailed
    }

    private func startStream(filter: SCContentFilter, config: SCStreamConfiguration,
                             output: AudioRecordingOutput, microphone: Bool) async throws {
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        self.stream = stream
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        if config.capturesAudio { try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue) }
        if #available(macOS 15.0, *), microphone {
            try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.queue)
        }
        await output.activate(stream)
        try await stream.startCapture()
    }

    func stop() async throws -> URL? {
        generation += 1
        let stream = self.stream
        self.stream = nil
        try? await stream?.stopCapture()
        let output = self.output
        self.output = nil
        return try await output?.finish()
    }
}
