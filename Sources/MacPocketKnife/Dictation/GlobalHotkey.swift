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

import Carbon
import Foundation

@MainActor
final class GlobalHotkey {
    private var hotkeys: [UInt32: EventHotKeyRef] = [:]
    private var keys: [UInt32: String] = [:]
    private var handler: EventHandlerRef?
    var actions: [UInt32: @MainActor () -> Void] = [:]

    init() {
        QuitSelfTest.trace("GlobalHotkey init start")
        defer { QuitSelfTest.trace("GlobalHotkey init done") }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var identifier = EventHotKeyID()
            guard let event else { return OSStatus(eventNotHandledErr) }
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == 0x4D504B44 else { return OSStatus(eventNotHandledErr) }
            let id = identifier.id
            guard let context else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<GlobalHotkey>.fromOpaque(context).takeUnretainedValue().actions[id]?()
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(id: UInt32, enabled: Bool, key: String) -> Bool {
        QuitSelfTest.trace("GlobalHotkey register \(id) start")
        defer { QuitSelfTest.trace("GlobalHotkey register \(id) done") }
        if let previous = hotkeys.removeValue(forKey: id) { UnregisterEventHotKey(previous) }
        keys.removeValue(forKey: id)
        guard enabled else { return true }
        guard handler != nil, let code = Self.keyCodes[key], !keys.values.contains(key) else { return false }
        let identifier = EventHotKeyID(signature: 0x4D504B44, id: id)
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        var hotkey: EventHotKeyRef?
        let result = RegisterEventHotKey(code, modifiers, identifier, GetApplicationEventTarget(), 0, &hotkey)
        guard result == noErr, let hotkey else { return false }
        hotkeys[id] = hotkey
        keys[id] = key
        return true
    }

    func unregister() {
        for hotkey in hotkeys.values { UnregisterEventHotKey(hotkey) }
        hotkeys.removeAll()
        keys.removeAll()
    }

    func shutdown() {
        unregister()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        actions.removeAll()
    }

    // Carbon virtual key codes refer to physical ANSI letter keys.
    private static let keyCodes: [String: UInt32] = [
        "A": 0, "B": 11, "C": 8, "D": 2, "E": 14, "F": 3, "G": 5,
        "H": 4, "I": 34, "J": 38, "K": 40, "L": 37, "M": 46,
        "N": 45, "O": 31, "P": 35, "Q": 12, "R": 15, "S": 1,
        "T": 17, "U": 32, "V": 9, "W": 13, "X": 7, "Y": 16, "Z": 6,
    ]
}
