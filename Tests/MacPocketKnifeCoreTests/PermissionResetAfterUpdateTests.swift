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
import Testing
import MacPocketKnifeCore

private final class ResetStorage: PermissionResetBuildStoring, @unchecked Sendable {
    var lastBuildID: String?
    var writes = 0
    var lastSigner: String?
    func store(buildID: String) { lastBuildID = buildID; writes += 1 }
    func store(signer: String?) { lastSigner = signer }
}

private final class ResetRunner: UpdateProcessRunning, @unchecked Sendable {
    let storage: ResetStorage
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var failures: Set<String> = []
    var delay: TimeInterval = 0
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }
    init(storage: ResetStorage) { self.storage = storage }
    func run(_ executable: String, arguments: [String]) throws {
        #expect(storage.writes == 0)
        #expect(executable == "/usr/bin/tccutil")
        lock.lock(); recorded.append(arguments); lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if failures.contains(arguments[1]) { throw CocoaError(.executableLoad) }
    }
}

@Test func permissionResetDecision() {
    #expect(PermissionResetAfterUpdate.shouldReset(storedBuildID: nil, currentBuildID: "a"))
    #expect(PermissionResetAfterUpdate.shouldReset(storedBuildID: "a", currentBuildID: "b"))
    #expect(!PermissionResetAfterUpdate.shouldReset(storedBuildID: "a", currentBuildID: "a"))
    #expect(!PermissionResetAfterUpdate.shouldReset(storedBuildID: nil, currentBuildID: ""))
}

@Test func permissionResetAttemptsOnlyOwnServicesThenStores() async {
    let storage = ResetStorage()
    let runner = ResetRunner(storage: storage)
    let reset = PermissionResetAfterUpdate(processes: runner, storage: storage, buildID: { "new" }, logger: .noop)
    #expect(await reset.run(enabled: true, channel: "nightly", environment: [:], arguments: []))
    #expect(runner.calls.sorted { $0[1] < $1[1] } == PermissionResetAfterUpdate.services.sorted().map {
        ["reset", $0, "io.github.fperdigon.macpocketknife"]
    })
    #expect(storage.lastBuildID == "new")
    #expect(storage.writes == 1)
    #expect(await !reset.run(enabled: true, channel: "nightly", environment: [:], arguments: []))
    #expect(runner.calls.count == 3)
    #expect(storage.writes == 1)
}

@Test(arguments: [false, true]) func permissionResetFailuresStillStore(allFail: Bool) async {
    let storage = ResetStorage()
    storage.lastBuildID = "old"
    let runner = ResetRunner(storage: storage)
    runner.failures = allFail ? Set(PermissionResetAfterUpdate.services) : ["Microphone"]
    let reset = PermissionResetAfterUpdate(processes: runner, storage: storage, buildID: { "new" }, logger: .noop)
    #expect(await reset.run(enabled: true, channel: "stable", environment: [:], arguments: []) == !allFail)
    #expect(runner.calls.count == 3)
    #expect(storage.lastBuildID == "new")
    #expect(storage.writes == 1)
}

@Test func permissionResetSkipsBeforeReadingBuild() async {
    let storage = ResetStorage()
    let runner = ResetRunner(storage: storage)
    let reset = PermissionResetAfterUpdate(processes: runner, storage: storage, buildID: {
        Issue.record("Skipped reset must not hash the executable")
        return "new"
    }, logger: .noop)
    #expect(await !reset.run(enabled: false, channel: "stable", environment: [:], arguments: []))
    #expect(await !reset.run(enabled: true, channel: "dev", environment: [:], arguments: []))
    for key in ["CI", "GITHUB_ACTIONS", "XCTestConfigurationFilePath"] {
        #expect(await !reset.run(enabled: true, channel: "stable", environment: [key: "1"], arguments: []))
    }
    for argument in ["Tests.xctest", "swiftpm-testing-helper"] {
        #expect(await !reset.run(enabled: true, channel: "stable", environment: [:], arguments: [argument]))
    }
    #expect(runner.calls.isEmpty)
    #expect(storage.writes == 0)
}

@Test func permissionResetHashFailureSkipsAndRetriesLater() async {
    let storage = ResetStorage()
    let runner = ResetRunner(storage: storage)
    let reset = PermissionResetAfterUpdate(processes: runner, storage: storage, buildID: {
        throw CocoaError(.fileReadNoSuchFile)
    }, logger: .noop)
    #expect(await !reset.run(enabled: true, channel: "stable", environment: [:], arguments: []))
    #expect(storage.writes == 0)
    #expect(runner.calls.isEmpty)
}

@Test func permissionResetRunsConcurrentlyAndSyncWrapperWorks() async {
    let storage = ResetStorage()
    let runner = ResetRunner(storage: storage)
    runner.delay = 0.6
    let reset = PermissionResetAfterUpdate(processes: runner, storage: storage, buildID: { "new" }, logger: .noop)
    let start = Date()
    #expect(await reset.run(enabled: true, channel: "stable", environment: [:], arguments: []))
    // Three serial 0.6 s resets would take at least 1.8 s; allow scheduling slack.
    #expect(Date().timeIntervalSince(start) < 1.5)
    #expect(runner.calls.count == 3)
    let storage2 = ResetStorage()
    let again = PermissionResetAfterUpdate(processes: ResetRunner(storage: storage2), storage: storage2,
                                           buildID: { "x" }, logger: .noop)
    let sync = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        DispatchQueue.global().async {
            continuation.resume(returning: again.run(enabled: true, channel: "stable", environment: [:], arguments: []) as Bool)
        }
    }
    #expect(sync)
}

