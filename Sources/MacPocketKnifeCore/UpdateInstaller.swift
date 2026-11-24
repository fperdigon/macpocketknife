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
    case missingDigest
    case unexpectedVersion
    case unsafeBundle

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let status): return "The update download failed (HTTP \(status))."
        case .checksumMismatch: return "The download does not match GitHub's SHA-256 digest. Installation was refused."
        case .invalidDigest: return "GitHub reported an unsupported or invalid digest."
        case .invalidBundle: return "The update does not contain an app with the running app's bundle identifier."
        case .signatureInvalid: return "The update's code signature could not be verified."
        case .operationFailed: return "The update could not be installed. Check that the app's folder is writable and try again."
        case .missingDigest: return "The release provides no SHA-256 checksum, so the download cannot be verified. Installation was refused."
        case .unexpectedVersion: return "The downloaded app does not match the release that was offered (or is older than the running app). Installation was refused."
        case .unsafeBundle: return "The downloaded app contains symbolic links where none are expected. Installation was refused."
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
    func bundleMetadata(at app: URL) -> UpdateBundleMetadata?
    /// True when the app, its `Contents` folder, or an entry directly inside `Contents`
    /// or `Contents/MacOS` is a symbolic link.
    func hasSymlinkInBundleSkeleton(at app: URL) -> Bool
    func replace(_ current: URL, with staged: URL, backupName: String) throws
    func restore(_ current: URL, from backup: URL) throws
}

public protocol UpdateProcessRunning: Sendable {
    func run(_ executable: String, arguments: [String]) throws
    /// Runs the process and returns its combined standard output and standard error.
    func runCapturing(_ executable: String, arguments: [String]) throws -> String
}

extension UpdateProcessRunning {
    /// Runners that cannot capture output fail closed.
    public func runCapturing(_ executable: String, arguments: [String]) throws -> String {
        throw UpdateInstallError.operationFailed
    }
}

/// The Info.plist fields the updater compares against the offered release.
public struct UpdateBundleMetadata: Equatable, Sendable {
    public let identifier: String
    public let version: String
    public let sha: String
    public let channel: String

    public init(identifier: String, version: String, sha: String = "unknown", channel: String = "dev") {
        self.identifier = identifier
        self.version = version
        self.sha = sha.lowercased()
        self.channel = channel
    }
}

/// What the installer requires the downloaded bundle to be, derived from the offered release.
public struct UpdateExpectation: Equatable, Sendable {
    public let tag: String
    public let channel: UpdateChannel
    public let runningVersion: String

    public init(tag: String, channel: UpdateChannel, runningVersion: String) {
        self.tag = tag
        self.channel = channel
        self.runningVersion = runningVersion
    }

    public init(update: AvailableUpdate, runningVersion: String) {
        self.init(tag: update.release.tag, channel: update.channel, runningVersion: runningVersion)
    }

