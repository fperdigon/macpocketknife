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
import Foundation

// Twelve unique slots; the verifier intentionally uses the same fixed signal vocabulary.
let palette: [[UInt8]] = [
    [255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0],
    [255, 0, 255], [0, 255, 255], [255, 255, 255], [255, 128, 0],
    [128, 0, 255], [0, 128, 128], [255, 128, 192], [128, 255, 0]
]

// BT.709 coefficients, with video-range Y (16...235) and Cb/Cr (16...240).
func clampedByte(_ value: Double) -> UInt8 {
    let rounded: Double = value.rounded()
    let integer: Int = Int(rounded)
    return UInt8(clamping: integer)
}

func ycbcr(_ color: [UInt8]) -> [UInt8] {
    let r: Double = Double(color[0]) / 255.0
    let g: Double = Double(color[1]) / 255.0
    let b: Double = Double(color[2]) / 255.0
    let redLuma: Double = 0.2126 * r
    let greenLuma: Double = 0.7152 * g
    let blueLuma: Double = 0.0722 * b
    let redGreenLuma: Double = redLuma + greenLuma
    let y: Double = redGreenLuma + blueLuma
    let scaledY: Double = 219.0 * y
    let videoY: Double = 16.0 + scaledY
    let blueDifference: Double = b - y
    let scaledBlueDifference: Double = 224.0 * blueDifference
    let cbOffset: Double = scaledBlueDifference / 1.8556
    let cb: Double = 128.0 + cbOffset
    let redDifference: Double = r - y
    let scaledRedDifference: Double = 224.0 * redDifference
    let crOffset: Double = scaledRedDifference / 1.5748
    let cr: Double = 128.0 + crOffset
    return [clampedByte(videoY), clampedByte(cb), clampedByte(cr)]
}

let ycbcrPalette: [[UInt8]] = palette.map { ycbcr($0) }

func toneSample(slot: Int, position: Int) -> Float {
    let frequencyOffset: Int = slot * 110
    let frequency: Double = Double(440 + frequencyOffset)
    let angularScale: Double = 2.0 * Double.pi
    let angularFrequency: Double = angularScale * frequency
    let phaseNumerator: Double = angularFrequency * Double(position)
    let phase: Double = phaseNumerator / 48_000.0
    let amplitude: Double = 0.35 * sin(phase)
    return Float(amplitude)
}

// The watchdog reads counters independently of any potentially stuck encoder call.
final class ClipProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var audioBuffers = 0
    let writer: AVAssetWriter

    init(writer: AVAssetWriter) { self.writer = writer }

    func appended(video: Bool) {
        lock.lock()
        if video { frames += 1 } else { audioBuffers += 1 }
        let report = video && frames % 60 == 0
        lock.unlock()
        if report { printStatus("Progress") }
    }

    func printStatus(_ reason: String) {
        lock.lock()
        let counts = "frames appended=\(frames), audio buffers appended=\(audioBuffers)"
        lock.unlock()
        FileHandle.standardError.write(Data(
            "\(reason): \(counts), writer.status=\(writer.status.rawValue), writer.error=\(String(describing: writer.error))\n".utf8))
    }
}

// After setup, each producer's input, adaptor and mutable state belong to its serial queue.
final class ClipProducer: @unchecked Sendable {
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor?
    var nextIndex: Int = 0
    var finished: Bool = false

    init(input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor? = nil) {
        self.input = input
        self.adaptor = adaptor
    }
}

func failAppending(_ writer: AVAssetWriter) -> Never {
    let error: Error = writer.error ?? NSError(domain: "Writer failed to append media", code: 1)
    FileHandle.standardError.write(Data("make-clip: \(error)\n".utf8))
    exit(1)
}

