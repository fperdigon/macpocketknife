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

@MainActor
public protocol SettingsStore: Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

@MainActor
public final class UserDefaultsSettingsStore: SettingsStore {
    public static let storageKey = "appSettings"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: Self.storageKey) else { return AppSettings() }
        guard let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            // Keep the unreadable payload so the next save cannot destroy it.
            let stamp = Int(Date().timeIntervalSince1970)
            defaults.set(data, forKey: "\(Self.storageKey).corrupt-\(stamp)")
            AppLog.shared.warning(category: "settings", "Settings unreadable; backed up and using defaults")
            return AppSettings()
        }
        return settings.validated()
    }

    public func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings.validated()) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
