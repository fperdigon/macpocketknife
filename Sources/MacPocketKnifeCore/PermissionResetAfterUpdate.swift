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

@preconcurrency import Foundation

public protocol PermissionResetBuildStoring: Sendable {
    var lastBuildID: String? { get }
    func store(buildID: String)
}

/// Accessed serially by the launch reset task; UserDefaults is thread safe.
public final class UserDefaultsPermissionResetStore: PermissionResetBuildStoring, @unchecked Sendable {
    public static let key = "lastPermissionResetBuildID"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var lastBuildID: String? { defaults.string(forKey: Self.key) }
    public func store(buildID: String) { defaults.set(buildID, forKey: Self.key) }
}

/// Run once at launch, before making capture controllers or registering hotkeys.
public struct PermissionResetAfterUpdate: Sendable {
    public static let bundleIdentifier = "io.github.fperdigon.macpocketknife"
    public static let services = ["Microphone", "ScreenCapture", "SpeechRecognition"]
    private let processes: any UpdateProcessRunning
    private let storage: any PermissionResetBuildStoring
    private let buildID: @Sendable () throws -> String
    private let logger: AppLogger

    public init(
        processes: any UpdateProcessRunning = UpdateProcessRunner(timeout: 10),
        storage: any PermissionResetBuildStoring = UserDefaultsPermissionResetStore(),
        buildID: @escaping @Sendable () throws -> String = PermissionResetAfterUpdate.currentBuildID,
        logger: AppLogger = AppLog.shared
    ) {
        self.processes = processes
        self.storage = storage
        self.buildID = buildID
        self.logger = logger
    }

    public static func shouldReset(storedBuildID: String?, currentBuildID: String) -> Bool {
        !currentBuildID.isEmpty && storedBuildID != currentBuildID
    }

    public static func isTestOrCI(environment: [String: String], arguments: [String]) -> Bool {
        environment["CI"] != nil || environment["GITHUB_ACTIONS"] != nil
            || environment["XCTestConfigurationFilePath"] != nil
            || arguments.contains { $0.contains(".xctest") || $0.contains("swiftpm-testing-helper") }
    }

    public static func currentBuildID() throws -> String {
        guard let executable = Bundle.main.executableURL else { throw CocoaError(.fileReadNoSuchFile) }
        return try LocalUpdateFileSystem().sha256(of: executable)
    }

    /// Returns true if at least one reset succeeded. Failures never prevent launch
    /// or cause repeated reset attempts on subsequent launches of the same build.
    public func run(
        enabled: Bool, channel: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> Bool {
        guard enabled, channel != "dev",
              !Self.isTestOrCI(environment: environment, arguments: arguments) else { return false }
        let current: String
        do { current = try buildID() }
        catch {
            logger.warning(category: "permission", "Permission reset skipped category=buildID")
            return false
        }
        guard Self.shouldReset(storedBuildID: storage.lastBuildID, currentBuildID: current) else { return false }
        var didReset = false
        for service in Self.services {
            do {
                try processes.run("/usr/bin/tccutil", arguments: ["reset", service, Self.bundleIdentifier])
                didReset = true
                logger.info(category: "permission", "Reset permissions after update service=\(service)")
            } catch {
                logger.warning(category: "permission", "Permission reset failed service=\(service)")
            }
        }
        storage.store(buildID: current)
        return didReset
    }
}
