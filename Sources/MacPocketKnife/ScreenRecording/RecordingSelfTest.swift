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
@preconcurrency import CoreGraphics
import MacPocketKnifeCore

/// Hidden CLI entry point. No settings, permission prompts or product UI are initialized.
@MainActor
enum RecordingSelfTest {
    static private(set) var microphoneDiagnosticsEnabled = false
    private static var resultFile: URL?

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.contains("--record-selftest") else { return }
        microphoneDiagnosticsEnabled = true
        var includesMicrophone = false
        var index = 4
        while index < args.count {
            switch args[index] {
            case "--mic" where !includesMicrophone:
                includesMicrophone = true
            case "--result-file" where resultFile == nil && index + 1 < args.count:
                index += 1
                resultFile = URL(fileURLWithPath: args[index])
            default:
                fail("Unknown or incomplete option: \(args[index])", code: 2)
            }
            index += 1
        }
        guard args.count >= 4,
              args[1] == "--record-selftest", let seconds = Double(args[3]),
              seconds.isFinite, seconds > 0, seconds <= 300 else {
            fail("Usage: MacPocketKnife --record-selftest <output.mp4> <seconds> [0 < seconds <= 300] [--mic] [--result-file <path>]", code: 2)
        }
        let destination = URL(fileURLWithPath: args[2])
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            fail("Output already exists: \(destination.path)", code: 2)
        }
        // Preflight only: the harness must never grant permission on a developer machine.
        guard CGPreflightScreenCaptureAccess() else {
            fail("PERMISSION DENIED: Allow Screen Recording for the ScreenRecTest bundle in System Settings, then relaunch.", code: 10)
        }
        Task { @MainActor in
            let recorder = ScreenCaptureKitRecorder()
            recorder.onFailure = { failure in
                fail("Capture failed: \(failure?.message ?? "sharing stopped before the requested duration")", code: 1)
            }
            do {
                let configuration = ScreenRecordingConfiguration(
                    frameRate: 30, showsCursor: false, includesMicrophone: includesMicrophone
                )
                let outcome = try await recorder.start(configuration: configuration, destination: destination, display: nil, content: nil)
                if includesMicrophone && outcome != .included {
                    _ = try? await recorder.stop()
                    fail(outcome.notice ?? "Microphone was not included.", code: 1)
                }
                print(String(format: "RECORDING_STARTED %.9f", Date().timeIntervalSince1970))
                fflush(stdout)
                try await Task.sleep(for: .seconds(seconds))
                guard let file = try await recorder.stop(),
                      FileManager.default.fileExists(atPath: file.path),
                      (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else {
                    fail("Capture failed: no recording file was written.", code: 1)
                }
                print("RECORDING_SAVED \(file.path)")
                finish(code: 0)
            } catch {
                _ = try? await recorder.stop()
                fail("Capture failed: \(error)", code: 1)
            }
        }
        // Dispatch the async capture on the main actor without constructing NSApplication.
        dispatchMain()
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data(("record-selftest: " + message + "\n").utf8))
        finish(code: code, message: message)
    }

    private static func finish(code: Int32, message: String? = nil) -> Never {
        if let resultFile {
            let detail = message.map { " " + $0.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") } ?? ""
            do {
                try "exit=\(code)\(detail)\n".write(to: resultFile, atomically: true, encoding: .utf8)
            } catch {
                FileHandle.standardError.write(Data(("record-selftest: Cannot write result file: \(error)\n").utf8))
            }
        }
        exit(code)
    }
}
