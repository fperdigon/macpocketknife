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

import Foundation
import Testing
@testable import MacPocketKnifeCore

@Suite struct SelfTestGateTests {
    @Test func deniedWithoutEnvironmentVariable() {
        #expect(!SelfTestGate.isEnabled(environment: [:]))
        #expect(!SelfTestGate.isEnabled(environment: [SelfTestGate.environmentKey: "0"]))
        #expect(!SelfTestGate.isEnabled(environment: [SelfTestGate.environmentKey: "true"]))
        #expect(SelfTestGate.isEnabled(environment: [SelfTestGate.environmentKey: "1"]))
    }

    @Test func pathsInsideTemporaryDirectoryAreAllowed() {
        let roots = SelfTestGate.allowedRoots(environment: [:], temporaryDirectory: NSTemporaryDirectory())
        #expect(SelfTestGate.isPathAllowed(NSTemporaryDirectory() + "new/out.mp4", roots: roots))
    }

    @Test func pathsOutsideOrEscapingAreDenied() {
        let roots = SelfTestGate.allowedRoots(environment: [:], temporaryDirectory: NSTemporaryDirectory())
        #expect(!SelfTestGate.isPathAllowed("/Users/someone/out.mp4", roots: roots))
        #expect(!SelfTestGate.isPathAllowed("relative/out.mp4", roots: roots))
        #expect(!SelfTestGate.isPathAllowed(NSTemporaryDirectory() + "../escape.mp4", roots: roots))
        #expect(!SelfTestGate.isPathAllowed(NSTemporaryDirectory(), roots: roots))
    }

    @Test func scriptDirectoryIsAllowedWhenProvided() {
        let env = [SelfTestGate.directoryKey: "/var/ci-work"]
        let roots = SelfTestGate.allowedRoots(environment: env, temporaryDirectory: NSTemporaryDirectory())
        #expect(SelfTestGate.isPathAllowed("/var/ci-work/rec.mp4", roots: roots))
        #expect(!SelfTestGate.isPathAllowed("/var/ci-work-evil/rec.mp4", roots: roots))
    }

    @Test func durationIsCapped() {
        #expect(SelfTestGate.validatedDuration(30) == 30)
        #expect(SelfTestGate.validatedDuration(60) == 60)
        #expect(SelfTestGate.validatedDuration(61) == nil)
        #expect(SelfTestGate.validatedDuration(0) == nil)
        #expect(SelfTestGate.validatedDuration(.infinity) == nil)
        #expect(SelfTestGate.validatedDuration(.nan) == nil)
    }
}
