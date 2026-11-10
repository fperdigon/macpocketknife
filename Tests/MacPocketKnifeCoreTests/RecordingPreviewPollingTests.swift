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

struct RecordingPreviewPollingTests {
    @Test func ticksAllowOnlyOneCapturePerDisplayAndKeepLoadedStateUntilNextTick() {
        var polling = RecordingPreviewPolling()
        #expect(!polling.shouldPoll)
        #expect(polling.begin("a") == false)
        polling.start(displayIDs: ["a", "b", "a"])
        #expect(polling.states == ["a": .idle, "b": .idle])
        #expect(polling.shouldPoll)
        #expect(polling.begin("missing") == false)
        #expect(polling.begin("a") == true)
        #expect(polling.isLoading)
        #expect(polling.begin("a") == false)
        #expect(polling.begin("b") == true)
        polling.complete("a", succeeded: true)
        #expect(polling.states["a"] == .loaded)
        polling.complete("b", succeeded: true)
        #expect(!polling.isLoading)
        #expect(polling.begin("a") == true)
    }

    @Test func firstFailureStopsAllPollingAndWindowKeyResumesIt() {
        var polling = RecordingPreviewPolling()
        polling.start(displayIDs: ["a", "b"])
        #expect(polling.begin("a") == true)
        #expect(polling.begin("b") == true)
        polling.complete("a", succeeded: false)
        #expect(polling.isDenied)
        #expect(!polling.shouldPoll)
        #expect(polling.begin("a") == false)
        polling.complete("b", succeeded: true)
        #expect(polling.begin("b") == false)
        polling.resume()
        #expect(!polling.isDenied)
        #expect(polling.states["a"] == .idle)
        #expect(polling.states["b"] == .loaded)
        #expect(polling.shouldPoll)
        #expect(polling.begin("a") == true)
        polling.resume()
        #expect(polling.begin("a") == false)
    }

    @Test func closeIgnoresLateResultsAndActivationUntilReopened() {
        var polling = RecordingPreviewPolling()
        polling.start(displayIDs: ["a"])
        #expect(polling.begin("a") == true)
        polling.stop()
        polling.complete("a", succeeded: false)
        polling.resume()
        #expect(polling.states.isEmpty)
        #expect(!polling.isActive)
        #expect(!polling.isDenied)
        #expect(!polling.shouldPoll)
        #expect(polling.begin("a") == false)
        polling.start(displayIDs: [])
        #expect(!polling.shouldPoll)
        polling.start(displayIDs: ["b"])
        polling.complete("missing", succeeded: false)
        polling.complete("b", succeeded: false)
        #expect(!polling.isDenied)
        #expect(polling.begin("b") == true)
    }
}
