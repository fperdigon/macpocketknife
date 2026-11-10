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

/// Queue-confined converters preserve resampler state separately for each source.
final class RecordingPCMConverter {
    private var converters: [Int: AVAudioConverter] = [:]

    func samples(_ sample: CMSampleBuffer, source: Int) -> [Float]? {
        guard let description = sample.formatDescription else { return nil }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: description)
        guard
              inputFormat.channelCount == 1 || inputFormat.channelCount == 2,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat,
                  frameCapacity: AVAudioFrameCount(sample.numSamples)) else { return nil }
        input.frameLength = AVAudioFrameCount(sample.numSamples)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
            frameCount: Int32(sample.numSamples), into: input.mutableAudioBufferList) == noErr else { return nil }
        let channels = inputFormat.channelCount
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000, channels: channels, interleaved: false) else { return nil }
        if converters[source]?.inputFormat != inputFormat {
            converters[source] = AVAudioConverter(from: inputFormat, to: target)
        }
        guard let converter = converters[source] else { return nil }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 48_000 / inputFormat.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, let data = output.floatChannelData else { return nil }
        var result = [Float](repeating: 0, count: Int(output.frameLength) * 2)
        for frame in 0..<Int(output.frameLength) {
            result[frame * 2] = data[0][frame]
            result[frame * 2 + 1] = data[channels == 1 ? 0 : 1][frame]
        }
        return result
    }

    static func buffer(_ samples: [Float], time: CMTime) -> CMSampleBuffer? {
        var format = AudioStreamBasicDescription(mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description) == noErr,
            let description else { return nil }
        let length = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: length,
            flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: description, sampleCount: samples.count / 2,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result) == noErr else { return nil }
        return result
    }
}
