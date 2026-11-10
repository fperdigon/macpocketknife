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

@preconcurrency import AppKit

/// Exercise the normal launch and termination delegate without launch prompts.
@MainActor
enum QuitSelfTest {
    static let isRequested = CommandLine.arguments.contains("--quit-selftest")
    private static var heartbeatCount = 0
    private static var heartbeatTimer: Timer?

    static func trace(_ label: String) {
        guard isRequested else { return }
        print("quit-selftest: trace \(label)")
        fflush(stdout)
    }

    static func runIfRequested() {
        guard isRequested else { return }
        print("quit-selftest: started")
        fflush(stdout)
        let heartbeat = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                heartbeatCount += 1
                print("quit-selftest: heartbeat \(heartbeatCount)")
                fflush(stdout)
                guard heartbeatCount == 2 else { return }
                heartbeatTimer?.invalidate()
                heartbeatTimer = nil
                print("quit-selftest: requesting normal termination")
                fflush(stdout)
                NSApp.terminate(nil)
            }
        }
        heartbeatTimer = heartbeat
        RunLoop.main.add(heartbeat, forMode: .common)
    }
}
