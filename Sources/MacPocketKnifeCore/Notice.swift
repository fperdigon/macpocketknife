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

public enum NoticeKind: String, Sendable, Equatable {
    case batteryAlert
    case keepAwakeDetected
    case processTerminated
    case terminationSkipped
    case info
}

public struct Notice: Sendable, Equatable {
    public let kind: NoticeKind
    public let title: String
    public let body: String
    public let level: AlertLevel?
    public let recordingFile: URL?

    public init(kind: NoticeKind, title: String, body: String, level: AlertLevel? = nil, recordingFile: URL? = nil) {
        self.kind = kind
        self.title = title
        self.body = body
        self.level = level
        self.recordingFile = recordingFile
    }
}

public protocol AlertNotifying: Sendable {
    func deliver(_ notice: Notice) async
}