@Test func permissionResetDefaultsStorage() throws {
    let name = "permission-reset-tests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let storage = UserDefaultsPermissionResetStore(defaults: defaults)
    #expect(storage.lastBuildID == nil)
    storage.store(buildID: "digest")
    #expect(storage.lastBuildID == "digest")
    #expect(defaults.string(forKey: "lastPermissionResetBuildID") == "digest")
}

@Test func permissionResetExecutableHash() throws {
    let digest = try PermissionResetAfterUpdate.currentBuildID()
    #expect(digest.count == 64)
    #expect(digest.allSatisfy { $0.isHexDigit })
}

@Test func permissionResetSettingsMigrationAndRoundTrip() throws {
    var settings = AppSettings()
    #expect(settings.resetPermissionsAfterUpdates)
    settings.resetPermissionsAfterUpdates = false
    let encoded = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(AppSettings.self, from: encoded) == settings)
    var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    json.removeValue(forKey: "resetPermissionsAfterUpdates")
    let legacy = try JSONSerialization.data(withJSONObject: json)
    #expect(try JSONDecoder().decode(AppSettings.self, from: legacy).resetPermissionsAfterUpdates)
    json["resetPermissionsAfterUpdates"] = NSNull()
    let nullValue = try JSONSerialization.data(withJSONObject: json)
    #expect(try JSONDecoder().decode(AppSettings.self, from: nullValue).resetPermissionsAfterUpdates)
}

@Test func permissionResetNotice() {
    let notice = NoticeComposer().composePermissionResetAfterUpdate()
    #expect(notice.kind == .info)
    #expect(notice.body == "MacPocketKnife was updated. Re-allow Screen Recording and Microphone in Record screen… > Permissions.")
}

@Test func permissionResetSignerDecision() {
    let shouldReset = PermissionResetAfterUpdate.shouldReset
    #expect(!shouldReset("a", "b", "cert", "cert"))
    #expect(shouldReset("a", "b", "cert", "other"))
    #expect(shouldReset("a", "b", nil, "cert"))
    #expect(shouldReset("a", "b", "cert", nil))
    #expect(shouldReset("a", "b", nil, nil))
    #expect(shouldReset(nil, "b", "cert", "cert"))
    #expect(shouldReset("a", "b", "", ""))
    #expect(!shouldReset("a", "a", "cert", "other"))
}

@Test func permissionResetSkippedWhenSameCertificateButMarkersUpdate() async {
    let storage = ResetStorage()
    storage.lastBuildID = "old"
    storage.lastSigner = "cert"
    let runner = ResetRunner(storage: storage)
    let reset = PermissionResetAfterUpdate(processes: runner, storage: storage, buildID: { "new" },
                                           signer: { "cert" }, logger: .noop)
    #expect(await !reset.run(enabled: true, channel: "stable", environment: [:], arguments: []))
    #expect(runner.calls.isEmpty)
    #expect(storage.lastBuildID == "new")
    #expect(storage.lastSigner == "cert")
}

@Test func permissionResetRunsOnceWhenSwitchingToCertificateThenSkips() async {
    let storage = ResetStorage()
    storage.lastBuildID = "adhoc-build"
    let runner = ResetRunner(storage: storage)
    let first = PermissionResetAfterUpdate(processes: runner, storage: storage, buildID: { "b1" },
                                           signer: { "cert" }, logger: .noop)
    #expect(await first.run(enabled: true, channel: "stable", environment: [:], arguments: []))
    #expect(storage.lastSigner == "cert")
    let second = PermissionResetAfterUpdate(processes: runner, storage: storage, buildID: { "b2" },
                                            signer: { "cert" }, logger: .noop)
    #expect(await !second.run(enabled: true, channel: "stable", environment: [:], arguments: []))
    #expect(runner.calls.count == 3)
    storage.writes = 0
    let rotated = PermissionResetAfterUpdate(processes: runner, storage: storage, buildID: { "b3" },
                                             signer: { "new-cert" }, logger: .noop)
    #expect(await rotated.run(enabled: true, channel: "stable", environment: [:], arguments: []))
    #expect(storage.lastSigner == "new-cert")
    // Back to ad-hoc clears the marker.
    storage.writes = 0
    let adhoc = PermissionResetAfterUpdate(processes: runner, storage: storage, buildID: { "b4" },
                                           signer: { nil }, logger: .noop)
    #expect(await adhoc.run(enabled: true, channel: "stable", environment: [:], arguments: []))
    #expect(storage.lastSigner == nil)
}

@Test func permissionResetDefaultSignerFailsClosedToReset() async {
    let storage = ResetStorage()
    storage.lastBuildID = "old"
    storage.lastSigner = "cert"
    let runner = ResetRunner(storage: storage)
    // The runner cannot capture, so the signer is unknown and the reset still happens.
    let reset = PermissionResetAfterUpdate(processes: runner, storage: storage, buildID: { "new" }, logger: .noop)
    #expect(await reset.run(enabled: true, channel: "stable", environment: [:], arguments: []))
    #expect(storage.lastSigner == nil)
}

@Test func permissionResetStoreKeepsSignerMarker() throws {
    let name = "permission-reset-signer-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let storage = UserDefaultsPermissionResetStore(defaults: defaults)
    #expect(storage.lastSigner == nil)
    storage.store(signer: "cert")
    #expect(storage.lastSigner == "cert")
    storage.store(signer: nil)
    #expect(storage.lastSigner == nil)
}
