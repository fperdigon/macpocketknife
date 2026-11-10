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

import CryptoKit
@preconcurrency import Foundation
import Darwin

public enum UpdateInstallError: Error, Equatable, Sendable, LocalizedError {
    case downloadFailed(Int)
    case checksumMismatch
    case invalidDigest
    case invalidBundle
    case signatureInvalid
    case operationFailed

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let status): return "The update download failed (HTTP \(status))."
        case .checksumMismatch: return "The download does not match GitHub's SHA-256 digest. Installation was refused."
        case .invalidDigest: return "GitHub reported an unsupported or invalid digest."
        case .invalidBundle: return "The update does not contain an app with the running app's bundle identifier."
        case .signatureInvalid: return "The update's code signature could not be verified."
        case .operationFailed: return "The update could not be installed. Check that the app's folder is writable and try again."
        }
    }
}

public protocol UpdateDownloading: Sendable {
    func download(_ asset: ReleaseAsset, to directory: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

/// All installation side effects are replaceable in deterministic tests.
public protocol UpdateFileSystem: Sendable {
    func sha256(of file: URL) throws -> String
    func createDirectory(_ directory: URL) throws
    func remove(_ url: URL) throws
    func copy(_ source: URL, to destination: URL) throws
    func bundleIdentifier(at app: URL) -> String?
    func replace(_ current: URL, with staged: URL, backupName: String) throws
    func restore(_ current: URL, from backup: URL) throws
}

public protocol UpdateProcessRunning: Sendable {
    func run(_ executable: String, arguments: [String]) throws
}

public struct UpdateInstaller: Sendable {
    private let files: any UpdateFileSystem
    private let processes: any UpdateProcessRunning

    public init(files: any UpdateFileSystem = LocalUpdateFileSystem(),
                processes: any UpdateProcessRunning = UpdateProcessRunner()) {
        self.files = files
        self.processes = processes
    }

    public func verify(file: URL, expected: String?) throws {
        guard let expected else { return }
        let digest = expected.lowercased()
        guard digest.hasPrefix("sha256:"), digest.count == 71,
              digest.dropFirst(7).allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw UpdateInstallError.invalidDigest
        }
        guard try files.sha256(of: file) == String(digest.dropFirst(7)) else {
            throw UpdateInstallError.checksumMismatch
        }
    }

    /// Stage on the destination volume, validate, atomically swap, and keep the backup
    /// until the installed copy has passed validation. Every mount attempt is detached.
    public func install(dmg: URL, expectedDigest: String?, over current: URL, work: URL) throws {
        try verify(file: dmg, expected: expectedDigest)
        guard current.pathExtension == "app", let identifier = files.bundleIdentifier(at: current) else {
            throw UpdateInstallError.invalidBundle
        }
        let mount = work.appendingPathComponent("mount")
        let staging = current.deletingLastPathComponent().appendingPathComponent(".cam-update-" + UUID().uuidString)
        let backupName = ".cam-backup-" + UUID().uuidString
        let backup = current.deletingLastPathComponent().appendingPathComponent(backupName)
        try files.createDirectory(mount)
        defer {
            try? processes.run("/usr/bin/hdiutil", arguments: ["detach", mount.path, "-force"])
            try? files.remove(mount)
            try? files.remove(staging)
        }
        try processes.run("/usr/bin/hdiutil", arguments: [
            "attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path
        ])
        let source = mount.appendingPathComponent("MacPocketKnife.app")
        guard files.bundleIdentifier(at: source) == identifier else { throw UpdateInstallError.invalidBundle }
        try validateSignature(source)
        try files.createDirectory(staging)
        let staged = staging.appendingPathComponent(current.lastPathComponent)
        try files.copy(source, to: staged)
        guard files.bundleIdentifier(at: staged) == identifier else { throw UpdateInstallError.invalidBundle }
        try validateSignature(staged)
        do {
            try files.replace(current, with: staged, backupName: backupName)
            guard files.bundleIdentifier(at: current) == identifier else { throw UpdateInstallError.invalidBundle }
            try validateSignature(current)
        } catch {
            // A failed rollback keeps the backup on disk for recovery.
            try files.restore(current, from: backup)
            throw error
        }
        try? files.remove(backup)
    }

    private func validateSignature(_ app: URL) throws {
        do { try processes.run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", app.path]) }
        catch { throw UpdateInstallError.signatureInvalid }
    }

    /// Positional arguments keep app paths out of shell code. The helper waits for
    /// the actual process to exit before launching the installed bundle.
    public static func relaunchProcess(appURL: URL, processID: Int32 = ProcessInfo.processInfo.processIdentifier) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 1; done; /usr/bin/open -n \"$2\"",
                             "cam-update", String(processID), appURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }
}

public struct LocalUpdateFileSystem: UpdateFileSystem {
    public init() {}