    /// Checks the bundle's metadata against the tag (`vX.Y.Z` or `nightly-YYYYMMDD-<sha>`).
    func accepts(_ meta: UpdateBundleMetadata) -> Bool {
        switch channel {
        case .stable:
            guard tag.hasPrefix("v") else { return false }
            let version = String(tag.dropFirst())
            return meta.channel == "stable" && meta.version == version
                && VersionCompare.compare(meta.version, runningVersion) >= 0
        case .nightly:
            let release = ReleaseInfo(tag: tag, name: tag, prerelease: true)
            guard let sha = UpdateChecker.nightlySHA(of: release) else { return false }
            return meta.channel == "nightly" && meta.sha.hasPrefix(sha)
        }
    }
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
        guard let expected else { throw UpdateInstallError.missingDigest }
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
    public func install(dmg: URL, expectedDigest: String?, expectation: UpdateExpectation,
                        over current: URL, work: URL) throws {
        try verify(file: dmg, expected: expectedDigest)
        guard current.pathExtension == "app", let identifier = files.bundleMetadata(at: current)?.identifier else {
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
        try validateBundle(source, identifier: identifier, expectation: expectation)
        try validateSignature(source, identifier: identifier)
        try files.createDirectory(staging)
        let staged = staging.appendingPathComponent(current.lastPathComponent)
        try files.copy(source, to: staged)
        try validateBundle(staged, identifier: identifier, expectation: expectation)
        try validateSignature(staged, identifier: identifier)
        do {
            try files.replace(current, with: staged, backupName: backupName)
            guard files.bundleMetadata(at: current)?.identifier == identifier else { throw UpdateInstallError.invalidBundle }
            try validateSignature(current, identifier: identifier)
        } catch {
            // A failed rollback keeps the backup on disk for recovery.
            try files.restore(current, from: backup)
            throw error
        }
        try? files.remove(backup)
    }

    /// Structural checks: no symlinks in the bundle skeleton, same bundle identifier,
    /// and the version/channel/commit of the release that was offered.
    private func validateBundle(_ app: URL, identifier: String, expectation: UpdateExpectation) throws {
        guard !files.hasSymlinkInBundleSkeleton(at: app) else { throw UpdateInstallError.unsafeBundle }
        guard let meta = files.bundleMetadata(at: app), meta.identifier == identifier else {
            throw UpdateInstallError.invalidBundle
        }
        guard expectation.accepts(meta) else { throw UpdateInstallError.unexpectedVersion }
    }

    /// `codesign --verify` proves the bundle is self-consistent (ad-hoc signatures carry no
    /// publisher identity). The signing identifier must equal the bundle identifier and the
    /// hardened runtime flag must be present, as for official builds.
    private func validateSignature(_ app: URL, identifier: String) throws {
        do {
            try processes.run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", app.path])
            let details = try processes.runCapturing("/usr/bin/codesign", arguments: ["-dv", "--verbose=2", app.path])
            let lines = details.split(separator: "\n").map(String.init)
            guard lines.contains("Identifier=" + identifier),
                  lines.contains(where: { $0.hasPrefix("CodeDirectory ") && $0.contains("flags=") && $0.contains("runtime") })
            else { throw UpdateInstallError.signatureInvalid }
        } catch { throw UpdateInstallError.signatureInvalid }
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
    public func bundleMetadata(at app: URL) -> UpdateBundleMetadata? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty else { return nil }
        return UpdateBundleMetadata(identifier: identifier,
                                    version: info["CFBundleShortVersionString"] as? String ?? "",
                                    sha: info["CAMGitSHA"] as? String ?? "unknown",
                                    channel: info["CAMBuildChannel"] as? String ?? "dev")
    }
    public func hasSymlinkInBundleSkeleton(at app: URL) -> Bool {
        let fm = FileManager.default
        func isLink(_ url: URL) -> Bool {
            (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
        }
        let contents = app.appendingPathComponent("Contents")
        if isLink(app) || isLink(contents) { return true }
        for folder in [contents, contents.appendingPathComponent("MacOS")] {
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            if names.contains(where: { isLink(folder.appendingPathComponent($0)) }) { return true }
        }
        return false
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
        _ = try execute(executable, arguments: arguments, capture: false)
    }

    public func runCapturing(_ executable: String, arguments: [String]) throws -> String {
        try execute(executable, arguments: arguments, capture: true)
    }

    private func execute(_ executable: String, arguments: [String], capture: Bool) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = capture ? pipe : FileHandle.nullDevice
        process.standardError = capture ? pipe : FileHandle.nullDevice
        // Drain the pipe concurrently so a chatty child cannot block on a full buffer.
        let collected = LockedData()
        if capture { pipe.fileHandleForReading.readabilityHandler = { collected.append($0.availableData) } }
        defer { pipe.fileHandleForReading.readabilityHandler = nil }
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
        if capture { collected.append(pipe.fileHandleForReading.readDataToEndOfFile()) }
        return String(decoding: collected.value, as: UTF8.self)
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

/// Finds the SHA-256 for an update: GitHub's asset `digest` when present, otherwise the
/// release's `<asset>.sha256` file. Without either, the update is refused.
public struct UpdateDigestResolver: Sendable {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, Int)
    private let fetch: Fetch

    public init(fetch: @escaping Fetch = UpdateDigestResolver.urlSessionFetch) { self.fetch = fetch }

    public static let urlSessionFetch: Fetch = { request in
        let session = URLSession(configuration: .ephemeral, delegate: DownloadProgress(progress: { _ in }), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    public func resolve(asset: ReleaseAsset, in release: ReleaseInfo) async throws -> String {
        if let digest = asset.digest, !digest.isEmpty { return digest }
        let wanted = asset.name + ".sha256"
        guard let file = release.assets.first(where: {
            $0.name == wanted && $0.downloadURL.scheme == "https" && $0.downloadURL.host == "github.com"
                && $0.downloadURL.path.hasPrefix("/fperdigon/macpocketknife/releases/download/")
        }) else { throw UpdateInstallError.missingDigest }
        var request = URLRequest(url: file.downloadURL)
        request.timeoutInterval = 20
        let (data, status) = try await fetch(request)
        guard status == 200 else { throw UpdateInstallError.downloadFailed(status) }
        guard data.count <= 4096, let digest = Self.parse(String(decoding: data, as: UTF8.self), assetName: asset.name) else {
            throw UpdateInstallError.invalidDigest
        }
        return digest
    }

    /// Parses `<64 hex>  <file name>` (shasum output) into "sha256:<hex>".
    static func parse(_ text: String, assetName: String) -> String? {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let hex = tokens.first, hex.count == 64, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        if tokens.count > 1 {
            let name = tokens[1].hasPrefix("*") ? String(tokens[1].dropFirst()) : tokens[1]
            guard tokens.count == 2, name == assetName else { return nil }
        }
        return "sha256:" + hex.lowercased()
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
