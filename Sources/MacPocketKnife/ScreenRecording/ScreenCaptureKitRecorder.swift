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

@preconcurrency import AppKit
@preconcurrency import AVFoundation
@preconcurrency import CoreGraphics
import MacPocketKnifeCore
@preconcurrency import ScreenCaptureKit

@MainActor
struct ScreenRecordingPermission: ScreenRecordingPermissionProviding {
    private static var requested = false

    func requestAccessIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if !Self.requested {
            Self.requested = true
            _ = CGRequestScreenCaptureAccess()
        }
        return CGPreflightScreenCaptureAccess()
    }
}

@MainActor
struct RecordingDiskSpace: FreeDiskSpaceProviding {
    func availableBytes(at folder: URL) throws -> Int64 {
        let values = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values.volumeAvailableCapacityForImportantUsage else {
            throw ScreenRecordingFailure.writingFailed
        }
        return bytes
    }
}

@MainActor
struct RecordingFiles: RecordingFileManaging {
    func createFolder(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    func exists(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path) }
    func revealFolder(_ folder: URL) { NSWorkspace.shared.open(folder) }
}

/// Writer and inputs belong exclusively to queue after initialization. Sample buffers
/// never cross into a main-actor Task. finish drains the same queue before closing inputs.
private final class RecordingOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "net.core-ai.MacPocketKnife.screen-recording")
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let diagnosticsEnabled: Bool
    private var diagnostics = [RecordingAudioDiagnostics(), RecordingAudioDiagnostics()]
    private var microphoneOutcome: RecordingMicrophoneOutcome = .disabled
    private var captureMicrophoneSet = false
    private var mixesMicrophone: Bool
    private var mixer: PCMMixer
    private let converter: RecordingPCMConverter
    private let destination: URL
    private let workingFile: URL
    private let failure: @Sendable (ScreenRecordingFailure?) -> Void
    private var firstVideoTime: CMTime?
    private var lastVideoTime: CMTime?
    private var latestTime: CMTime?
    private var wroteVideo = false
    private var closing = false
    private var reportedFailure = false
    private var activeStreamID: ObjectIdentifier?
    private var stoppedStreams: Set<ObjectIdentifier> = []

    init(destination: URL, width: Int, height: Int, frameRate: Int, microphone: Bool, diagnosticsEnabled: Bool,
         failure: @escaping @Sendable (ScreenRecordingFailure?) -> Void) throws {
        self.diagnosticsEnabled = diagnosticsEnabled
        self.destination = destination
        self.failure = failure
        workingFile = destination.deletingLastPathComponent().appendingPathComponent(".Recording-\(UUID().uuidString).mp4")
        writer = try AVAssetWriter(outputURL: workingFile, fileType: .mp4)
        let bitrate = ScreenRecordingFiles.bitrate(width: width, height: height, frameRate: frameRate)
        let compression: [String: Any] = [AVVideoAverageBitRateKey: bitrate,
                                          AVVideoExpectedSourceFrameRateKey: frameRate]
        let colorProperties: [String: Any] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                               AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                               AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        let videoSettings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264,
                                            AVVideoWidthKey: width, AVVideoHeightKey: height,
                                            AVVideoColorPropertiesKey: colorProperties,
                                            AVVideoCompressionPropertiesKey: compression]
        video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                                            AVEncoderBitRateKey: 160_000]
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        mixesMicrophone = microphone
        mixer = PCMMixer()
        converter = RecordingPCMConverter()
        super.init()
        let inputs = [video, audio]
        for input in inputs {
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw ScreenRecordingFailure.writingFailed }
            writer.add(input)
        }
        guard writer.startWriting() else {
            try? FileManager.default.removeItem(at: workingFile)
            throw ScreenRecordingFailure.writingFailed
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !closing else { return }
        var source: Int?
        if type == .audio { source = 0 }
        if #available(macOS 15.0, *), type == .microphone { source = 1 }
        if diagnosticsEnabled, let source { diagnostics[source].receive(sampleBuffer) }
        guard sampleBuffer.isValid else { return }
        guard writer.status == .writing else { reportWriterFailure(); return }
        let time = sampleBuffer.presentationTimeStamp
        guard time.isNumeric else { return }
        let input: AVAssetWriterInput
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let status = attachments.first?[.status] as? Int,
                  status == SCFrameStatus.complete.rawValue else { return }
            input = video
            if firstVideoTime == nil {
                firstVideoTime = time
                writer.startSession(atSourceTime: time)
            }
        } else {
            guard let source else { return }
            // Observe conversion before timeline guards, including startup buffers.
            let samples = mixesMicrophone || diagnosticsEnabled
                ? converter.samples(sampleBuffer, source: source) : nil
            if diagnosticsEnabled { diagnostics[source].conversion(samples) }
            guard let firstVideoTime else { return }
            if mixesMicrophone {
                if let samples {
                    let seconds = CMTimeSubtract(time, firstVideoTime).seconds
                    let frame = Int((seconds * 48_000).rounded())
                    let droppedBefore = mixer.droppedFrameCount
                    let added = mixer.add(samples, at: frame)
                    if diagnosticsEnabled {
                        diagnostics[source].addedFrames += added
                        diagnostics[source].droppedFrames += mixer.droppedFrameCount - droppedBefore
                    }
                    // Keep one second for sources delivered later than system audio.
                    // Already written audio cannot be shifted without breaking A/V sync.
                    drainAudio(upTo: mixer.endPosition - 48_000)
                }
                return
            }
            guard source == 0, CMTimeCompare(time, firstVideoTime) >= 0 else { return }
            input = audio
        }
        guard input.isReadyForMoreMediaData else { return }
        if input.append(sampleBuffer) {
            if type == .screen {
                wroteVideo = true
                lastVideoTime = time
            }
            var sampleEnd: CMTime = time
            let duration: CMTime = sampleBuffer.duration
            if duration.isNumeric {
                let end: CMTime = CMTimeAdd(time, duration)
                if CMTimeCompare(end, sampleEnd) > 0 { sampleEnd = end }
            }
            if let latestTime {
                if CMTimeCompare(sampleEnd, latestTime) > 0 { self.latestTime = sampleEnd }
            } else {
                latestTime = sampleEnd
            }
        } else { reportWriterFailure() }
        if writer.status == .failed { reportWriterFailure() }
    }

    func activate(_ stream: SCStream) async throws {
        let identifier = ObjectIdentifier(stream)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if stoppedStreams.contains(identifier) {
                    continuation.resume(throwing: ScreenRecordingFailure.captureFailed)
                } else {
                    activeStreamID = identifier
                    continuation.resume()
                }
            }
        }
    }

    func setMicrophoneDiagnostics(outcome: RecordingMicrophoneOutcome, captureMicrophone: Bool) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                microphoneOutcome = outcome
                captureMicrophoneSet = captureMicrophone
                continuation.resume()
            }
        }
    }

    private func printDiagnostics() {
        guard diagnosticsEnabled else { return }
        var block = "MIC-DEBUG BEGIN outcome=\(microphoneOutcome) config.captureMicrophone=\(captureMicrophoneSet) drainMarginSeconds=1\n"
        block += diagnostics[1].report(name: "microphone", firstVideoTime: firstVideoTime)
        block += diagnostics[0].report(name: "system", firstVideoTime: firstVideoTime)
        block += "MIC-DEBUG mixerDroppedBehindPosition=\(mixer.droppedFrameCount)\nMIC-DEBUG END\n"
        FileHandle.standardError.write(Data(block.utf8))
    }

    func disableMicrophone() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                mixesMicrophone = false
                continuation.resume()
            }
        }
    }

    private func drainAudio(upTo frame: Int, flushing: Bool = false) {
        guard let base = firstVideoTime else { return }
        while mixer.position < frame {
            if flushing && !audio.isReadyForMoreMediaData { return }
            let position = mixer.position
            let samples = mixer.drain(upTo: frame)
            let time = CMTimeAdd(base, CMTime(value: Int64(position), timescale: 48_000))
            guard let buffer = RecordingPCMConverter.buffer(samples, time: time) else {
                reportWriterFailure()
                return
            }
            // Match the direct capture path's real-time backpressure policy.
            guard audio.isReadyForMoreMediaData else { continue }
            if !audio.append(buffer) { reportWriterFailure(); return }
            let end = CMTimeAdd(time, CMTime(value: Int64(samples.count / 2), timescale: 48_000))
            if latestTime == nil || CMTimeCompare(end, latestTime!) > 0 { latestTime = end }
        }
    }

    private func reportWriterFailure() {
        guard !reportedFailure else { return }
        reportedFailure = true
        failure(.writingFailed)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let identifier = ObjectIdentifier(stream)
        let streamError = error as NSError
        let userStopped = streamError.domain == SCStreamErrorDomain && streamError.code == SCStreamError.userStopped.rawValue
        queue.async { [self] in
            stoppedStreams.insert(identifier)
            guard !closing, activeStreamID == identifier else { return }
            failure(userStopped ? nil : .captureFailed)
        }
    }

    func finish() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                closing = true
                printDiagnostics()
                finishWhenReady(continuation)
            }
        }
    }

    private func finishWhenReady(_ continuation: CheckedContinuation<URL?, Error>) {
        if mixesMicrophone && firstVideoTime != nil && writer.status == .writing {
            drainAudio(upTo: mixer.endPosition, flushing: true)
            if mixer.position < mixer.endPosition && writer.status == .writing && !reportedFailure {
                queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [self] in
                    finishWhenReady(continuation)
                }
                return
            }
        }
        if firstVideoTime == nil, writer.status == .writing {
            writer.startSession(atSourceTime: .zero)
        }
        if writer.status == .writing {
            if firstVideoTime != nil, wroteVideo, let latestTime, let lastVideoTime,
               CMTimeCompare(latestTime, lastVideoTime) > 0 {
                // ScreenCaptureKit stops sending frames while the screen is static.
                writer.endSession(atSourceTime: latestTime)
            }
            video.markAsFinished()
            audio.markAsFinished()
        }
        writer.finishWriting { [self] in
            queue.async { [self] in
                if writer.status == .completed, wroteVideo {
                    do {
                        // moveItem refuses an existing destination, including a collision
                        // created by another process after the controller's filename check.
                        try FileManager.default.moveItem(at: workingFile, to: destination)
                        continuation.resume(returning: destination)
                    } catch {
                        try? FileManager.default.removeItem(at: workingFile)
                        continuation.resume(throwing: ScreenRecordingFailure.writingFailed)
                    }
                } else {
                    try? FileManager.default.removeItem(at: workingFile)
                    if wroteVideo || writer.status == .failed {
                        continuation.resume(throwing: ScreenRecordingFailure.writingFailed)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }
}

@MainActor
final class ScreenCaptureKitRecorder: ScreenRecording {
    var onFailure: (@MainActor (ScreenRecordingFailure?) -> Void)?
    private var stream: SCStream?
    private var output: RecordingOutput?
    private var generation = 0

    func start(configuration: ScreenRecordingConfiguration, destination: URL,
               display requestedDisplay: DisplayInfo?, content pickedContent: (any ScreenRecordingContent)?) async throws -> RecordingMicrophoneOutcome {
        var outcome: RecordingMicrophoneOutcome = .disabled
        if configuration.includesMicrophone {
            if #available(macOS 15.0, *) {
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                if !allowed { outcome = .denied }
                else { outcome = AVCaptureDevice.default(for: .audio) == nil ? .unavailable : .included }
            } else { outcome = .unsupported }
        }
        let filter: SCContentFilter
        let width: Int
        let height: Int
        if #available(macOS 14.0, *), let picked = pickedContent as? PickedRecordingContent {
            filter = picked.filter
            let info = SCShareableContent.info(for: filter)
            width = Int(info.contentRect.width * CGFloat(info.pointPixelScale))
            height = Int(info.contentRect.height * CGFloat(info.pointPixelScale))
        } else {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let display = content.displays.first { candidate in
                if let requestedDisplay {
                    return RecordingDisplays.uuid(for: candidate.displayID) == requestedDisplay.uuid
                }
                return candidate.displayID == CGMainDisplayID()
            }
            guard let display, let mode = CGDisplayCopyDisplayMode(display.displayID) else {
                throw ScreenRecordingFailure.noDisplay
            }
            width = mode.pixelWidth
            height = mode.pixelHeight
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }
        guard width > 0, height > 0 else { throw ScreenRecordingFailure.noDisplay }
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.frameRate))
        config.showsCursor = configuration.showsCursor
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        var microphone = false
        if #available(macOS 15.0, *) {
            config.captureMicrophone = outcome == .included
            microphone = outcome == .included
        }
        generation += 1
        let session = generation
        let output = try RecordingOutput(destination: destination, width: width, height: height,
                                         frameRate: configuration.frameRate, microphone: microphone,
                                         diagnosticsEnabled: RecordingSelfTest.microphoneDiagnosticsEnabled) { [weak self] failure in
            Task { @MainActor [weak self] in
                guard let self, self.generation == session else { return }
                self.onFailure?(failure)
            }
        }
        self.output = output
        do {
            try await startStream(filter: filter, configuration: config, output: output, microphone: microphone)
        } catch {
            guard microphone else { throw error }
            // Retry capture independently of the microphone, including errors while
            // registering its output or opening the input device.
            try? await self.stream?.stopCapture()
            if #available(macOS 15.0, *) { config.captureMicrophone = false }
            await output.disableMicrophone()
            try await startStream(filter: filter, configuration: config, output: output, microphone: false)
            outcome = .unavailable
        }
        if RecordingSelfTest.microphoneDiagnosticsEnabled {
            var captureMicrophone = false
            if #available(macOS 15.0, *) { captureMicrophone = config.captureMicrophone }
            await output.setMicrophoneDiagnostics(outcome: outcome, captureMicrophone: captureMicrophone)
        }
        return outcome
    }

    private func startStream(filter: SCContentFilter, configuration: SCStreamConfiguration,
                             output: RecordingOutput, microphone: Bool) async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        self.stream = stream
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
        if #available(macOS 15.0, *), microphone {
            try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.queue)
        }
        try await stream.startCapture()
        try await output.activate(stream)
    }

    func stop() async throws -> URL? {
        generation += 1
        let stream = self.stream
        self.stream = nil
        // stopCapture can fail after macOS has already stopped sharing; still close the writer.
        try? await stream?.stopCapture()
        let output = self.output
        self.output = nil
        if let output { return try await output.finish() }
        return nil
    }
}
