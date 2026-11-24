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
import Testing
@testable import MacPocketKnifeCore

private final class LogTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }
    func set(_ date: Date) {
        lock.lock()
        defer { lock.unlock() }
        self.date = date
    }
}

private struct LogTestFixture {
    let root: URL
    let directory: URL
    let calendar: Calendar
    let clock: LogTestClock

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directory = root.appendingPathComponent("logs")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -5 * 3_600)!
        self.calendar = calendar
        let date = calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 20, hour: 14, minute: 3, second: 22, nanosecond: 123_000_000
        ))!
        clock = LogTestClock(date)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func logger(softLimit: UInt64 = 10_485_760, hardLimit: UInt64 = 20_971_520) -> AppLogger {
        AppLogger(directory: directory, clock: { clock.now() }, calendar: calendar,
                  softLimit: softLimit, hardLimit: hardLimit, mirrorToUnifiedLog: false,
                  homeDirectory: "/Users/test-person")
    }

    func file(_ date: Date? = nil) -> URL {
        directory.appendingPathComponent(LogFolder.name(for: date ?? clock.now(), calendar: calendar))
    }

    func text(_ date: Date? = nil) throws -> String {
        try String(contentsOf: file(date), encoding: .utf8)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Test func loggerUsesPreciseLocalLineFormatAndEscapesNewlines() throws {
    let fixture = try LogTestFixture()
    defer { fixture.cleanup() }
    let logger = fixture.logger()
    logger.info(category: "recording", "message")
    logger.debug(category: "state\nnew", "line\r\nend")
    logger.warning(category: "policy", "warning")
    logger.error(category: "policy", "error")
    let lines = try fixture.text().split(separator: "\n")
    #expect(lines.count == 4)
    #expect(lines[0] == "2026-11-20T14:03:22.123-05:00 INFO [recording] message")
    #expect(lines[1] == "2026-11-20T14:03:22.123-05:00 DEBUG [state\\nnew] line\\r\\nend")
    #expect(lines[2].contains(" WARNING [policy] warning"))
    #expect(lines[3].contains(" ERROR [policy] error"))
    #expect(!logger.hasFileError)
}

@Test func loggerCreatesNewDailyFileAndPrunesOnRollover() throws {
    let fixture = try LogTestFixture()
    defer { fixture.cleanup() }
    let logger = fixture.logger()
    let firstDay = fixture.clock.now()
    logger.info(category: "test", "before")
    let oldDay = fixture.calendar.date(byAdding: .day, value: -29, to: firstDay)!
    try Data("old".utf8).write(to: fixture.file(oldDay))
    let nextDay = fixture.calendar.date(byAdding: .day, value: 1, to: firstDay)!
    fixture.clock.set(nextDay)
    logger.info(category: "test", "after")
    #expect(try fixture.text(firstDay).contains("before"))
    #expect(try fixture.text(nextDay).contains("after"))
    #expect(!FileManager.default.fileExists(atPath: fixture.file(oldDay).path))
}

@Test func loggerRetentionKeepsExactlyThirtyDaysAndIgnoresForeignItems() throws {
    let fixture = try LogTestFixture()
    defer { fixture.cleanup() }
    try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
    for offset in -40...0 {
        let day = fixture.calendar.date(byAdding: .day, value: offset, to: fixture.clock.now())!
        try Data("log".utf8).write(to: fixture.file(day))
    }
    let foreign = ["notes.txt", "macpocketknife-2026-02-30.log", "macpocketknife-2026-1-01.log",
                   "macpocketknife-2020-01-01.log.backup", "macpocketknife-abcd-ef-gh.log"]
    for name in foreign {
        try Data().write(to: fixture.directory.appendingPathComponent(name))
    }
    let foreignDirectory = fixture.directory.appendingPathComponent("macpocketknife-2000-01-01.log")
    try FileManager.default.createDirectory(at: foreignDirectory, withIntermediateDirectories: false)
    let link = fixture.directory.appendingPathComponent("macpocketknife-2001-01-01.log")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.file())
    let logger = fixture.logger()
    #expect(!logger.hasFileError)
    let folder = LogFolder(url: fixture.directory, calendar: fixture.calendar)
    let files = try folder.files()
    #expect(files.count == 30)
    #expect(files.first?.name == "macpocketknife-2026-10-22.log")
    #expect(files.last?.name == "macpocketknife-2026-11-20.log")
    #expect(files.allSatisfy { $0.size == 3 })
    for name in foreign {
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent(name).path))
    }
    #expect(FileManager.default.fileExists(atPath: foreignDirectory.path))
    #expect(FileManager.default.fileExists(atPath: link.path))
}

