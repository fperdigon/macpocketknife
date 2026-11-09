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

let halfChannel: Double = 128.0 / 255.0
let threeQuarterChannel: Double = 192.0 / 255.0
let palette: [[Double]] = [
    [1, 0, 0], [0, 1, 0], [0, 0, 1], [1, 1, 0], [1, 0, 1], [0, 1, 1],
    [1, 1, 1], [1, halfChannel, 0], [halfChannel, 0, 1],
    [0, halfChannel, halfChannel], [1, halfChannel, threeQuarterChannel], [halfChannel, 1, 0]
]
func frequency(for slot: Int) -> Double {
    let offset: Int = 110 * slot
    let hertz: Int = 440 + offset
    return Double(hertz)
}
let frequencies: [Double] = (0..<12).map { frequency(for: $0) }
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
func colorDistance(_ color: [Double], _ rgb: [Double]) -> Double {
    var distance: Double = 0.0
    for (channel, observed) in zip(color, rgb) {
        let difference: Double = channel - observed
        let squared: Double = pow(difference, 2.0)
        distance += squared
    }
    return distance
}
func classify(_ rgb: [Double]) -> Int? {
    let distances: [Double] = palette.map { colorDistance($0, rgb) }
    let best = distances.indices.min(by: { distances[$0] < distances[$1] })!
    return distances[best] < 0.035 ? best : nil
}
func sampleEnergy(_ samples: ArraySlice<Float>) -> Double {
    var energy: Double = 0.0
    for sample in samples {
        let value: Double = Double(sample)
        let squared: Double = value * value
        energy += squared
    }
    return energy
}
func tonePower(_ samples: ArraySlice<Float>, frequency: Double) -> Double {
    let angularScale: Double = 2.0 * Double.pi
    let angularFrequency: Double = angularScale * frequency
    let phase: Double = angularFrequency / 48_000.0
    let coefficient: Double = 2.0 * cos(phase)
    var previous: Double = 0.0
    var older: Double = 0.0
    for sample in samples {
        let feedback: Double = coefficient * previous
        let sum: Double = Double(sample) + feedback
        let current: Double = sum - older
        older = previous
        previous = current
    }
    let previousSquared: Double = previous * previous
    let olderSquared: Double = older * older
    let squaredSum: Double = previousSquared + olderSquared
    let weightedPrevious: Double = coefficient * previous
    let crossTerm: Double = weightedPrevious * older
    return squaredSum - crossTerm
}
func tone(_ samples: ArraySlice<Float>) -> Int? {
    let energy: Double = sampleEnergy(samples)
    let sampleCount: Double = Double(samples.count)
    let meanEnergy: Double = energy / sampleCount
    guard meanEnergy > 0.000225 else { return nil }
    let powers: [Double] = frequencies.map { tonePower(samples, frequency: $0) }
    let best = powers.indices.max(by: { powers[$0] < powers[$1] })!
    let numerator: Double = 2.0 * powers[best]
    let denominator: Double = sampleCount * energy
    let fraction: Double = numerator / denominator
    return fraction > 0.35 ? best : nil
}
func toneSample(frequency: Double, position: Int) -> Float {
    let angularScale: Double = 2.0 * Double.pi
    let angularFrequency: Double = angularScale * frequency
    let phaseNumerator: Double = angularFrequency * Double(position)
    let phase: Double = phaseNumerator / 48_000.0
    let amplitude: Double = 0.35 * sin(phase)
    return Float(amplitude)
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
            let samplePosition: Double = sample.presentationTimeStamp.seconds * 48_000.0
            let roundedPosition: Double = samplePosition.rounded()
            let position: Int = max(0, Int(roundedPosition))
            guard position + decoded.count <= 48_000 * 310 else { throw NSError(domain: "Audio exceeds 310 seconds", code: 1) }
            if samples.count < position + decoded.count {
                samples.append(contentsOf: repeatElement(0, count: position + decoded.count - samples.count))
            }
            samples.replaceSubrange(position..<(position + decoded.count), with: decoded)
        }
        if reader.status == .failed { throw reader.error! }
        if !samples.isEmpty {
            let energy: Double = sampleEnergy(samples[...])
            let meanEnergy: Double = energy / Double(samples.count)
            result.rms = sqrt(meanEnergy)
            result.peak = Double(samples.map { abs($0) }.max() ?? 0)
        }
        for start in Swift.stride(from: 0, through: max(-1, samples.count - 4800), by: 4800) {
            let startTime: Double = Double(start) / 48_000.0
            let centerTime: Double = startTime + 0.05
            append(tone(samples[start..<(start + 4800)]), at: centerTime, to: &result.audio)
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
func verify(_ reference: Analysis, _ recording: Analysis, seconds: Double?, strictDurations: Bool = false) -> Bool {
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
    let relativeTolerance: Double = expectedSpan * 0.15
    let tolerance: Double = max(1.5, relativeTolerance)
    let durations: [Double] = [recording.audioDuration, recording.span]
    let durationOK: Bool = durations.allSatisfy { $0.isFinite && $0 > 0 && abs($0 - expectedSpan) <= tolerance }
    let minimumVideo: Double = recording.audioDuration * 0.60
    let maximumVideo: Double = recording.audioDuration + 1.5
    var videoOK: Bool = recording.videoDuration.isFinite
        && recording.videoDuration >= minimumVideo && recording.videoDuration <= maximumVideo
    if strictDurations {
        let expectedVideoOK: Bool = abs(recording.videoDuration - expectedSpan) <= tolerance
        let pairOK: Bool = abs(recording.videoDuration - recording.audioDuration) <= tolerance
        videoOK = recording.videoDuration.isFinite && recording.videoDuration > 0 && expectedVideoOK && pairOK
    }
    check(durationOK && videoOK, String(format: "durations video=%.3f audio=%.3f span=%.3f expected=%.3f tolerance=%.3f s",
        recording.videoDuration, recording.audioDuration, recording.span, expectedSpan, tolerance))
    if !strictDurations {
        print(String(format: "Recording video duration limits: minimum=%.3f maximum=%.3f s", minimumVideo, maximumVideo))
    }
    for (name, expected, observed) in [("video", reference.video, recording.video), ("audio", reference.audio, recording.audio)] {
        let count = lcs(expected, observed)
        let requiredCount: Double = Double(observed.count) * 0.85
        let roundedCount: Double = ceil(requiredCount)
        let minimum: Int = max(5, Int(roundedCount))
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
    let totalOffset: Double = offsets.reduce(0.0, +)
    let mean: Double = offsets.isEmpty ? Double.infinity : totalOffset / Double(offsets.count)
    let maximum = offsets.max() ?? .infinity
    check(offsets.count >= 4 && maximum < 0.300,
          String(format: "A/V sync boundaries=%d mean=%.3f max=%.3f s (limit 0.300 s)", offsets.count, mean, maximum))
    return passed
}
func selftest() -> Bool {
    var passed = classify([0.4, 0.4, 0.4]) == nil
    for index in palette.indices {
        passed = passed && classify(palette[index]) == index
        let samples: [Float] = (0..<4800).map { toneSample(frequency: frequencies[index], position: $0) }
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
    passed = verify(healthy, healthy, seconds: 12, strictDurations: true) && passed
    var silent = healthy
    silent.audio = []; silent.rms = 0; silent.peak = 0
    print("Selftest silent control (FAIL assertions expected):")
    passed = !verify(healthy, silent, seconds: 12, strictDurations: true) && passed
    var shuffled = healthy
    shuffled.video = forward.reversed()
    shuffled.audio = forward.reversed()
    print("Selftest shuffled control (FAIL assertions expected):")
    passed = !verify(healthy, shuffled, seconds: 12, strictDurations: true) && passed
    var delayed = healthy
    delayed.audio = forward.map { Event(slot: $0.slot, time: $0.time + 0.6) }
    print("Selftest desynchronized control (FAIL assertions expected):")
    passed = !verify(healthy, delayed, seconds: 12, strictDurations: true) && passed
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
    let passed = verify(reference, recording, seconds: seconds, strictDurations: args[1] == args[2])
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
