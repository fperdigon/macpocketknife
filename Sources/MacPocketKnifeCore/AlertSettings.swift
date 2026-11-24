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

public struct AlertSettings: Codable, Sendable, Equatable {
    public let urgentBelowPercent: Int
    public let criticalBelowPercent: Int
    public let normalInterval: TimeInterval
    public let urgentInterval: TimeInterval
    public let criticalInterval: TimeInterval

    /// Thresholds satisfy 0 <= critical < urgent <= 100. Finite intervals are
    /// clamped to at least one second; nonfinite intervals use their defaults.
    public init(
        urgentBelowPercent: Int = 50,
        criticalBelowPercent: Int = 20,
        normalInterval: TimeInterval = 600,
        urgentInterval: TimeInterval = 120,
        criticalInterval: TimeInterval = 60
    ) {
        let urgent = min(100, max(1, urgentBelowPercent))
        self.urgentBelowPercent = urgent
        self.criticalBelowPercent = min(urgent - 1, max(0, criticalBelowPercent))
        self.normalInterval = normalInterval.isFinite ? max(1, normalInterval) : 600
        self.urgentInterval = urgentInterval.isFinite ? max(1, urgentInterval) : 120
        self.criticalInterval = criticalInterval.isFinite ? max(1, criticalInterval) : 60
    }

    private enum CodingKeys: String, CodingKey {
        case urgentBelowPercent, criticalBelowPercent, normalInterval, urgentInterval, criticalInterval
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            urgentBelowPercent: container.lenient(Int.self, .urgentBelowPercent) ?? 50,
            criticalBelowPercent: container.lenient(Int.self, .criticalBelowPercent) ?? 20,
            normalInterval: container.lenient(TimeInterval.self, .normalInterval) ?? 600,
            urgentInterval: container.lenient(TimeInterval.self, .urgentInterval) ?? 120,
            criticalInterval: container.lenient(TimeInterval.self, .criticalInterval) ?? 60
        )
    }
}
