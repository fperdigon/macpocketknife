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
@preconcurrency import ScreenCaptureKit

@MainActor
final class RecordingDisplayThumbnails: ObservableObject {
    @Published private(set) var images: [String: CGImage] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var hasPermission = false
    private var task: Task<Void, Never>?
    private var generation = 0

    func refresh(displays: [DisplayInfo]) {
        clear()
        hasPermission = CGPreflightScreenCaptureAccess()
        guard hasPermission else { return }
        var displayIDs: [String: CGDirectDisplayID] = [:]
        for display in displays {
            guard let uuid = CFUUIDCreateFromString(nil, display.uuid as CFString) else { continue }
            let id = CGDisplayGetDisplayIDFromUUID(uuid)
            if id != kCGNullDirectDisplay { displayIDs[display.uuid] = id }
        }
        isLoading = true
        let currentGeneration = generation
        task = Task { [weak self] in
            let images = await RecordingThumbnailCapture().capture(displayIDs: displayIDs)
            guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
            self.images = images
            self.isLoading = false
            self.task = nil
        }
    }

    func clear() {
        generation += 1
        task?.cancel()
        task = nil
        images = [:]
        isLoading = false
    }
}

// Actor isolation keeps capture and image resizing off the main thread, including
// on Swift 6.1. Only the small, immutable thumbnails cross back to the UI.
private actor RecordingThumbnailCapture {
    func capture(displayIDs: [String: CGDirectDisplayID]) async -> [String: CGImage] {
        guard !Task.isCancelled, CGPreflightScreenCaptureAccess() else { return [:] }
        var images: [String: CGImage] = [:]
        if #available(macOS 14.0, *) {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
                return [:]
            }
            for (uuid, id) in displayIDs {
                guard !Task.isCancelled, CGPreflightScreenCaptureAccess() else { return [:] }
                guard let display = content.displays.first(where: { $0.displayID == id }) else { continue }
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.width = 400
                configuration.height = max(1, 400 * display.height / max(1, display.width))
                configuration.showsCursor = false
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
                    guard !Task.isCancelled else { return [:] }
                    images[uuid] = thumbnail(image)
                }
            }
        } else {
            for (uuid, id) in displayIDs {
                guard !Task.isCancelled, CGPreflightScreenCaptureAccess() else { return [:] }
                if let image = CGDisplayCreateImage(id) { images[uuid] = thumbnail(image) }
            }
        }
        return images
    }

    private func thumbnail(_ image: CGImage) -> CGImage? {
        let width = min(400, image.width)
        let height = max(1, image.height * width / max(1, image.width))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
