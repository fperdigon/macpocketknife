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
        case .noDisplay: return "No main display is available to record."
        case .captureFailed: return "Screen capture stopped unexpectedly. Any usable recording has been finalized."
        case .writingFailed: return "The recording could not be saved. Check free disk space and folder access."
        case .folderUnavailable: return "The recordings folder is unavailable. Choose another folder in Settings > Tools."
        }
    }
}

@MainActor
public protocol ScreenRecording: AnyObject {
    /// A nil failure means the user or system ended sharing normally.
    var onFailure: (@MainActor (ScreenRecordingFailure?) -> Void)? { get set }
    func start(configuration: ScreenRecordingConfiguration, destination: URL) async throws
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

    public static func name(date: Date, timeZone: TimeZone = .current, collision: Int = 1) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let suffix = collision > 1 ? " \(collision)" : ""
        return "Screen \(formatter.string(from: date))\(suffix).mp4"
    }

    public static func destination(date: Date, folder: URL, exists: (URL) -> Bool) -> URL {
        var collision = 1
        var file = folder.appendingPathComponent(name(date: date, collision: collision))
        while exists(file) {
            collision += 1
            file = folder.appendingPathComponent(name(date: date, collision: collision))
        }
        return file
    }

    public static func bitrate(width: Int, height: Int, frameRate: Int) -> Int {
        let estimate = Double(max(0, width)) * Double(max(0, height)) * Double(max(0, frameRate)) * 0.07
        return Int(min(40_000_000, max(4_000_000, estimate)))
    }
}
