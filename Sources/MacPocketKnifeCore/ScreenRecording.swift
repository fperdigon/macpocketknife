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

public enum ScreenRecordingTarget: Codable, Equatable, Hashable, Sendable {
    case mainDisplay
    case display(uuid: String)
    case allDisplays
    case askEachTime

    public func validated() -> ScreenRecordingTarget {
        if case .display(let uuid) = self {
            guard let value = UUID(uuidString: uuid) else { return .mainDisplay }
            return .display(uuid: value.uuidString)
        }
        return self
    }
}

public struct DisplayInfo: Codable, Equatable, Sendable {
    public let uuid: String
    public let name: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let isMain: Bool

    public init(uuid: String, name: String, pixelWidth: Int, pixelHeight: Int, isMain: Bool) {
        self.uuid = uuid
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isMain = isMain
    }
}

public struct ScreenRecordingResolution: Equatable, Sendable {
    public let displays: [DisplayInfo]
    public let fellBack: Bool
}

public enum ScreenRecordingTargets {
    /// nil means the per-recording choice was cancelled or has not been supplied.
    public static func resolve(_ target: ScreenRecordingTarget, displays: [DisplayInfo],
                               chosenTarget: ScreenRecordingTarget? = nil) throws -> ScreenRecordingResolution? {
        guard !displays.isEmpty else { throw ScreenRecordingFailure.noDisplay }
        let main = displays.first(where: { $0.isMain }) ?? displays[0]
        switch target {
        case .mainDisplay: return ScreenRecordingResolution(displays: [main], fellBack: false)
        case .display(let uuid):
            let selected = displays.first { $0.uuid.caseInsensitiveCompare(uuid) == .orderedSame }
            return ScreenRecordingResolution(displays: [selected ?? main], fellBack: selected == nil)
        case .allDisplays:
            let ordered = [main] + displays.filter { $0.uuid != main.uuid }
            return ScreenRecordingResolution(displays: ordered, fellBack: false)
        case .askEachTime:
            guard let chosenTarget, chosenTarget != .askEachTime else { return nil }
            return try resolve(chosenTarget, displays: displays)
        }
    }
}

/// Platform-owned capture content (for example a system picker's content filter).
@MainActor public protocol ScreenRecordingContent: AnyObject, Sendable {}

@MainActor public protocol ScreenRecordingDisplayProviding {
    func connectedDisplays() -> [DisplayInfo]
}

@MainActor public protocol ScreenRecordingPicking {
    var isSupported: Bool { get }
    func chooseContent() async throws -> (any ScreenRecordingContent)?
    func cancel()
}

@MainActor public protocol ScreenRecordingFactory {
    func makeRecorder() -> any ScreenRecording
}

public struct ScreenRecordingConfiguration: Equatable, Sendable {
    public let frameRate: Int
    public let showsCursor: Bool
    public let includesMicrophone: Bool

    public init(frameRate: Int, showsCursor: Bool, includesMicrophone: Bool) {
        self.frameRate = frameRate == 60 ? 60 : 30
        self.showsCursor = showsCursor
        self.includesMicrophone = includesMicrophone
    }
}

public enum ScreenRecordingFailure: Error, Equatable, Sendable {
    case permissionDenied, microphoneDenied, lowDiskSpace, noDisplay, captureFailed, writingFailed, folderUnavailable

    public var message: String {
        switch self {
        case .permissionDenied:
            return "Allow access in System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch the app if needed."
        case .microphoneDenied:
            return "Allow microphone access in System Settings > Privacy & Security > Microphone."
        case .lowDiskSpace: return "Screen recording requires at least 1 GB of free space on the save volume."
        case .noDisplay: return "No display is available to record."
        case .captureFailed: return "Screen capture stopped unexpectedly. Any usable recording has been finalized."
        case .writingFailed: return "The recording could not be saved. Check free disk space and folder access."
        case .folderUnavailable: return "The recordings folder is unavailable. Choose another folder in Settings > Tools."
        }
    }
}

public enum RecordingMicrophoneOutcome: Equatable, Sendable {
    case included, disabled, denied, unsupported, unavailable

    public var notice: String? {
        switch self {
        case .included, .disabled: return nil
        case .denied:
            return "Saved without your microphone: allow it in System Settings > Privacy & Security > Microphone."
        case .unsupported:
            return "Saved without your microphone: microphone capture needs macOS 15 or later."
        case .unavailable:
            return "Saved without your microphone: the microphone could not start. Check your input device."
        }
    }
}

@MainActor
public protocol ScreenRecording: AnyObject {
    /// A nil failure means the user or system ended sharing normally.
    var onFailure: (@MainActor (ScreenRecordingFailure?) -> Void)? { get set }
    /// Microphone limitations are nonfatal and returned as the actual capture outcome.
    func start(configuration: ScreenRecordingConfiguration, destination: URL,
               display: DisplayInfo?, content: (any ScreenRecordingContent)?) async throws -> RecordingMicrophoneOutcome
    /// Finalizes the writer, removes empty or unusable output, and returns a usable file only.
    func stop() async throws -> URL?
}

@MainActor
public protocol ScreenRecordingPermissionProviding {
    func requestAccessIfNeeded() -> Bool
}

@MainActor
public protocol FreeDiskSpaceProviding {
    func availableBytes(at folder: URL) throws -> Int64
}

@MainActor
public protocol RecordingFileManaging {
    func createFolder(_ folder: URL) throws
    func exists(_ file: URL) -> Bool
    func revealFolder(_ folder: URL)
}

public enum ScreenRecordingFiles {
    public static var defaultFolder: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/MacPocketKnife").path
    }

    public static func name(date: Date, timeZone: TimeZone = .current, collision: Int = 1, displayName: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let suffix = collision > 1 ? " \(collision)" : ""
        let displaySuffix = displayName.map { " - " + sanitizedDisplayName($0) } ?? ""
        return "Screen \(formatter.string(from: date))\(displaySuffix)\(suffix).mp4"
    }

    public static func destination(date: Date, folder: URL, displayName: String? = nil, exists: (URL) -> Bool) -> URL {
        var collision = 1
        var file = folder.appendingPathComponent(name(date: date, collision: collision, displayName: displayName))
        while exists(file) {
            collision += 1
            file = folder.appendingPathComponent(name(date: date, collision: collision, displayName: displayName))
        }
        return file
    }

    public static func sanitizedDisplayName(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let parts = name.components(separatedBy: illegal)
        let cleaned = parts.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        var bounded = String(cleaned.prefix(80))
        // Leave room for the timestamp, collision suffix and extension even with emoji names.
        while bounded.utf8.count > 160 { bounded.removeLast() }
        bounded = bounded.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return bounded.isEmpty ? "Display" : bounded
    }

    public static func bitrate(width: Int, height: Int, frameRate: Int) -> Int {
        let estimate = Double(max(0, width)) * Double(max(0, height)) * Double(max(0, frameRate)) * 0.07
        return Int(min(40_000_000, max(4_000_000, estimate)))
    }
}
