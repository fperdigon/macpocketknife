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

import CoreAudio
import Foundation

func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}
let system = AudioObjectID(kAudioObjectSystemObject)
var address = property(kAudioHardwarePropertyDefaultOutputDevice)
var device = AudioDeviceID(0)
var size = UInt32(MemoryLayout<AudioDeviceID>.size)
let status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device)
if CommandLine.arguments.contains("--select-blackhole") {
    var devicesAddress = property(kAudioHardwarePropertyDevices)
    var bytes: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &devicesAddress, 0, nil, &bytes) == noErr else { exit(1) }
    var devices = [AudioDeviceID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioDeviceID>.size)
    let result = devices.withUnsafeMutableBytes {
        AudioObjectGetPropertyData(system, &devicesAddress, 0, nil, &bytes, $0.baseAddress!)
    }
    guard result == noErr else { exit(1) }
    for candidate in devices {
        var nameAddress = property(kAudioObjectPropertyName)
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        let nameStatus = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(candidate, &nameAddress, 0, nil, &nameSize, $0)
        }
        guard nameStatus == noErr else { continue }
        if (name as String).contains("BlackHole") {
            var selected = candidate
            guard AudioObjectSetPropertyData(system, &address, 0, nil, size, &selected) == noErr else { exit(1) }
            print("Selected default output: \(name)")
            exit(0)
        }
    }
    print("BlackHole output was not found")
    exit(1)
}
guard status == noErr, device != kAudioObjectUnknown else {
    print("NO AUDIO OUTPUT DEVICE (CoreAudio status \(status))")
    exit(20)
}
print("Default audio output device: \(device)")