@Test func loggerCreatesPrivateFolderAndFileAndAppends() throws {
    let fixture = try LogTestFixture()
    defer { fixture.cleanup() }
    fixture.logger().info(category: "test", "first")
    fixture.logger().info(category: "test", "second")
    let folderAttributes = try FileManager.default.attributesOfItem(atPath: fixture.directory.path)
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: fixture.file().path)
    #expect((folderAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(try fixture.text().split(separator: "\n").count == 2)
}

@Test func loggerRedactsMessagesAndCategoriesBeforeWriting() throws {
    let fixture = try LogTestFixture()
    defer { fixture.cleanup() }
    let token = "123456789:" + String(repeating: "A", count: 35)
    let logger = fixture.logger()
    let bearer = "Bearer " + "abcdef"
    logger.info(category: token, "/Users/test-person/Movies \(bearer) \(token)")
    let text = try fixture.text()
    #expect(!text.contains(token))
    #expect(!text.contains("/Users/test-person"))
    #expect(!text.contains("abcdef"))
    #expect(text.contains("[[REDACTED]] ~/Movies [REDACTED] [REDACTED]"))
}

@Test func loggerDropsLowPriorityAfterSoftCapAndAllEntriesAtHardCap() throws {
    let fixture = try LogTestFixture()
    defer { fixture.cleanup() }
    let logger = fixture.logger(softLimit: 100, hardLimit: 450)
    logger.info(category: "test", String(repeating: "a", count: 70))
    logger.debug(category: "test", "dropped-debug")
    logger.info(category: "test", "dropped-info")
    logger.warning(category: "test", "retained-warning")
    logger.error(category: "test", "retained-error")
    for _ in 0..<10 { logger.error(category: "test", String(repeating: "b", count: 100)) }
    let text = try fixture.text()
    #expect(!text.contains("dropped-debug"))
    #expect(!text.contains("dropped-info"))
    #expect(text.components(separatedBy: "log size cap reached").count == 2)
    #expect(text.contains("retained-warning"))
    #expect(text.contains("retained-error"))
    #expect(text.utf8.count <= 450)
    fixture.clock.set(fixture.calendar.date(byAdding: .day, value: 1, to: fixture.clock.now())!)
    logger.info(category: "test", "new-day-info")
    #expect(try fixture.text().contains("new-day-info"))
}

private struct FailingLogFileSystem: LogFileSystem {
    enum Failure: Error { case unavailable }
    func createDirectory(at url: URL) throws { throw Failure.unavailable }
    func contents(of url: URL) throws -> [URL] { throw Failure.unavailable }
    func attributes(at url: URL) throws -> [FileAttributeKey: Any] { throw Failure.unavailable }
    func append(_ data: Data, to url: URL) throws { throw Failure.unavailable }
    func remove(at url: URL) throws { throw Failure.unavailable }
}

@Test func loggerSilentlyRemembersUnwritableFolderAndNoopDoesNothing() throws {
    let fixture = try LogTestFixture()
    defer { fixture.cleanup() }
    let logger = AppLogger(directory: fixture.directory, fileSystem: FailingLogFileSystem(),
                           clock: { fixture.clock.now() }, mirrorToUnifiedLog: false)
    logger.info(category: "test", "silently discarded")
    #expect(logger.hasFileError)
    #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    AppLogger.noop.error(category: "test", "discarded")
    #expect(!AppLogger.noop.hasFileError)
}

private final class FlakyLogFileSystem: LogFileSystem, @unchecked Sendable {
    let inner = LocalLogFileSystem()
    private let lock = NSLock()
    private var failing = true
    func setFailing(_ value: Bool) { lock.lock(); failing = value; lock.unlock() }
    private var isFailing: Bool { lock.lock(); defer { lock.unlock() }; return failing }
    func createDirectory(at url: URL) throws { try inner.createDirectory(at: url) }
    func contents(of url: URL) throws -> [URL] { try inner.contents(of: url) }
    func attributes(at url: URL) throws -> [FileAttributeKey: Any] { try inner.attributes(at: url) }
    func append(_ data: Data, to url: URL) throws {
        if isFailing { throw CocoaError(.fileWriteUnknown) }
        try inner.append(data, to: url)
    }
    func remove(at url: URL) throws { try inner.remove(at: url) }
}

