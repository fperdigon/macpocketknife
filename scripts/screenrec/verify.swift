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
@preconcurrency import AppKit
import Foundation

let palette: [[Double]] = [
    [1, 0, 0], [0, 1, 0], [0, 0, 1], [1, 1, 0], [1, 0, 1], [0, 1, 1],
    [1, 1, 1], [1, 128.0/255, 0], [128.0/255, 0, 1],
    [0, 128.0/255, 128.0/255], [1, 128.0/255, 192.0/255], [128.0/255, 1, 0]
]
let frequencies = (0..<12).map { Double(440 + 110 * $0) }
struct Event {
    let slot: Int
    let time: Double
}
struct Analysis {
    var video: [Event] = []
    var audio: [Event] = []
    var videoDuration = 0.0
    var audioDuration = 0.0
    var span = 0.0
    var rms = 0.0
    var peak = 0.0
    var hasVideo = false
    var hasAudio = false
}
func classify(_ rgb: [Double]) -> Int? {
    let distances = palette.map { color in
        zip(color, rgb).reduce(0.0) { $0 + pow($1.0 - $1.1, 2) }
    }
    let best = distances.indices.min(by: { distances[$0] < distances[$1] })!
    return distances[best] < 0.035 ? best : nil
}
func tone(_ samples: ArraySlice<Float>) -> Int? {
    let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
    guard energy / Double(samples.count) > 0.000225 else { return nil }
    let powers = frequencies.map { frequency -> Double in
        let coefficient = 2 * cos(2 * .pi * frequency / 48_000)
        var previous = 0.0
        var older = 0.0
        for sample in samples {
            let current = Double(sample) + coefficient * previous - older
            older = previous; previous = current
        }
        return previous * previous + older * older - coefficient * previous * older
    }
    let best = powers.indices.max(by: { powers[$0] < powers[$1] })!
    let fraction = 2 * powers[best] / (Double(samples.count) * energy)
    return fraction > 0.35 ? best : nil
}
func append(_ slot: Int?, at time: Double, to events: inout [Event]) {
    if let slot, events.last?.slot != slot { events.append(Event(slot: slot, time: time)) }
}
func reader(_ asset: AVAsset, track: AVAssetTrack, settings: [String: Any]) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else { throw reader.error! }
    return (reader, output)
}
func analyze(_ path: String) async throws -> Analysis {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    var result = Analysis()
    result.span = try await asset.load(.duration).seconds
    if let track = try await asset.loadTracks(withMediaType: .video).first {
        result.hasVideo = true
        result.videoDuration = try await track.load(.timeRange).duration.seconds
        let (reader, output) = try reader(asset, track: track,
            settings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        var next = -Double.infinity
        while let sample = output.copyNextSampleBuffer() {
            let time = sample.presentationTimeStamp.seconds
            guard time >= next, let buffer = sample.imageBuffer else { continue }
            next = time + 0.095
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            var rgb = [Double](repeating: 0, count: 3)
            var count = 0.0
            // A grid across the central half avoids the cursor, menu bar and letterboxing.
            for y in Swift.stride(from: height * 3 / 8, to: height * 5 / 8, by: 8) {
                for x in Swift.stride(from: width * 3 / 8, to: width * 5 / 8, by: 8) {
                    let offset = y * stride + x * 4
                    rgb[0] += Double(bytes[offset + 2]) / 255
                    rgb[1] += Double(bytes[offset + 1]) / 255
                    rgb[2] += Double(bytes[offset]) / 255
                    count += 1
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            append(classify(rgb.map { $0 / count }), at: time, to: &result.video)
        }
        if reader.status == .failed { throw reader.error! }
    }
    if let track = try await asset.loadTracks(withMediaType: .audio).first {
        result.hasAudio = true
        result.audioDuration = try await track.load(.timeRange).duration.seconds
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
        let (reader, output) = try reader(asset, track: track, settings: settings)
        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = sample.dataBuffer else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var decoded = [Float](repeating: 0, count: length / 4)
            let status = decoded.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            guard status == noErr else { throw NSError(domain: "PCM copy failed", code: Int(status)) }
            // Preserve the container timeline, including an initial audio delay or missing buffers.
            let position = max(0, Int((sample.presentationTimeStamp.seconds * 48_000).rounded()))
            guard position + decoded.count <= 48_000 * 310 else { throw NSError(domain: "Audio exceeds 310 seconds", code: 1) }
            if samples.count < position + decoded.count {
                samples.append(contentsOf: repeatElement(0, count: position + decoded.count - samples.count))
            }
            samples.replaceSubrange(position..<(position + decoded.count), with: decoded)
        }
        if reader.status == .failed { throw reader.error! }
        if !samples.isEmpty {
            let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
            result.rms = sqrt(energy / Double(samples.count))
            result.peak = Double(samples.map { abs($0) }.max() ?? 0)
        }
        for start in Swift.stride(from: 0, through: max(-1, samples.count - 4800), by: 4800) {
            append(tone(samples[start..<(start + 4800)]), at: Double(start) / 48_000 + 0.05, to: &result.audio)
        }
    }
    return result
}
func lcs(_ expected: [Event], _ observed: [Event]) -> Int {
    var row = [Int](repeating: 0, count: observed.count + 1)
    for event in expected {
        var next = row
        for index in observed.indices {
            next[index + 1] = event.slot == observed[index].slot ? row[index] + 1 : max(row[index + 1], next[index])
        }
        row = next
    }
    return row.last!
}
func describe(_ events: [Event]) -> String {
    events.map { String(format: "%d@%.3f", $0.slot, $0.time) }.joined(separator: " ")
}
func boundaries(_ events: [Event]) -> [String: Double] {
    var result: [String: Double] = [:]
    for index in events.indices.dropFirst() {
        let key = "\(events[index - 1].slot)->\(events[index].slot)"
        result[key] = events[index].time
    }
    return result
}
func verify(_ reference: Analysis, _ recording: Analysis, seconds: Double?) -> Bool {
    var passed = true
    func check(_ condition: Bool, _ description: String) {
        print("\(condition ? "PASS" : "FAIL") \(description)")
        if !condition { passed = false }
    }
    print("Reference video: \(describe(reference.video))")
    print("Reference audio: \(describe(reference.audio))")
    print("Observed video: \(describe(recording.video))")
    print("Observed audio: \(describe(recording.audio))")
    print(String(format: "Audio RMS=%.6f peak=%.6f", recording.rms, recording.peak))
    check(reference.video.count == 12 && reference.audio.count == 12, "reference has 12 colour and tone slots")
    check(recording.hasVideo, "video track exists")
    check(recording.hasAudio, "audio track exists")
    check(recording.rms > 0.015 && recording.peak > 0.04, "audio is not silent (RMS > 0.015, peak > 0.04)")
    if !recording.hasAudio || recording.rms <= 0.015 { print("AUDIO_NOT_CAPTURED") }
    let expectedSpan = seconds ?? recording.span
    let tolerance = max(1.5, expectedSpan * 0.15)
    let durations = [recording.videoDuration, recording.audioDuration, recording.span]
    let durationOK = durations.allSatisfy { $0.isFinite && $0 > 0 && abs($0 - expectedSpan) <= tolerance }
    let pairOK = abs(recording.videoDuration - recording.audioDuration) <= tolerance
    check(durationOK && pairOK, String(format: "durations video=%.3f audio=%.3f span=%.3f expected=%.3f tolerance=%.3f s",
        recording.videoDuration, recording.audioDuration, recording.span, expectedSpan, tolerance))
    for (name, expected, observed) in [("video", reference.video, recording.video), ("audio", reference.audio, recording.audio)] {
        let count = lcs(expected, observed)
        let minimum = max(5, Int(ceil(Double(observed.count) * 0.85)))
        check(count >= minimum, "\(name) ordered slots=\(count)/\(observed.count), required=\(minimum)")
    }
    let videoBoundaries = boundaries(recording.video)
    let audioBoundaries = boundaries(recording.audio)
    var offsets: [Double] = []
    for key in videoBoundaries.keys.sorted() {
        if let audio = audioBoundaries[key], let video = videoBoundaries[key] {
            let offset = video - audio
            offsets.append(abs(offset))
            print(String(format: "Boundary %@ video=%.3f audio=%.3f offset=%+.3f s", key, video, audio, offset))
        }
    }
    let mean = offsets.isEmpty ? Double.infinity : offsets.reduce(0, +) / Double(offsets.count)
    let maximum = offsets.max() ?? .infinity
    check(offsets.count >= 4 && maximum < 0.300,
          String(format: "A/V sync boundaries=%d mean=%.3f max=%.3f s (limit 0.300 s)", offsets.count, mean, maximum))
    return passed
}
func selftest() -> Bool {
    var passed = classify([0.4, 0.4, 0.4]) == nil
    for index in palette.indices {
        passed = passed && classify(palette[index]) == index
        let samples = (0..<4800).map { Float(0.35 * sin(2 * .pi * frequencies[index] * Double($0) / 48_000)) }
        passed = passed && tone(samples[...]) == index
    }
    passed = passed && tone([Float](repeating: 0, count: 4800)[...]) == nil
    let forward = (0..<12).map { Event(slot: $0, time: Double($0)) }
    passed = passed && lcs(forward, forward) == 12 && lcs(forward, forward.reversed()) == 1
    print("\(passed ? "PASS" : "FAIL") classifier, twelve tone detectors, silence, ordered matching")
    // Exercise the assertions independently of local encoder availability.
    var healthy = Analysis()
    healthy.video = forward
    healthy.audio = forward.map { Event(slot: $0.slot, time: $0.time + 0.05) }
    healthy.videoDuration = 12; healthy.audioDuration = 12; healthy.span = 12
    healthy.rms = 0.237; healthy.peak = 0.35
    healthy.hasVideo = true; healthy.hasAudio = true
    print("Selftest healthy control:")
    passed = verify(healthy, healthy, seconds: 12) && passed
    var silent = healthy
    silent.audio = []; silent.rms = 0; silent.peak = 0
    print("Selftest silent control (FAIL assertions expected):")
    passed = !verify(healthy, silent, seconds: 12) && passed
    var shuffled = healthy
    shuffled.video = forward.reversed()
    shuffled.audio = forward.reversed()
    print("Selftest shuffled control (FAIL assertions expected):")
    passed = !verify(healthy, shuffled, seconds: 12) && passed
    var delayed = healthy
    delayed.audio = forward.map { Event(slot: $0.slot, time: $0.time + 0.6) }
    print("Selftest desynchronized control (FAIL assertions expected):")
    passed = !verify(healthy, delayed, seconds: 12) && passed
    print("\(passed ? "PASS" : "FAIL") verifier selftest, including expected negative controls")
    return passed
}

do {
    let args = CommandLine.arguments
    if args.count == 2 && args[1] == "--selftest" { exit(selftest() ? 0 : 1) }
    guard args.count >= 3 else { throw NSError(domain: "Usage: verify <reference.mp4> <recording.mp4> [--seconds N] [--frames directory]", code: 2) }
    var seconds: Double?
    if let index = args.firstIndex(of: "--seconds") {
        guard index + 1 < args.count, let value = Double(args[index + 1]), value.isFinite, value > 0 else {
            throw NSError(domain: "Invalid --seconds", code: 2)
        }
        seconds = value
    }
    let reference = try await analyze(args[1])
    let recording = try await analyze(args[2])
    let passed = verify(reference, recording, seconds: seconds)
    if let index = args.firstIndex(of: "--frames"), index + 1 < args.count, recording.hasVideo {
        let directory = URL(fileURLWithPath: args[index + 1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let asset = AVURLAsset(url: URL(fileURLWithPath: args[2]))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        for second in [2, 5, 8] {
            if let generated = try? await generator.image(at: CMTime(value: Int64(second), timescale: 1)) {
                let bitmap = NSBitmapImageRep(cgImage: generated.image)
                try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("frame-\(second).png"))
            }
        }
    }
    exit(passed ? 0 : 1)
} catch {
    print("FAIL verifier: \(error)"); exit(1)
}