    public func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func createDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    public func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
    public func copy(_ source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }
    public func bundleIdentifier(at app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty else { return nil }
        return identifier
    }
    public func replace(_ current: URL, with staged: URL, backupName: String) throws {
        _ = try FileManager.default.replaceItemAt(current, withItemAt: staged, backupItemName: backupName,
                                                  options: .withoutDeletingBackupItem)
    }
    public func restore(_ current: URL, from backup: URL) throws {
        guard FileManager.default.fileExists(atPath: backup.path) else { return }
        if FileManager.default.fileExists(atPath: current.path) {
            _ = try FileManager.default.replaceItemAt(current, withItemAt: backup)
        } else {
            try FileManager.default.moveItem(at: backup, to: current)
        }
    }
}

public struct UpdateProcessRunner: UpdateProcessRunning {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 120) {
        self.timeout = timeout
    }
    public func run(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            // A child can ignore SIGTERM. Bound cleanup too, then force its exit.
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            throw UpdateInstallError.operationFailed
        }
        guard process.terminationStatus == 0 else { throw UpdateInstallError.operationFailed }
    }
}

public protocol UpdateDownloadTransport: Sendable {
    func download(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, Int)
}

public protocol UpdateDownloadFileSystem: Sendable {
    func createDirectory(_ directory: URL) throws
    func move(_ source: URL, to destination: URL) throws
    func remove(_ url: URL) throws
}

extension LocalUpdateFileSystem: UpdateDownloadFileSystem {
    public func move(_ source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }
}

public struct UpdateDownloader: UpdateDownloading {
    private let transport: any UpdateDownloadTransport
    private let files: any UpdateDownloadFileSystem

    public init(transport: any UpdateDownloadTransport = URLSessionUpdateDownloadTransport(),
                files: any UpdateDownloadFileSystem = LocalUpdateFileSystem()) {
        self.transport = transport
        self.files = files
    }

    public func download(_ asset: ReleaseAsset, to directory: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard UpdateChecker.selectAsset([asset]) != nil else { throw UpdateInstallError.operationFailed }
        try files.createDirectory(directory)
        let (temporary, status) = try await transport.download(from: asset.downloadURL, progress: progress)
        defer { try? files.remove(temporary) }
        guard status == 200 else { throw UpdateInstallError.downloadFailed(status) }
        let destination = directory.appendingPathComponent("update.dmg")
        try files.move(temporary, to: destination)
        progress(1)
        return destination
    }
}

public struct URLSessionUpdateDownloadTransport: UpdateDownloadTransport {
    public init() {}

    public func download(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, Int) {
        let delegate = DownloadProgress(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(from: url)
        return (temporary, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    let progress: @Sendable (Double) -> Void
    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let host = request.url?.host ?? ""
        let allowed = request.url?.scheme == "https" &&
            (host == "github.com" || host == "release-assets.githubusercontent.com" || host == "objects.githubusercontent.com")
        completionHandler(allowed ? request : nil)
    }
}
