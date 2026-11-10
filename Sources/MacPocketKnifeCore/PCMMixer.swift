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

/// Sparse stereo PCM accumulator. Call drain regularly against the newest source
/// timestamp, regardless of which source delivered it. Already drained audio is immutable.
public struct PCMMixer: Sendable {
    private var blocks: [Int: [Float]] = [:]
    public private(set) var position: Int = 0
    public private(set) var endPosition: Int = 0
    /// Source frames discarded because their timeline has already been drained.
    public private(set) var droppedFrameCount: Int = 0
    public var bufferedFrameCapacity: Int { blocks.count * 1024 }

    public init() {}

    /// Returns the number of frames retained, preserving the timestamp of any suffix.
    @discardableResult
    public mutating func add(_ samples: [Float], at frame: Int) -> Int {
        let count = samples.count / 2
        guard count > 0 else { return 0 }
        let end = frame + count
        let dropped = min(count, max(0, position - frame))
        droppedFrameCount += dropped
        guard end > position else { return 0 }
        endPosition = max(endPosition, end)
        for index in max(position, frame)..<end {
            let key = index / 1024
            let offset = (index % 1024) * 2
            let source = (index - frame) * 2
            if blocks[key] == nil { blocks[key] = [Float](repeating: 0, count: 2048) }
            blocks[key]![offset] += samples[source]
            blocks[key]![offset + 1] += samples[source + 1]
        }
        return count - dropped
    }

    /// Returns at most maxFrames, filling timeline gaps with silence. Clamp only
    /// after all sources have summed, so opposite polarities cancel correctly.
    public mutating func drain(upTo frame: Int, maxFrames: Int = 1024) -> [Float] {
        let count = min(max(0, frame - position), max(0, maxFrames))
        guard count > 0 else { return [] }
        var result = [Float](repeating: 0, count: count * 2)
        var index = 0
        while index < count {
            let absolute = position + index
            let key = absolute / 1024
            let offset = absolute % 1024
            let length = min(count - index, 1024 - offset)
            if let block = blocks[key] {
                for channel in 0..<(length * 2) {
                    result[index * 2 + channel] = min(1, max(-1, block[offset * 2 + channel]))
                }
            }
            if offset + length == 1024 { blocks.removeValue(forKey: key) }
            index += length
        }
        position += count
        if position >= endPosition { blocks.removeAll(keepingCapacity: true) }
        return result
    }
}
