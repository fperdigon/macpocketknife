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
    func store(buildID: String) { lastBuildID = buildID; writes += 1 }
}

private final class ResetRunner: UpdateProcessRunning, @unchecked Sendable {
    let storage: ResetStorage
    var calls: [[String]] = []
    var failures: Set<String> = []
    init(storage: ResetStorage) { self.storage = storage }
    func run(_ executable: String, arguments: [String]) throws {
        #expect(storage.writes == 0)
        #expect(executable == "/usr/bin/tccutil")
        calls.append(arguments)
        if failures.contains(arguments[1]) { throw CocoaError(.executableLoad) }
    }
}

@Test func permissionResetDecision() {
    #expect(PermissionResetAfterUpdate.shouldReset(storedBuildID: nil, currentBuildID: "a"))
    #expect(PermissionResetAfterUpdate.shouldReset(storedBuildID: "a", currentBuildID: "b"))
    #expect(!PermissionResetAfterUpdate.shouldReset(storedBuildID: "a", currentBuildID: "a"))
    #expect(!PermissionResetAfterUpdate.shouldReset(storedBuildID: nil, currentBuildID: ""))
}

@Test func permissionResetAttemptsOnlyOwnServicesThenStores() {
    let storage = ResetStorage()
    let runner = ResetRunner(storage: storage)
    let reset = PermissionResetAfterUpdate(processes: runner, storage: storage, buildID: { "new" }, logger: .noop)
    #expect(reset.run(enabled: true, channel: "nightly", environment: [:], arguments: []))
    #expect(runner.calls == PermissionResetAfterUpdate.services.map {
        ["reset", $0, "io.github.fperdigon.macpocketknife"]
    })
    #expect(storage.lastBuildID == "new")
    #expect(storage.writes == 1)
    #expect(!reset.run(enabled: true, channel: "nightly", environment: [:], arguments: []))
    #expect(runner.calls.count == 3)
    #expect(storage.writes == 1)
}

@Test(arguments: [false, true]) func permissionResetFailuresStillStore(allFail: Bool) {
    let storage = ResetStorage()
    storage.lastBuildID = "old"
    let runner = ResetRunner(storage: storage)
    runner.failures = allFail ? Set(PermissionResetAfterUpdate.services) : ["Microphone"]
    let reset = PermissionResetAfterUpdate(processes: runner, storage: storage, buildID: { "new" }, logger: .noop)
    #expect(reset.run(enabled: true, channel: "stable", environment: [:], arguments: []) == !allFail)
    #expect(runner.calls.count == 3)
    #expect(storage.lastBuildID == "new")
    #expect(storage.writes == 1)
}

@Test func permissionResetSkipsBeforeReadingBuild() {
    let storage = ResetStorage()
    let runner = ResetRunner(storage: storage)
    let reset = PermissionResetAfterUpdate(processes: runner, storage: storage, buildID: {
        Issue.record("Skipped reset must not hash the executable")
        return "new"
    }, logger: .noop)
    #expect(!reset.run(enabled: false, channel: "stable", environment: [:], arguments: []))
    #expect(!reset.run(enabled: true, channel: "dev", environment: [:], arguments: []))
    for key in ["CI", "GITHUB_ACTIONS", "XCTestConfigurationFilePath"] {
        #expect(!reset.run(enabled: true, channel: "stable", environment: [key: "1"], arguments: []))
    }
    for argument in ["Tests.xctest", "swiftpm-testing-helper"] {
        #expect(!reset.run(enabled: true, channel: "stable", environment: [:], arguments: [argument]))
    }
    #expect(runner.calls.isEmpty)
    #expect(storage.writes == 0)
}

@Test func permissionResetHashFailureSkipsAndRetriesLater() {
    let storage = ResetStorage()
    let runner = ResetRunner(storage: storage)
    let reset = PermissionResetAfterUpdate(processes: runner, storage: storage, buildID: {
        throw CocoaError(.fileReadNoSuchFile)
    }, logger: .noop)
    #expect(!reset.run(enabled: true, channel: "stable", environment: [:], arguments: []))
    #expect(storage.writes == 0)
    #expect(runner.calls.isEmpty)
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
