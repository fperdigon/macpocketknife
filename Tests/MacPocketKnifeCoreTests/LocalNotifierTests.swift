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

import Testing
import UserNotifications
import MacPocketKnifeCore

private enum FakeNotificationError: Error {
    case unavailable
}

@MainActor
private final class FakeNotificationCenter: NotificationCenterProviding {
    var status: AuthorizationState
    var grantsAuthorization = true
    var failsAuthorization = false
    var failsDelivery = false
    private(set) var statusChecks = 0
    private(set) var authorizationRequests = 0
    private(set) var requests: [UNNotificationRequest] = []
    private(set) var pending: [String: UNNotificationRequest] = [:]

    init(status: AuthorizationState = .authorized) {
        self.status = status
    }

    func authorizationStatus() async -> AuthorizationState {
        statusChecks += 1
        return status
    }

    func requestAuthorization() async throws -> Bool {
        authorizationRequests += 1
        if failsAuthorization { throw FakeNotificationError.unavailable }
        status = grantsAuthorization ? .authorized : .denied
        return grantsAuthorization
    }

    func add(_ request: UNNotificationRequest) async throws {
        requests.append(request)
        if failsDelivery { throw FakeNotificationError.unavailable }
        pending[request.identifier] = request
    }
}

private let localTestBundleIdentifier = "example.notifications"

@Test(arguments: [AlertLevel.normal, .urgent, .critical, nil] as [AlertLevel?])
@MainActor func localNotifierMapsLevelsAndDefaultSound(level: AlertLevel?) async throws {
    let center = FakeNotificationCenter()
    let notifier: any AlertNotifying = LocalNotifier(
        center: center, bundleIdentifier: localTestBundleIdentifier
    )
    await notifier.deliver(Notice(kind: .batteryAlert, title: "Battery alert", body: "Battery at 25%.", level: level))
    let request = try #require(center.requests.first)
    #expect(request.content.title == "Battery alert")
    #expect(request.content.body == "Battery at 25%.")
    #expect(request.content.sound == UNNotificationSound.default)
    #expect(request.content.interruptionLevel == (level == .urgent || level == .critical ? .timeSensitive : .active))
    #expect(request.trigger == nil)
    #expect(center.authorizationRequests == 0)
}

@Test(arguments: [AuthorizationState.authorized, .denied, .unavailable])
@MainActor func localNotifierDoesNotRequestAlreadyDeterminedAuthorization(state: AuthorizationState) async {
    let center = FakeNotificationCenter(status: state)
    let notifier = LocalNotifier(center: center, bundleIdentifier: localTestBundleIdentifier)
    #expect(await notifier.authorizationState() == state)
    #expect(await notifier.requestAuthorizationIfNeeded() == state)
    #expect(center.authorizationRequests == 0)
}

@Test(arguments: [false, true])
@MainActor func localNotifierRequestsAuthorizationOnlyWhenNeeded(granted: Bool) async {
    let center = FakeNotificationCenter(status: .notDetermined)
    center.grantsAuthorization = granted
    let notifier = LocalNotifier(center: center, bundleIdentifier: localTestBundleIdentifier)
    #expect(await notifier.authorizationState() == .notDetermined)
    let expected: AuthorizationState = granted ? .authorized : .denied
    #expect(await notifier.requestAuthorizationIfNeeded() == expected)
    #expect(await notifier.requestAuthorizationIfNeeded() == expected)
    #expect(await notifier.authorizationState() == expected)
    #expect(center.authorizationRequests == 1)
}

@Test(arguments: [AuthorizationState.denied, .notDetermined, .unavailable])
@MainActor func localNotifierSkipsDeliveryWithoutAuthorization(state: AuthorizationState) async {
    let center = FakeNotificationCenter(status: state)
    let notifier = LocalNotifier(center: center, bundleIdentifier: localTestBundleIdentifier)
    await notifier.deliver(Notice(kind: .info, title: "Keep-awake", body: "Sleep assertion released."))
    #expect(center.requests.isEmpty)
    #expect(center.authorizationRequests == 0)
}

