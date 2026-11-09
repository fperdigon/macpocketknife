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

import AppKit
import AVFoundation
import CoreGraphics
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
    private let microphone: AVAssetWriterInput?
    private let destination: URL
    private let workingFile: URL
    private let failure: @Sendable (ScreenRecordingFailure?) -> Void
    private var firstVideoTime: CMTime?
    private var lastVideoTime: CMTime?
    private var latestTime: CMTime?
    private var wroteVideo = false
    private var closing = false
    private var reportedFailure = false

    init(destination: URL, width: Int, height: Int, frameRate: Int, microphone: Bool,
         failure: @escaping @Sendable (ScreenRecordingFailure?) -> Void) throws {
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
        self.microphone = microphone ? AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings) : nil
        super.init()
        var inputs = [video, audio]
        if let input = self.microphone { inputs.append(input) }
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
        guard !closing, sampleBuffer.isValid else { return }
        guard writer.status == .writing else { reportWriterFailure(); return }
        let time = sampleBuffer.presentationTimeStamp
        guard time.isValid else { return }
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
            guard let firstVideoTime, CMTimeCompare(time, firstVideoTime) >= 0 else { return }
            if type == .audio {
                input = audio
            } else if #available(macOS 15.0, *), type == .microphone, let microphone {
                input = microphone
            } else { return }
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

    private func reportWriterFailure() {
        guard !reportedFailure else { return }
        reportedFailure = true
        failure(.writingFailed)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let streamError = error as NSError
        let userStopped = streamError.domain == SCStreamErrorDomain && streamError.code == SCStreamError.userStopped.rawValue
        queue.async { [self] in
            guard !closing else { return }
            failure(userStopped ? nil : .captureFailed)
        }
    }

    func finish() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                closing = true
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
                    microphone?.markAsFinished()
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
    }
}

@MainActor
final class ScreenCaptureKitRecorder: ScreenRecording {
    var onFailure: (@MainActor (ScreenRecordingFailure?) -> Void)?
    private var stream: SCStream?
    private var output: RecordingOutput?
    private var generation = 0

    func start(configuration: ScreenRecordingConfiguration, destination: URL) async throws {
        if configuration.includesMicrophone {
            if #available(macOS 15.0, *) {
                guard await AVCaptureDevice.requestAccess(for: .audio) else { throw ScreenRecordingFailure.microphoneDenied }
            }
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
            throw ScreenRecordingFailure.noDisplay
        }
        // Display modes expose actual backing pixels, including Retina/scaled modes.
        guard let mode = CGDisplayCopyDisplayMode(display.displayID) else { throw ScreenRecordingFailure.noDisplay }
        let width = mode.pixelWidth
        let height = mode.pixelHeight
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
            config.captureMicrophone = configuration.includesMicrophone
            microphone = configuration.includesMicrophone
        }
        generation += 1
        let session = generation
        let output = try RecordingOutput(destination: destination, width: width, height: height,
                                         frameRate: configuration.frameRate, microphone: microphone) { [weak self] failure in
            Task { @MainActor [weak self] in
                guard let self, self.generation == session else { return }
                self.onFailure?(failure)
            }
        }
        self.output = output
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        self.stream = stream
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
        if #available(macOS 15.0, *), microphone {
            try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.queue)
        }
        try await stream.startCapture()
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
