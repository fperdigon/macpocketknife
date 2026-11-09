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
import AudioToolbox
import CoreAudio
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
    ProbeCase(name: "h264", fileType: .mp4, fileExtension: "mp4", videoCodec: .h264, audioFormat: nil, pcm: false),
    ProbeCase(name: "hevc", fileType: .mp4, fileExtension: "mp4", videoCodec: .hevc, audioFormat: nil, pcm: false),
    ProbeCase(name: "jpeg", fileType: .mov, fileExtension: "mov", videoCodec: .jpeg, audioFormat: nil, pcm: false),
    ProbeCase(name: "prores422", fileType: .mov, fileExtension: "mov", videoCodec: .proRes422, audioFormat: nil, pcm: false),
    ProbeCase(name: "aac-mp4", fileType: .mp4, fileExtension: "mp4", videoCodec: nil, audioFormat: kAudioFormatMPEG4AAC, pcm: false),
    ProbeCase(name: "aac-m4a", fileType: .m4a, fileExtension: "m4a", videoCodec: nil, audioFormat: kAudioFormatMPEG4AAC, pcm: false),
    ProbeCase(name: "aac-mov", fileType: .mov, fileExtension: "mov", videoCodec: nil, audioFormat: kAudioFormatMPEG4AAC, pcm: false),
    ProbeCase(name: "pcm-mov", fileType: .mov, fileExtension: "mov", videoCodec: nil, audioFormat: kAudioFormatLinearPCM, pcm: true),
    ProbeCase(name: "alac-m4a", fileType: .m4a, fileExtension: "m4a", videoCodec: nil, audioFormat: kAudioFormatAppleLossless, pcm: false)
]
let extraCases = ["aac-extaudiofile", "aac-converter-only"]

// Write directly so a crash or watchdog exit cannot hide buffered diagnostics.
func emit(_ message: String, to handle: FileHandle = .standardOutput) {
    handle.write(Data((message + "\n").utf8))
}

func fourCC(_ value: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }
    return bytes.allSatisfy { (32...126).contains($0) }
        ? "'" + String(bytes: bytes, encoding: .ascii)! + "'" : String(format: "0x%08x", value)
}

func pcmDescription() -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
}

func printAudioDiagnostics() {
    var size: UInt32 = 0
    var status = AudioFormatGetPropertyInfo(kAudioFormatProperty_EncodeFormatIDs, 0, nil, &size)
    if status == noErr {
        var formats = [AudioFormatID](repeating: 0, count: Int(size) / MemoryLayout<AudioFormatID>.size)
        status = formats.withUnsafeMutableBytes {
            AudioFormatGetProperty(kAudioFormatProperty_EncodeFormatIDs, 0, nil, &size, $0.baseAddress!)
        }
        emit("AudioToolbox encoder format IDs: status=\(status) \(formats.prefix(Int(size) / 4).map(fourCC).joined(separator: ", "))", to: .standardError)
    } else {
        emit("AudioToolbox encoder format IDs: unavailable (OSStatus=\(status))", to: .standardError)
    }
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var device = AudioDeviceID(kAudioObjectUnknown)
    size = UInt32(MemoryLayout.size(ofValue: device))
    status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    emit("Default output device: id=\(device), OSStatus=\(status)", to: .standardError)
}

