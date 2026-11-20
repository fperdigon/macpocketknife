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
@preconcurrency import os
@preconcurrency import Darwin

/// The small file-system boundary keeps logging independent of the real Library directory.
public protocol LogFileSystem: Sendable {
    func createDirectory(at url: URL) throws
    func contents(of url: URL) throws -> [URL]
    func attributes(at url: URL) throws -> [FileAttributeKey: Any]
    func append(_ data: Data, to url: URL) throws
    func remove(at url: URL) throws
}

public struct LocalLogFileSystem: LogFileSystem {
    public init() {}

    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    public func contents(of url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }

    public func attributes(at url: URL) throws -> [FileAttributeKey: Any] {
        try FileManager.default.attributesOfItem(atPath: url.path)
    }

    public func append(_ data: Data, to url: URL) throws {
        // O_NOFOLLOW prevents an existing symbolic link from redirecting a log write.
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += count
            }
        }
    }

    public func remove(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

/// A log file's date comes from its name, never its modification timestamp.
public struct LogFile: Sendable {
    public let name: String
    public let size: UInt64
    public let date: Date
}

public struct LogFolder: Sendable {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacPocketKnife", isDirectory: true)
    }

    public let url: URL
    private let fileSystem: any LogFileSystem
    private let calendar: Calendar

    public init(
        url: URL = LogFolder.defaultURL,
        fileSystem: any LogFileSystem = LocalLogFileSystem(),
        calendar: Calendar = .current
    ) {
        self.url = url
        self.fileSystem = fileSystem
        self.calendar = calendar
    }

    public func createIfNeeded() throws {
        try fileSystem.createDirectory(at: url)
    }

    public func files() throws -> [LogFile] {
        var result: [LogFile] = []
        for item in try fileSystem.contents(of: url) {
            guard let date = Self.date(in: item.lastPathComponent, calendar: calendar) else { continue }
            let attributes = try fileSystem.attributes(at: item)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            result.append(LogFile(name: item.lastPathComponent, size: size, date: date))
        }
        return result.sorted { $0.name < $1.name }
    }

    static func name(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "macpocketknife-%04d-%02d-%02d.log",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(in name: String, calendar: Calendar) -> Date? {
        guard name.count == 29, name.hasPrefix("macpocketknife-"), name.hasSuffix(".log") else {
            return nil
        }
        let dateText = String(name.dropFirst(15).dropLast(4))
        let parts = dateText.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components), Self.name(for: date, calendar: calendar) == name else {
            return nil
        }
        return date
    }
}

/// All state and file operations are protected by `lock`; callers can log synchronously from any task.
public final class AppLogger: @unchecked Sendable {
    public enum Level: String, Sendable, CaseIterable {
        case debug = "DEBUG", info = "INFO", warning = "WARNING", error = "ERROR"
    }

    public static let noop = AppLogger(enabled: false)
    private let lock = NSLock()
    private let folder: LogFolder
    private let fileSystem: any LogFileSystem
    private let clock: @Sendable () -> Date
    private let calendar: Calendar
    private let formatter: DateFormatter
    private let softLimit: UInt64
    private let hardLimit: UInt64
    private let mirrorToUnifiedLog: Bool
    private let enabled: Bool
    private let homeDirectory: String
    private var currentName: String?
    private var capWarningWritten = false
    private var fileError = false

