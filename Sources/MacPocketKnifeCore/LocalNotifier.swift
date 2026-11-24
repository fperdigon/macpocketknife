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
@preconcurrency import UserNotifications

@MainActor
public final class LocalNotifier: AlertNotifying {
    private let center: (any NotificationCenterProviding)?

    /// A missing bundle identifier must be checked before accessing the system center,
    /// which cannot be used safely by a bare executable. Inject a center in tests.
    public init(
        center: (any NotificationCenterProviding)? = nil,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        if bundleIdentifier == nil {
            self.center = nil
        } else {
            self.center = center ?? SystemNotificationCenterProvider()
        }
    }

    public func authorizationState() async -> AuthorizationState {
        guard let center else { return .unavailable }
        return await center.authorizationStatus()
    }

    @discardableResult
    public func requestAuthorizationIfNeeded() async -> AuthorizationState {
        guard let center else { return .unavailable }
        let state = await center.authorizationStatus()
        guard state == .notDetermined else { return state }
        do {
            return try await center.requestAuthorization() ? .authorized : .denied
        } catch {
            // Keep errors local and permit a later retry if authorization is still undetermined.
            return await center.authorizationStatus()
        }
    }

    /// Delivery never prompts for permission. The setup flow requests it explicitly.
    public func deliver(_ notice: Notice) async {
        AppLog.shared.info(category: "notice", "User notice kind=\(notice.kind.rawValue)")
        guard let center, await center.authorizationStatus() == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.threadIdentifier = "macpocketknife.\(notice.kind.rawValue)"
        content.sound = .default
        if let file = notice.recordingFile {
            content.categoryIdentifier = "recording-saved"
            content.userInfo = ["recordingFile": file.path]
        }
        switch notice.level {
        case .urgent, .critical: content.interruptionLevel = .timeSensitive
        case .normal, nil: content.interruptionLevel = .active
        }
        let identifier = notice.kind == .batteryAlert
            ? content.threadIdentifier : "\(content.threadIdentifier).\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        // Local delivery is best effort; denial or a center failure must not interrupt policy work.
        do {
            try await center.add(request)
        } catch {
            AppLog.shared.warning(category: "notice", "Delivery failed kind=\(notice.kind.rawValue) category=notificationCenter")
        }
    }
}
