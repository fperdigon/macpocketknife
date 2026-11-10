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
    @Published private(set) var polling = RecordingPreviewPolling()
    private var displayIDs: [String: CGDirectDisplayID] = [:]
    private var captures: [String: Task<Void, Never>] = [:]
    private var timer: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var generation = 0
    private let capture = RecordingThumbnailCapture()

    func start(displays: [DisplayInfo]) {
        stop(releaseImages: false)
        for display in displays {
            guard let uuid = CFUUIDCreateFromString(nil, display.uuid as CFString) else { continue }
            let id = CGDisplayGetDisplayIDFromUUID(uuid)
            if id != kCGNullDirectDisplay { displayIDs[display.uuid] = id }
        }
        images = images.filter { displayIDs[$0.key] != nil }
        polling.start(displayIDs: Array(displayIDs.keys))
        startTimer()
    }

    func resume() {
        guard polling.isActive, polling.isDenied else { return }
        retry?.cancel()
        retry = nil
        polling.resume()
        startTimer()
    }

    func allowPreview() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        retry?.cancel()
        retry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) }
            catch { return }
            self?.resume()
        }
    }

    private func startTimer() {
        timer?.cancel()
        guard polling.shouldPoll else { return }
        tick()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                guard let self, self.polling.shouldPoll else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        let currentGeneration = generation
        for (uuid, id) in displayIDs {
            // Keep cancelled tasks registered until the capture API actually returns,
            // so even a rapid close/reopen cannot overlap captures of one display.
            guard captures[uuid] == nil, polling.begin(uuid) else { continue }
            let capture = capture
            captures[uuid] = Task { [weak self] in
                let image = await capture.capture(displayID: id)
                guard let self else { return }
                self.captures[uuid] = nil
                guard !Task.isCancelled, self.generation == currentGeneration else { return }
                if let image { self.images[uuid] = image }
                self.polling.complete(uuid, succeeded: image != nil)
                if self.polling.isDenied {
                    self.timer?.cancel()
                    self.timer = nil
                }
            }
        }
    }

    func stop(releaseImages: Bool = true) {
        generation += 1
        timer?.cancel()
        timer = nil
        retry?.cancel()
        retry = nil
        for task in captures.values { task.cancel() }
        displayIDs = [:]
        if releaseImages { images = [:] }
        polling.stop()
    }
}

// Actor isolation keeps capture and image resizing off the main thread, including
// on Swift 6.1. Only the small, immutable thumbnails cross back to the UI.
private actor RecordingThumbnailCapture {
    func capture(displayID: CGDirectDisplayID) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let image: CGImage?
        if #available(macOS 14.0, *) {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  !Task.isCancelled,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = 480
            configuration.height = max(1, 480 * display.height / max(1, display.width))
            configuration.showsCursor = false
            image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } else {
            image = CGDisplayCreateImage(displayID)
        }
        guard !Task.isCancelled, let image else { return nil }
        return thumbnail(image)
    }

    private func thumbnail(_ image: CGImage) -> CGImage? {
        guard image.width > 0, image.height > 0 else { return nil }
        // Bound both dimensions, including portrait and unusually tall displays.
        let scale = min(1, 480.0 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        let bytesPerRow = width * 4
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: bitmapInfo),
              let data = context.data else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Denied captures can return empty, black, or solid-color output rather
        // than nil. A genuinely solid screen is indistinguishable from that output.
        // Inspect only the downscaled buffer; never retain full-resolution pixels.
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var hasContent = false
        var hasVariation = false
        for offset in stride(from: 0, to: bytesPerRow * height, by: 4) {
            let visible = pixels[offset + 3] > 0
            let color = max(pixels[offset], pixels[offset + 1], pixels[offset + 2])
            if visible && color > 3 {
                hasContent = true
            }
            if pixels[offset] != pixels[0] || pixels[offset + 1] != pixels[1]
                || pixels[offset + 2] != pixels[2] || pixels[offset + 3] != pixels[3] {
                hasVariation = true
            }
            if hasContent && hasVariation { return context.makeImage() }
        }
        return nil
    }
}
