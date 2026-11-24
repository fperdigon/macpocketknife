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

public struct PolicySettings: Codable, Sendable, Equatable {
    public let killThresholdPercent: Int
    public let maxKillsPerWindow: Int
    public let killWindow: TimeInterval

    /// Percentages are clamped to 0...100 and counts to zero or greater.
    /// Finite windows are clamped to one second; nonfinite windows use 60 seconds.
    public init(
        killThresholdPercent: Int = 15,
        maxKillsPerWindow: Int = 3,
        killWindow: TimeInterval = 60
    ) {
        self.killThresholdPercent = min(100, max(0, killThresholdPercent))
        self.maxKillsPerWindow = max(0, maxKillsPerWindow)
        self.killWindow = killWindow.isFinite ? max(1, killWindow) : 60
    }

    private enum CodingKeys: String, CodingKey { case killThresholdPercent, maxKillsPerWindow, killWindow }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            killThresholdPercent: container.lenient(Int.self, .killThresholdPercent) ?? 15,
            maxKillsPerWindow: container.lenient(Int.self, .maxKillsPerWindow) ?? 3,
            killWindow: container.lenient(TimeInterval.self, .killWindow) ?? 60
        )
    }
}
