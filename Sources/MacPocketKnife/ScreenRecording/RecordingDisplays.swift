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
import CoreGraphics
import MacPocketKnifeCore
@preconcurrency import ScreenCaptureKit

@MainActor
struct RecordingDisplays: ScreenRecordingDisplayProviding {
    static func uuid(for id: CGDirectDisplayID) -> String? {
        guard let value = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, value) as String
    }

    func connectedDisplays() -> [DisplayInfo] {
        var result: [DisplayInfo] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            guard let uuid = Self.uuid(for: id), let mode = CGDisplayCopyDisplayMode(id) else { continue }
            result.append(DisplayInfo(uuid: uuid, name: screen.localizedName, pixelWidth: mode.pixelWidth,
                                      pixelHeight: mode.pixelHeight, isMain: id == CGMainDisplayID()))
        }
        return result.sorted { $0.isMain && !$1.isMain }
    }
}

@MainActor
struct RecordingFactory: ScreenRecordingFactory {
    func makeRecorder() -> any ScreenRecording { ScreenCaptureKitRecorder() }
}

@MainActor
final class PickedRecordingContent: ScreenRecordingContent {
    let filter: SCContentFilter
    init(filter: SCContentFilter) { self.filter = filter }
}

@MainActor
final class RecordingPicker: ScreenRecordingPicking {
    private var cancelCurrent: (@MainActor () -> Void)?
    var isSupported: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }
    func chooseContent() async throws -> (any ScreenRecordingContent)? {
        if #available(macOS 14.0, *) {
            let observer = RecordingPickerObserver()
            cancelCurrent = { observer.complete(content: nil, error: nil) }
            defer { cancelCurrent = nil }
            return try await observer.choose()
        }
        return nil
    }
    func cancel() {
        cancelCurrent?()
    }
}

@available(macOS 14.0, *)
@MainActor
private final class RecordingPickerObserver: NSObject, SCContentSharingPickerObserver {
    private var continuation: CheckedContinuation<(any ScreenRecordingContent)?, Error>?
    func choose() async throws -> (any ScreenRecordingContent)? {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay]
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            picker.present()
        }
    }
    func complete(content: (any ScreenRecordingContent)?, error: (any Error)?) {
        guard let continuation else { return }
        self.continuation = nil
        let picker = SCContentSharingPicker.shared
        picker.isActive = false
        picker.remove(self)
        picker.defaultConfiguration = SCContentSharingPickerConfiguration()
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: content) }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in self?.complete(content: nil, error: nil) }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor [weak self] in
            self?.complete(content: PickedRecordingContent(filter: filter), error: nil)
        }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor [weak self] in self?.complete(content: nil, error: ScreenRecordingFailure.captureFailed) }
    }
}
