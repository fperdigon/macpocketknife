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

/// Decides whether the hidden CI self-test launch flags may run. Pure and side-effect free.
public enum SelfTestGate {
    public static let environmentKey = "MACPOCKETKNIFE_SELFTEST"
    public static let directoryKey = "MACPOCKETKNIFE_SELFTEST_DIR"
    public static let maximumRecordingSeconds: Double = 60

    /// True only when the explicit opt-in variable is exactly "1".
    public static func isEnabled(environment: [String: String]) -> Bool {
        environment[environmentKey] == "1"
    }

    /// Roots under which self-test output may be written: the temporary directory
    /// and, when set, the directory the CI script provides.
    public static func allowedRoots(environment: [String: String], temporaryDirectory: String) -> [URL] {
        var roots = [URL(fileURLWithPath: temporaryDirectory, isDirectory: true)]
        if let extra = environment[directoryKey], !extra.isEmpty {
            roots.append(URL(fileURLWithPath: extra, isDirectory: true))
        }
        return roots
    }

    /// True when `path` lies strictly inside one of `roots` after resolving symlinks and `..`.
    public static func isPathAllowed(_ path: String, roots: [URL]) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let target = resolved(URL(fileURLWithPath: path))
        for root in roots {
            let base = resolved(root).path
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if target.path.hasPrefix(prefix) { return true }
        }
        return false
    }

    /// Returns the duration when it is finite and within (0, maximumRecordingSeconds], else nil.
    public static func validatedDuration(_ seconds: Double) -> Double? {
        guard seconds.isFinite, seconds > 0, seconds <= maximumRecordingSeconds else { return nil }
        return seconds
    }

    // Resolve symlinks through the deepest existing ancestor so not-yet-created files compare correctly.
    private static func resolved(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            tail.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var result = existing.resolvingSymlinksInPath()
        for part in tail { result.appendPathComponent(part) }
        return result.standardizedFileURL
    }
}