func printEncoderList() {
    var list: CFArray?
    let status = VTCopyVideoEncoderList(nil, &list)
    guard status == noErr, let entries = list as? [[String: Any]] else {
        emit("VideoToolbox encoders: unavailable (status \(status))", to: .standardError)
        return
    }
    emit("VideoToolbox encoders:", to: .standardError)
    for entry in entries {
        let codec = entry["CodecName"] as? String ?? "unknown codec"
        let hardware = (entry[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) ?? false
        emit("  \(codec): hardware accelerated=\(hardware ? "yes" : "no")", to: .standardError)
    }
}

func pcmSample(at frame: Int64) -> Int16 {
    let angularScale: Double = 2.0 * Double.pi
    let angularFrequency: Double = angularScale * 440.0
    let phaseNumerator: Double = angularFrequency * Double(frame)
    let phase: Double = phaseNumerator / 48_000.0
    let amplitude: Double = sin(phase) * 12_000.0
    return Int16(amplitude)
}

func makeAudioSample(format: CMAudioFormatDescription, frameCount: Int, startFrame: Int64) -> CMSampleBuffer? {
    var samples = [Int16](repeating: 0, count: frameCount * 2)
    for frame in 0..<frameCount {
        let position: Int64 = startFrame + Int64(frame)
        let value: Int16 = pcmSample(at: position)
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
        var asbd = pcmDescription()
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

func check(_ status: OSStatus, _ operation: String) throws {
    emit("\(operation): OSStatus=\(status) (\(fourCC(UInt32(bitPattern: status))))")
    guard status == noErr else { throw NSError(domain: operation, code: Int(status)) }
}

func runConverterOnly() throws -> (Int, Bool) {
    var source = pcmDescription()
    var destination = AudioStreamBasicDescription()
    destination.mSampleRate = 48_000
    destination.mFormatID = kAudioFormatMPEG4AAC
    destination.mChannelsPerFrame = 2
    var converter: AudioConverterRef?
    let status = AudioConverterNew(&source, &destination, &converter)
    try check(status, "AudioConverterNew LPCM -> AAC")
    if let converter { try check(AudioConverterDispose(converter), "AudioConverterDispose") }
    return (0, false)
}

func runExtAudioFile() throws -> (Int, Bool) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("codec-probe-\(UUID().uuidString).m4a")
    defer { try? FileManager.default.removeItem(at: url) }
    var destination = AudioStreamBasicDescription()
    destination.mSampleRate = 48_000
    destination.mFormatID = kAudioFormatMPEG4AAC
    destination.mChannelsPerFrame = 2
    var size = UInt32(MemoryLayout.size(ofValue: destination))
    try check(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &destination), "AAC format info")
    var file: ExtAudioFileRef?
    try check(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileM4AType, &destination, nil,
        AudioFileFlags.eraseFile.rawValue, &file), "ExtAudioFileCreateWithURL")
    guard let file else { throw NSError(domain: "Missing ExtAudioFile", code: 1) }
    var disposed = false
    defer { if !disposed { ExtAudioFileDispose(file) } }
    var source = pcmDescription()
    try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
        UInt32(MemoryLayout.size(ofValue: source)), &source), "ExtAudioFile client PCM format")
    var samples = [Int16](repeating: 0, count: 48_000 * 2)
    for frame in 0..<48_000 {
        let value: Int16 = pcmSample(at: Int64(frame))
        samples[frame * 2] = value
        samples[frame * 2 + 1] = value
    }
    let status = samples.withUnsafeMutableBytes { bytes -> OSStatus in
        var buffer = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
        return ExtAudioFileWrite(file, 48_000, &buffer)
    }
    try check(status, "ExtAudioFileWrite (1 s, 48 kHz stereo sine)")
    let closeStatus = ExtAudioFileDispose(file)
    disposed = true
    try check(closeStatus, "ExtAudioFileDispose")
    let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    let asset = AVURLAsset(url: url)
    return (bytes, asset.duration.seconds.isFinite && asset.duration.seconds > 0 && !asset.tracks.isEmpty)
}

guard CommandLine.arguments.count == 2 else {
    emit("Usage: codec-probe <list|case-name>", to: .standardError)
    exit(64)
}
let name = CommandLine.arguments[1]
if name == "list" {
    printEncoderList()
    printAudioDiagnostics()
    for name in cases.map(\.name) + extraCases { emit(name) }
    exit(0)
}
guard cases.contains(where: { $0.name == name }) || extraCases.contains(name) else {
    emit("Unknown case: \(name); use list", to: .standardError)
    exit(64)
}
emit("CASE \(name): START")
let done = DispatchSemaphore(value: 0)
let output = ResultBox()
DispatchQueue.global(qos: .userInitiated).async {
    output.set(Result {
        if name == "aac-converter-only" { return try runConverterOnly() }
        if name == "aac-extaudiofile" { return try runExtAudioFile() }
        return try run(cases.first { $0.name == name }!)
    })
    done.signal()
}
if done.wait(timeout: .now() + 15) == .timedOut {
    emit("CASE \(name): HANG (15 s watchdog)")
    exit(124)
}
switch output.get() {
case .success(let (bytes, readable)):
    if name == "aac-converter-only" {
        emit("CASE \(name): OK AudioConverter created, OSStatus=0")
    } else {
        emit("CASE \(name): OK \(bytes) bytes, readable=\(readable ? "yes" : "no")")
    }
    exit(0)
case .failure(let error):
    emit("CASE \(name): FAIL \(error)")
    exit(1)
case .none:
    emit("CASE \(name): FAIL missing result")
    exit(1)
}