func makeClip(_ path: String, silent: Bool, shuffled: Bool) throws {
    let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: .mp4)
    let progress = ClipProgress(writer: writer)
    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(45)) {
        progress.printStatus("TIMEOUT make-clip after 45s")
        exit(3)
    }
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1280, AVVideoHeightKey: 720,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000],
        AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
        sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                     kCVPixelBufferWidthKey as String: 1280,
                                     kCVPixelBufferHeightKey as String: 720])
    let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000
    ])
    guard writer.canApply(outputSettings: video.outputSettings, forMediaType: .video), writer.canAdd(video) else {
        throw NSError(domain: "H.264 encoder unavailable in this session", code: 1)
    }
    guard writer.canApply(outputSettings: audio.outputSettings, forMediaType: .audio), writer.canAdd(audio) else {
        throw NSError(domain: "AAC encoder unavailable in this session", code: 1)
    }
    writer.add(video)
    writer.add(audio)
    guard writer.startWriting() else { throw writer.error! }
    writer.startSession(atSourceTime: .zero)
    var format: CMAudioFormatDescription?
    var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    let audioFormat: CMAudioFormatDescription = format!
    let producers: DispatchGroup = DispatchGroup()
    let videoQueue: DispatchQueue = DispatchQueue(label: "make-clip.video")
    let audioQueue: DispatchQueue = DispatchQueue(label: "make-clip.audio")
    let videoProducer: ClipProducer = ClipProducer(input: video, adaptor: adaptor)
    let audioProducer: ClipProducer = ClipProducer(input: audio)
    producers.enter()
    producers.enter()
    // Let each input pull independently so writer interleaving cannot block its peer.
    video.requestMediaDataWhenReady(on: videoQueue) {
        guard !videoProducer.finished else { return }
        let video: AVAssetWriterInput = videoProducer.input
        let adaptor: AVAssetWriterInputPixelBufferAdaptor = videoProducer.adaptor!
        while video.isReadyForMoreMediaData && videoProducer.nextIndex < 360 {
            let frame: Int = videoProducer.nextIndex
            let slot: Int = shuffled ? 11 - frame / 30 : frame / 30
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixel = buffer!
            CVPixelBufferLockBaseAddress(pixel, [])
            let color = ycbcrPalette[slot]
            let yBytes = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt8.self)
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)
            for row in 0..<720 {
                yBytes.advanced(by: row * yStride).update(repeating: color[0], count: 1280)
            }
            let chroma = CVPixelBufferGetBaseAddressOfPlane(pixel, 1)!.assumingMemoryBound(to: UInt8.self)
            let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 1)
            for row in 0..<360 {
                let bytes = chroma.advanced(by: row * chromaStride)
                for column in 0..<640 {
                    bytes[column * 2] = color[1]
                    bytes[column * 2 + 1] = color[2]
                }
            }
            CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                                  .shouldPropagate)
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                failAppending(progress.writer)
            }
            progress.appended(video: true)
            videoProducer.nextIndex += 1
        }
        if videoProducer.nextIndex == 360 {
            videoProducer.finished = true
            video.markAsFinished()
            producers.leave()
        }
    }
    audio.requestMediaDataWhenReady(on: audioQueue) {
        guard !audioProducer.finished else { return }
        let audio: AVAssetWriterInput = audioProducer.input
        while audio.isReadyForMoreMediaData && audioProducer.nextIndex < 360 {
            let frame: Int = audioProducer.nextIndex
            let slot: Int = shuffled ? 11 - frame / 30 : frame / 30
            var samples = [Float](repeating: 0, count: 1600)
            for index in samples.indices {
                let frameStart: Int = frame * 1600
                let position: Int = frameStart + index
                let positionInSecond: Int = position % 48_000
                let phase: Double = Double(positionInSecond) / 48_000.0
                if !silent && phase >= 0.04 && phase < 0.96 {
                    samples[index] = toneSample(slot: slot, position: position)
                }
            }
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: samples.count * 4,
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                dataLength: samples.count * 4, flags: 0, blockBufferOut: &block)
            _ = samples.withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0,
                                              dataLength: raw.count)
            }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                presentationTimeStamp: CMTime(value: Int64(frame * 1600), timescale: 48_000), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            var size = 4
            CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: audioFormat,
                sampleCount: 1600, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
            guard audio.append(sample!) else { failAppending(progress.writer) }
            progress.appended(video: false)
            audioProducer.nextIndex += 1
        }
        if audioProducer.nextIndex == 360 {
            audioProducer.finished = true
            audio.markAsFinished()
            producers.leave()
        }
    }
    producers.wait()
    writer.endSession(atSourceTime: CMTime(value: 12, timescale: 1))
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    guard done.wait(timeout: .now() + .seconds(15)) == .success else {
        progress.printStatus("TIMEOUT finishing clip")
        exit(3)
    }
    guard writer.status == .completed else { throw writer.error! }
    print("Generated 12 slots, 12.0 s, 1280x720, 30 fps, H.264/AAC: \(path)")
}

do {
    guard CommandLine.arguments.count >= 2 else {
        throw NSError(domain: "Usage: make-clip <output.mp4> [--silent] [--shuffled]", code: 2)
    }
    try makeClip(CommandLine.arguments[1], silent: CommandLine.arguments.contains("--silent"),
                 shuffled: CommandLine.arguments.contains("--shuffled"))
} catch {
    FileHandle.standardError.write(Data("make-clip: \(error)\n".utf8)); exit(1)
}
