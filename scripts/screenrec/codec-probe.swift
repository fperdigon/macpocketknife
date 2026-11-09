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
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct ProbeCase {
    let name: String
    let fileType: AVFileType
    let fileExtension: String
    let videoCodec: AVVideoCodecType?
    let audioFormat: AudioFormatID?
    let pcm: Bool
}

final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<(Int, Bool), Error>?

    func set(_ value: Result<(Int, Bool), Error>) {
        lock.lock(); defer { lock.unlock() }
        stored = value
    }

    func get() -> Result<(Int, Bool), Error>? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

let cases: [ProbeCase] = [
    ProbeCase(name: "H.264", fileType: .mp4, fileExtension: "mp4", videoCodec: .h264, audioFormat: nil, pcm: false),
    ProbeCase(name: "HEVC", fileType: .mp4, fileExtension: "mp4", videoCodec: .hevc, audioFormat: nil, pcm: false),
    ProbeCase(name: "JPEG/MJPEG", fileType: .mov, fileExtension: "mov", videoCodec: .jpeg, audioFormat: nil, pcm: false),
    ProbeCase(name: "ProRes 422", fileType: .mov, fileExtension: "mov", videoCodec: .proRes422, audioFormat: nil, pcm: false),
    ProbeCase(name: "AAC", fileType: .mp4, fileExtension: "mp4", videoCodec: nil, audioFormat: kAudioFormatMPEG4AAC, pcm: false),
    ProbeCase(name: "Linear PCM 16-bit", fileType: .mov, fileExtension: "mov", videoCodec: nil, audioFormat: kAudioFormatLinearPCM, pcm: true),
    ProbeCase(name: "Apple Lossless", fileType: .m4a, fileExtension: "m4a", videoCodec: nil, audioFormat: kAudioFormatAppleLossless, pcm: false)
]

func printEncoderList() {
    var list: CFArray?
    let status = VTCopyVideoEncoderList(nil, &list)
    guard status == noErr, let entries = list as? [[String: Any]] else {
        print("VideoToolbox encoders: unavailable (status \(status))")
        return
    }
    print("VideoToolbox encoders:")
    for entry in entries {
        let codec = entry["CodecName"] as? String ?? "unknown codec"
        let hardware = (entry[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) ?? false
        print("  \(codec): hardware accelerated=\(hardware ? "yes" : "no")")
    }
}

func makeAudioSample(format: CMAudioFormatDescription, frameCount: Int, startFrame: Int64) -> CMSampleBuffer? {
    var samples = [Int16](repeating: 0, count: frameCount * 2)
    for frame in 0..<frameCount {
        let phase = 2.0 * Double.pi * 440.0 * Double(startFrame + Int64(frame)) / 48_000.0
        let value = Int16(sin(phase) * 12_000)
        samples[frame * 2] = value
        samples[frame * 2 + 1] = value
    }
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil,
        blockLength: samples.count * MemoryLayout<Int16>.size, blockAllocator: nil,
        customBlockSource: nil, offsetToData: 0, dataLength: samples.count * MemoryLayout<Int16>.size,
        flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
    let copied = samples.withUnsafeBytes {
        CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count)
    }
    guard copied == kCMBlockBufferNoErr else { return nil }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
        presentationTimeStamp: CMTime(value: startFrame, timescale: 48_000), decodeTimeStamp: .invalid)
    var size = MemoryLayout<Int16>.size * 2
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
        sampleCount: frameCount, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
    return sample
}

func run(_ probe: ProbeCase) throws -> (Int, Bool) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("codec-probe-\(UUID().uuidString).\(probe.fileExtension)")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try AVAssetWriter(outputURL: url, fileType: probe.fileType)
    if let codec = probe.videoCodec {
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: 640, AVVideoHeightKey: 360
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360
        ])
        guard writer.canAdd(input) else {
            throw NSError(domain: "Video settings unsupported", code: 1)
        }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "startWriting failed", code: 2) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            guard input.isReadyForMoreMediaData else { throw NSError(domain: "Video input not ready", code: 3) }
            var pixel: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess,
                  let pixel else { throw NSError(domain: "Pixel buffer allocation failed", code: 4) }
            CVPixelBufferLockBaseAddress(pixel, [])
            if let base = CVPixelBufferGetBaseAddress(pixel) {
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<360 {
                    let row = bytes.advanced(by: y * CVPixelBufferGetBytesPerRow(pixel))
                    for x in 0..<640 {
                        let p = row.advanced(by: x * 4)
                        p[0] = 32; p[1] = 96; p[2] = 192; p[3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? NSError(domain: "Video append failed", code: 5)
            }
        }
        input.markAsFinished()
    } else if let audioFormat = probe.audioFormat {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: audioFormat,
            mFormatFlags: probe.pcm ? (kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked) : 0,
            mBytesPerPacket: probe.pcm ? 4 : 0, mFramesPerPacket: 1,
            mBytesPerFrame: probe.pcm ? 4 : 0, mChannelsPerFrame: 2,
            mBitsPerChannel: probe.pcm ? 16 : 0, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format) == noErr, let format else {
            throw NSError(domain: "Audio format creation failed", code: 6)
        }
        var settings: [String: Any] = [AVFormatIDKey: audioFormat, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2]
        if probe.pcm {
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        } else if audioFormat == kAudioFormatMPEG4AAC {
            settings[AVEncoderBitRateKey] = 128_000
        } else if audioFormat == kAudioFormatAppleLossless {
            settings[AVEncoderBitDepthHintKey] = 16
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        guard writer.canAdd(input) else {
            throw NSError(domain: "Audio settings unsupported", code: 7)
        }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "startWriting failed", code: 8) }
        writer.startSession(atSourceTime: .zero)
        for start in stride(from: 0, to: 48_000, by: 1_024) {
            let count = min(1_024, 48_000 - start)
            guard input.isReadyForMoreMediaData,
                  let sample = makeAudioSample(format: format, frameCount: count, startFrame: Int64(start)),
                  input.append(sample) else { throw writer.error ?? NSError(domain: "Audio append failed", code: 9) }
        }
        input.markAsFinished()
    }
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    guard done.wait(timeout: .now() + 12) == .success else { throw NSError(domain: "finishWriting timed out", code: 10) }
    guard writer.status == .completed else { throw writer.error ?? NSError(domain: "Writer did not complete", code: 11) }
    let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    let asset = AVURLAsset(url: url)
    let readable = asset.duration.seconds.isFinite && asset.duration.seconds > 0 && !asset.tracks.isEmpty
    return (bytes, readable)
}

printEncoderList()
for probe in cases {
    let done = DispatchSemaphore(value: 0)
    let output = ResultBox()
    DispatchQueue.global(qos: .userInitiated).async {
        output.set(Result { try run(probe) })
        done.signal()
    }
    if done.wait(timeout: .now() + 15) == .timedOut {
        print("CASE \(probe.name): HANG")
    } else {
        let value = output.get()
        switch value {
        case .success(let (bytes, readable)):
            print("CASE \(probe.name): OK \(bytes) bytes, readable=\(readable ? "yes" : "no")")
        case .failure(let error):
            print("CASE \(probe.name): FAIL \(error)")
        case .none:
            print("CASE \(probe.name): FAIL missing result")
        }
    }
}
exit(0)