@Test @MainActor func localNotifierHandlesAuthorizationAndDeliveryFailures() async {
    let center = FakeNotificationCenter(status: .notDetermined)
    center.failsAuthorization = true
    let notifier = LocalNotifier(center: center, bundleIdentifier: localTestBundleIdentifier)
    #expect(await notifier.requestAuthorizationIfNeeded() == .notDetermined)
    center.failsAuthorization = false
    #expect(await notifier.requestAuthorizationIfNeeded() == .authorized)
    center.failsDelivery = true
    await notifier.deliver(Notice(kind: .info, title: "Keep-awake", body: "Sleep assertion released."))
    #expect(center.requests.count == 1)
    #expect(center.pending.isEmpty)
}

@Test @MainActor func localNotifierWithoutBundleNeverAccessesCenter() async {
    let center = FakeNotificationCenter()
    let notifier = LocalNotifier(center: center, bundleIdentifier: nil)
    #expect(await notifier.authorizationState() == .unavailable)
    #expect(await notifier.requestAuthorizationIfNeeded() == .unavailable)
    await notifier.deliver(Notice(kind: .info, title: "Keep-awake", body: "Sleep assertion released."))
    #expect(center.statusChecks == 0)
    #expect(center.authorizationRequests == 0)
    #expect(center.requests.isEmpty)

    // Also exercise production construction: this must not access UNUserNotificationCenter.current().
    let bareExecutableNotifier = LocalNotifier(bundleIdentifier: nil)
    #expect(await bareExecutableNotifier.authorizationState() == .unavailable)
    #expect(await bareExecutableNotifier.requestAuthorizationIfNeeded() == .unavailable)
    await bareExecutableNotifier.deliver(Notice(kind: .info, title: "Keep-awake", body: "Sleep assertion released."))
}

@Test @MainActor func localNotifierReplacesBatteryAlertAcrossLevelsAndInstances() async throws {
    let center = FakeNotificationCenter()
    let first = LocalNotifier(center: center, bundleIdentifier: localTestBundleIdentifier)
    let second = LocalNotifier(center: center, bundleIdentifier: localTestBundleIdentifier)
    let composer = NoticeComposer()
    await first.deliver(composer.compose(alert: BatteryAlert(level: .normal, batteryPercent: 80)))
    let latest = composer.compose(alert: BatteryAlert(level: .critical, batteryPercent: 15))
    await second.deliver(latest)
    #expect(center.requests.count == 2)
    #expect(center.requests[0].identifier == center.requests[1].identifier)
    #expect(center.pending.count == 1)
    #expect(try #require(center.pending.values.first).content.body == latest.body)
}

@Test @MainActor func localNotifierGroupsByKindAndPreservesSeparateActionNotices() async throws {
    let center = FakeNotificationCenter()
    let notifier = LocalNotifier(center: center, bundleIdentifier: localTestBundleIdentifier)
    let kinds: [NoticeKind] = [.batteryAlert, .keepAwakeDetected, .processTerminated, .terminationSkipped, .info]
    for kind in kinds {
        let notice = Notice(kind: kind, title: "Status", body: "Status updated.")
        await notifier.deliver(notice)
        await notifier.deliver(notice)
    }
    #expect(center.requests.count == kinds.count * 2)
    var threads: Set<String> = []
    for (index, kind) in kinds.enumerated() {
        let first = center.requests[index * 2]
        let second = center.requests[index * 2 + 1]
        #expect(!first.content.threadIdentifier.isEmpty)
        #expect(first.content.threadIdentifier == second.content.threadIdentifier)
        #expect((first.identifier == second.identifier) == (kind == .batteryAlert))
        threads.insert(first.content.threadIdentifier)
    }
    #expect(threads.count == kinds.count)
    #expect(center.pending.count == 9)
}

@Test(arguments: [false, true])
@MainActor func recordingSaveNotificationCarriesFinderAction(audio: Bool) async throws {
    let center = FakeNotificationCenter()
    let notifier = LocalNotifier(center: center, bundleIdentifier: localTestBundleIdentifier)
    let ext = audio ? "m4a" : "mp4"
    let file = URL(fileURLWithPath: "/Movies/Recording example.\(ext)")
    let composer = NoticeComposer()
    let notice = audio ? composer.composeAudioRecording(savedFile: file) : composer.composeScreenRecording(savedFile: file)
    await notifier.deliver(notice)
    let content = try #require(center.requests.first?.content)
    #expect(content.categoryIdentifier == "recording-saved")
    #expect(content.userInfo["recordingFile"] as? String == file.path)
    #expect(center.authorizationRequests == 0)
}
