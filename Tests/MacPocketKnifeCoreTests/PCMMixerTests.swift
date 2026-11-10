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

import MacPocketKnifeCore
import Testing

struct PCMMixerTests {
    @Test func sumsClampsAndPreservesStereo() {
        var mixer = PCMMixer()
        mixer.add([0.8, -0.8, 0.1, 0.2], at: 0)
        mixer.add([0.7, -0.7, -0.3, 0.4], at: 0)
        let samples = mixer.drain(upTo: 2)
        #expect(samples[0] == 1)
        #expect(samples[1] == -1)
        #expect(abs(samples[2] + 0.2) < 0.00001)
        #expect(abs(samples[3] - 0.6) < 0.00001)
        #expect(mixer.bufferedFrameCapacity == 0)
    }

    @Test func jitterGapsLateFramesAndFlush() {
        var mixer = PCMMixer()
        mixer.add([0.5, 0.5], at: 4)
        mixer.add([0.2, 0.3], at: 2)
        mixer.add([], at: 20)
        #expect(mixer.drain(upTo: 0).isEmpty)
        #expect(mixer.drain(upTo: 5, maxFrames: 0).isEmpty)
        #expect(mixer.drain(upTo: 3) == [0, 0, 0, 0, 0.2, 0.3])
        // A late overlapping buffer contributes only its undrained suffix.
        mixer.add([1, 1, 0.1, 0.1], at: 2)
        mixer.add([1, 1], at: 0)
        #expect(mixer.endPosition == 5)
        #expect(mixer.drain(upTo: mixer.endPosition) == [0.1, 0.1, 0.5, 0.5])
        #expect(mixer.drain(upTo: mixer.endPosition).isEmpty)
        #expect(mixer.bufferedFrameCapacity == 0)
        mixer.add([0.4, 0.4], at: 5)
        #expect(mixer.drain(upTo: 6) == [0.4, 0.4])
    }

    @Test func cancellationHappensBeforeClampAndNegativePrefixIsDropped() {
        var mixer = PCMMixer()
        mixer.add([1, 1, 1, 1], at: -1)
        mixer.add([1, 1], at: 0)
        mixer.add([-1, -1], at: 0)
        #expect(mixer.drain(upTo: 1) == [1, 1])
    }

    @Test func countsOnlyDiscardedFramesAndKeepsOverlappingSuffix() {
        var mixer = PCMMixer()
        #expect(mixer.add([], at: -20) == 0)
        #expect(mixer.droppedFrameCount == 0)
        #expect(mixer.add([0.9, 0.8, 0.1, 0.2], at: -1) == 1)
        #expect(mixer.droppedFrameCount == 1)
        #expect(mixer.drain(upTo: 1) == [0.1, 0.2])
        #expect(mixer.add([1, 1], at: -5) == 0)
        #expect(mixer.droppedFrameCount == 2)
        #expect(mixer.add([1, 1, 0.3, 0.4, 0.5, 0.6], at: 0) == 2)
        #expect(mixer.droppedFrameCount == 3)
        #expect(mixer.drain(upTo: 3) == [0.3, 0.4, 0.5, 0.6])
        #expect(mixer.add([0.7, 0.8], at: 3) == 1)
        #expect(mixer.droppedFrameCount == 3)
        #expect(mixer.drain(upTo: 4) == [0.7, 0.8])
    }

    @Test func absentSourceAndTwoHourTimelineHaveBoundedStorage() {
        var mixer = PCMMixer()
        let samples = [Float](repeating: 0.25, count: 2048)
        // Two hours of timestamps with sparse packets: silence never allocates blocks.
        for second in 0..<(2 * 60 * 60) {
            let position = second * 48_000
            mixer.add(samples, at: position)
            #expect(mixer.bufferedFrameCapacity <= 2048)
            while mixer.position < position + 1024 {
                let drained = mixer.drain(upTo: position + 1024, maxFrames: 48_000)
                #expect(drained.count <= 96_000)
            }
            #expect(mixer.bufferedFrameCapacity == 0)
        }
        #expect(mixer.position == 7199 * 48_000 + 1024)
    }

    @Test func continuousSourcesRetainOnlyTheDrainWindow() {
        var mixer = PCMMixer()
        let samples = [Float](repeating: 0.1, count: 2048)
        for packet in 0..<2000 {
            let position = packet * 1024
            mixer.add(samples, at: position)
            if packet % 3 == 0 { mixer.add(samples, at: position - 100) }
            while mixer.position < mixer.endPosition - 12_000 {
                _ = mixer.drain(upTo: mixer.endPosition - 12_000)
            }
            #expect(mixer.bufferedFrameCapacity <= 14_336)
        }
        while mixer.position < mixer.endPosition { _ = mixer.drain(upTo: mixer.endPosition) }
        #expect(mixer.bufferedFrameCapacity == 0)
    }
}