    /// True after the first file-system failure. No error is propagated to the app.
    public var hasFileError: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fileError
    }

    public init(
        directory: URL = LogFolder.defaultURL,
        fileSystem: any LogFileSystem = LocalLogFileSystem(),
        clock: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current,
        softLimit: UInt64 = 10 * 1_024 * 1_024,
        hardLimit: UInt64 = 20 * 1_024 * 1_024,
        mirrorToUnifiedLog: Bool = true,
        enabled: Bool = true,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.folder = LogFolder(url: directory, fileSystem: fileSystem, calendar: calendar)
        self.fileSystem = fileSystem
        self.clock = clock
        self.calendar = calendar
        self.softLimit = softLimit
        self.hardLimit = hardLimit
        self.mirrorToUnifiedLog = mirrorToUnifiedLog
        self.enabled = enabled
        self.homeDirectory = homeDirectory
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXX"
        self.formatter = formatter
        if enabled { prepareDay(clock()) }
    }

    public func debug(category: String, _ message: String) { log(.debug, category: category, message) }
    public func info(category: String, _ message: String) { log(.info, category: category, message) }
    public func warning(category: String, _ message: String) { log(.warning, category: category, message) }
    public func error(category: String, _ message: String) { log(.error, category: category, message) }

    public func log(_ level: Level, category: String, _ message: String) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        let safeCategory = sanitize(category)
        let safeMessage = sanitize(message)
        mirror(level, category: safeCategory, message: safeMessage)
        prepareDay(now)
        guard !fileError, let name = currentName else { return }
        let url = folder.url.appendingPathComponent(name)
        do {
            let size: UInt64
            if let attributes = try? fileSystem.attributes(at: url) {
                size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            } else {
                size = 0
            }
            if size >= softLimit && !capWarningWritten {
                capWarningWritten = true
                let warning = "log size cap reached"
                mirror(.warning, category: "logging", message: warning)
                let data = line(.warning, category: "logging", message: warning, at: now)
                if size <= hardLimit && UInt64(data.count) <= hardLimit - size {
                    try fileSystem.append(data, to: url)
                }
            }
            if size >= softLimit && (level == .debug || level == .info) { return }
            let data = line(level, category: safeCategory, message: safeMessage, at: now)
            let newSize = (try? fileSystem.attributes(at: url)[.size] as? NSNumber)?.uint64Value ?? size
            guard newSize <= hardLimit, UInt64(data.count) <= hardLimit - newSize else { return }
            try fileSystem.append(data, to: url)
        } catch {
            fileError = true
        }
    }

    private func prepareDay(_ date: Date) {
        let name = LogFolder.name(for: date, calendar: calendar)
        guard currentName != name else { return }
        currentName = name
        capWarningWritten = false
        guard !fileError else { return }
        do {
            try folder.createIfNeeded()
            let today = calendar.startOfDay(for: date)
            guard let cutoff = calendar.date(byAdding: .day, value: -29, to: today) else { return }
            for file in try folder.files() where file.date < cutoff {
                try fileSystem.remove(at: folder.url.appendingPathComponent(file.name))
            }
        } catch {
            fileError = true
        }
    }

    private func sanitize(_ value: String) -> String {
        let redacted = Redactor.redact(value, homeDirectory: homeDirectory)
        return redacted.replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func line(_ level: Level, category: String, message: String, at date: Date) -> Data {
        let text = "\(formatter.string(from: date)) \(level.rawValue) [\(category)] \(message)\n"
        return Data(text.utf8)
    }

    private func mirror(_ level: Level, category: String, message: String) {
        guard mirrorToUnifiedLog else { return }
        let logger = Logger(subsystem: "io.github.fperdigon.macpocketknife", category: category)
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }
}

public enum AppLog {
    public static let folder: LogFolder = {
        let override = ProcessInfo.processInfo.environment["MACPOCKETKNIFE_LOG_DIR"]
        let url = override.map { URL(fileURLWithPath: $0, isDirectory: true) }
        return LogFolder(url: url ?? LogFolder.defaultURL)
    }()

    public static let shared: AppLogger = {
        let environment = ProcessInfo.processInfo.environment
        // SwiftPM may launch swiftpm-testing-helper with the bundle in a later argument.
        let isTesting = CommandLine.arguments.contains { $0.contains(".xctest") }
            || environment["XCTestConfigurationFilePath"] != nil
        if isTesting && environment["MACPOCKETKNIFE_LOG_DIR"] == nil { return .noop }
        return AppLogger(directory: folder.url)
    }()
}
