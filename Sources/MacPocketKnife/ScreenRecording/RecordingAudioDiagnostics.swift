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

/// Queue-confined, opt-in selftest observations; never logs in product recordings.
struct RecordingAudioDiagnostics {
    var buffers = 0
    var converted = 0
    var conversionNil = 0
    var addedFrames = 0
    var droppedFrames = 0
    private var format = "none"
    private var minimumPTS = Double.infinity
    private var maximumPTS = -Double.infinity
    private var maximumHostLag = -Double.infinity
    private var peak = 0.0
    private var sumSquares = 0.0
    private var sampleCount = 0

    mutating func receive(_ sample: CMSampleBuffer) {
        buffers += 1
        if buffers == 1, let description = sample.formatDescription,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            format = "rate=\(asbd.mSampleRate) channels=\(asbd.mChannelsPerFrame) id=\(asbd.mFormatID) flags=\(asbd.mFormatFlags) bits=\(asbd.mBitsPerChannel) bytesPerFrame=\(asbd.mBytesPerFrame)"
        }
        let pts = sample.presentationTimeStamp.seconds
        if pts.isFinite {
            minimumPTS = min(minimumPTS, pts)
            maximumPTS = max(maximumPTS, pts)
            let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            maximumHostLag = max(maximumHostLag, host - pts)
        }
    }

    mutating func conversion(_ samples: [Float]?) {
        guard let samples else { conversionNil += 1; return }
        converted += 1
        for sample in samples {
            let value = Double(sample)
            peak = max(peak, abs(value))
            sumSquares += value * value
        }
        sampleCount += samples.count
    }

    func report(name: String, firstVideoTime: CMTime?) -> String {
        let base = firstVideoTime?.seconds ?? .nan
        let minimum = minimumPTS.isFinite ? minimumPTS - base : .nan
        let maximum = maximumPTS.isFinite ? maximumPTS - base : .nan
        let rms = sampleCount > 0 ? sqrt(sumSquares / Double(sampleCount)) : 0
        return "MIC-DEBUG \(name) buffers=\(buffers) convertedOK=\(converted) convertedNil=\(conversionNil) ASBD[\(format)]\n"
            + "MIC-DEBUG \(name) ptsMinusFirstVideoMin=\(minimum) max=\(maximum) maxHostMinusPTS=\(maximumHostLag) seconds addedFrames=\(addedFrames) droppedBehindPosition=\(droppedFrames) peak=\(peak) rms=\(rms)\n"
    }
}
