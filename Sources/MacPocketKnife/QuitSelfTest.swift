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

/// Exercise the normal launch and termination delegate without recording permissions.
@MainActor
enum QuitSelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--quit-selftest") else { return }
        print("quit-selftest: started")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            print("quit-selftest: requesting normal termination")
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }
}