@Test func loggerRecoversAfterWriteErrorWithBackoff() throws {
    let fixture = try LogTestFixture()
    defer { fixture.cleanup() }
    let flaky = FlakyLogFileSystem()
    let logger = AppLogger(directory: fixture.directory, fileSystem: flaky,
                           clock: { fixture.clock.now() }, calendar: fixture.calendar,
                           mirrorToUnifiedLog: false, homeDirectory: "/Users/test-person")
    logger.info(category: "test", "first fails")
    #expect(logger.hasFileError)
    #expect(logger.fileFailureCount == 1)
    flaky.setFailing(false)
    // Inside the backoff window nothing is retried.
    fixture.clock.set(fixture.clock.now().addingTimeInterval(10))
    logger.info(category: "test", "too early")
    #expect(logger.hasFileError)
    #expect(logger.fileFailureCount == 1)
    fixture.clock.set(fixture.clock.now().addingTimeInterval(25))
    logger.info(category: "test", "recovered")
    #expect(!logger.hasFileError)
    let text = try fixture.text()
    #expect(text.contains("recovered"))
    #expect(!text.contains("too early"))
    // A failure while retrying schedules another retry.
    flaky.setFailing(true)
    logger.info(category: "test", "fails again")
    #expect(logger.hasFileError)
    #expect(logger.fileFailureCount == 2)
}

@Test func loggerRejectsSymbolicLinkAsDailyFile() throws {
    let fixture = try LogTestFixture()
    defer { fixture.cleanup() }
    let logger = fixture.logger()
    let target = fixture.root.appendingPathComponent("untouched")
    try Data("original".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: fixture.file(), withDestinationURL: target)
    logger.error(category: "test", "must not follow link")
    #expect(logger.hasFileError)
    #expect(try String(contentsOf: target, encoding: .utf8) == "original")
}

@Test func concurrentLoggingWritesCompleteIndividualLines() async throws {
    let fixture = try LogTestFixture()
    defer { fixture.cleanup() }
    let logger = fixture.logger()
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<250 {
            group.addTask { logger.info(category: "concurrent", "entry=\(index)") }
        }
    }
    let lines = try fixture.text().split(separator: "\n")
    #expect(lines.count == 250)
    for index in 0..<250 {
        let expected = "2026-11-20T14:03:22.123-05:00 INFO [concurrent] entry=\(index)"
        #expect(lines.contains(Substring(expected)))
    }
}

@Test func loggerMirrorsEveryLevelWithRedactedMetadata() throws {
    let fixture = try LogTestFixture()
    defer { fixture.cleanup() }
    let logger = AppLogger(directory: fixture.directory, clock: { fixture.clock.now() })
    for level in AppLogger.Level.allCases {
        logger.log(level, category: "logger-test", "metadata-only")
    }
    #expect(try fixture.text().split(separator: "\n").count == 4)
}

@Test func loggerRetentionUsesCalendarDaysAcrossDaylightSavingChange() throws {
    let fixture = try LogTestFixture()
    defer { fixture.cleanup() }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Toronto"))
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20)))
    let oldest = try #require(calendar.date(byAdding: .day, value: -29, to: now))
    let expired = try #require(calendar.date(byAdding: .day, value: -30, to: now))
    try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
    let oldestURL = fixture.directory.appendingPathComponent(LogFolder.name(for: oldest, calendar: calendar))
    let expiredURL = fixture.directory.appendingPathComponent(LogFolder.name(for: expired, calendar: calendar))
    try Data().write(to: oldestURL)
    try Data().write(to: expiredURL)
    let logger = AppLogger(directory: fixture.directory, clock: { now }, calendar: calendar,
                           mirrorToUnifiedLog: false)
    #expect(!logger.hasFileError)
    #expect(FileManager.default.fileExists(atPath: oldestURL.path))
    #expect(!FileManager.default.fileExists(atPath: expiredURL.path))
}

@Test func loggerHardCapDoesNotExceedLimitEvenForItsCapWarning() throws {
    let fixture = try LogTestFixture()
    defer { fixture.cleanup() }
    let logger = fixture.logger(softLimit: 10, hardLimit: 50)
    try Data(repeating: 65, count: 50).write(to: fixture.file())
    logger.error(category: "test", "dropped")
    logger.warning(category: "test", "also dropped")
    #expect(try Data(contentsOf: fixture.file()).count == 50)
    #expect(!logger.hasFileError)
}

@Test func sharedLoggerIsNoopInTheTestProcessUnlessExplicitlyOverridden() {
    if ProcessInfo.processInfo.environment["MACPOCKETKNIFE_LOG_DIR"] == nil {
        #expect(AppLog.shared === AppLogger.noop)
    }
}
