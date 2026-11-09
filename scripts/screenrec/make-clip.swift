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

func makeClip(_ path: String, silent: Bool, shuffled: Bool) throws {
    let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: .mp4)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1280, AVVideoHeightKey: 720,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000]
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
        sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
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
    // Interleave inputs so neither encoder can block waiting for the other track.
    var format: CMAudioFormatDescription?
    var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    for frame in 0..<360 {
        let slot = shuffled ? 11 - frame / 30 : frame / 30
        while !video.isReadyForMoreMediaData {
            guard writer.status == .writing else { throw writer.error ?? NSError(domain: "Video writer stopped", code: 1) }
            Thread.sleep(forTimeInterval: 0.001)
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        let pixel = buffer!
        CVPixelBufferLockBaseAddress(pixel, [])
        let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        let color = palette[slot]
        let packed = UInt32(color[2]) | (UInt32(color[1]) << 8) | (UInt32(color[0]) << 16) | 0xFF000000
        for y in 0..<720 {
            let row = UnsafeMutableRawPointer(bytes.advanced(by: y * stride)).assumingMemoryBound(to: UInt32.self)
            row.update(repeating: packed, count: 1280)
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
            throw writer.error!
        }
        while !audio.isReadyForMoreMediaData {
            guard writer.status == .writing else { throw writer.error ?? NSError(domain: "Audio writer stopped", code: 1) }
            Thread.sleep(forTimeInterval: 0.001)
        }
        var samples = [Float](repeating: 0, count: 1600)
        for index in samples.indices {
            let position = frame * 1600 + index
            let phase = Double(position % 48_000) / 48_000
            if !silent && phase >= 0.04 && phase < 0.96 {
                samples[index] = Float(0.35 * sin(2 * .pi * Double(440 + slot * 110) * Double(position) / 48_000))
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
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
            sampleCount: 1600, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard audio.append(sample!) else { throw writer.error! }
    }
    writer.endSession(atSourceTime: CMTime(value: 12, timescale: 1))
    video.markAsFinished(); audio.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
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
