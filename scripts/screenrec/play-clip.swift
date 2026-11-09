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
@preconcurrency import AVFoundation
import Foundation

@MainActor
final class PlayerDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var player: AVPlayer?
    var observer: Any?
    var completion: NSObjectProtocol?
    var reported = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.count == 2, let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        }) else { exit(2) }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.backgroundColor = .black
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let player = AVPlayer(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        player.volume = 1
        player.isMuted = false
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer = layer
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        self.player = player
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 100), queue: .main) { time in
            Task { @MainActor in
                if !self.reported, time.seconds > 0, player.rate > 0 {
                    self.reported = true
                    print(String(format: "PLAYBACK_STARTED %.9f media=%.6f", Date().timeIntervalSince1970, time.seconds))
                    fflush(stdout)
                }
            }
        }
        completion = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main) { _ in exit(0) }
        player.play()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(25))
            FileHandle.standardError.write(Data("Playback timed out: \(String(describing: player.currentItem?.error))\n".utf8))
            exit(1)
        }
    }
}

let app = NSApplication.shared
let delegate = PlayerDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
