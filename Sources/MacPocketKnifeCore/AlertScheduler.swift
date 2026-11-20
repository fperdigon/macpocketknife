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

@preconcurrency import Foundation

public struct AlertScheduler: AlertScheduling {
    public var settings: AlertSettings

    private var previousLevel: AlertLevel?
    private var lastAlertTime: Date?

    public init(settings: AlertSettings = AlertSettings()) {
        self.settings = settings
    }

    /// Ineligible evaluations reset the session, including an unknown battery level.
    /// Level changes never restart the interval unless an alert is emitted.
    public mutating func evaluate(
        power: PowerState, blockerActive: Bool, now: Date
    ) -> BatteryAlert? {
        guard power.source == .battery, blockerActive,
              let percent = power.batteryPercent else {
            if previousLevel != nil {
                AppLog.shared.info(category: "battery", "Alert level reset reason=ineligible")
            }
            previousLevel = nil
            lastAlertTime = nil
            return nil
        }

        let level: AlertLevel
        let interval: TimeInterval
        if percent < settings.criticalBelowPercent {
            level = .critical
            interval = settings.criticalInterval
        } else if percent < settings.urgentBelowPercent {
            level = .urgent
            interval = settings.urgentInterval
        } else {
            level = .normal
            interval = settings.normalInterval
        }

        if previousLevel != level {
            AppLog.shared.info(category: "battery", "Alert level changed level=\(level)")
        }
        let escalated = previousLevel.map { level > $0 } ?? false
        previousLevel = level
        if let lastAlertTime, !escalated,
           now.timeIntervalSince(lastAlertTime) < interval {
            return nil
        }

        lastAlertTime = now
        return BatteryAlert(level: level, batteryPercent: percent)
    }
}
