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
@testable import MacPocketKnifeCore

private let updateSHA = "abcdef1" + String(repeating: "0", count: 33)
private let updateBuild = BuildInfo(version: "1.0.0", sha: updateSHA, channel: "stable")
private let updateAssetURL = URL(string: "https://github.com/fperdigon/macpocketknife/releases/download/v2/MacPocketKnife-2.dmg")!

private func releaseJSON(tag: String = "v2.0.0", prerelease: Bool = false, draft: Bool = false,
                         date: String = "2026-10-25T00:00:00Z", asset: Bool = true) -> String {
    let assets = asset ? #"[{"name":"MacPocketKnife-2.dmg","browser_download_url":"\#(updateAssetURL)","digest":"sha256:abc"}]"# : "[]"
    return #"{"tag_name":"\#(tag)","prerelease":\#(prerelease),"draft":\#(draft),"published_at":"\#(date)","assets":\#(assets)}"#
}

private func fakeChecker(_ json: String, status: Int = 200) -> UpdateChecker {
    UpdateChecker { request in
        #expect(request.url?.host == "api.github.com")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        return (Data(json.utf8), status)
    }
}

@Test(arguments: [("1.2", "1.2.0", 0), ("v1.9", "1.10", -1), ("2", "1.99", 1)])
func updateNumericVersionComparison(a: String, b: String, expected: Int) {
    #expect(VersionCompare.compare(a, b) == expected)
}

@Test func updateBuildMetadata() {
    let info: [String: Any] = ["CFBundleShortVersionString": "1.2", "CAMGitSHA": updateSHA.uppercased(), "CAMBuildChannel": "nightly"]
    let build = BuildInfo(infoDictionary: info, bundleIdentifier: "example.app")
    #expect(build.version == "1.2")
    #expect(build.sha == updateSHA)
    #expect(build.shortSHA == "abcdef1")
    #expect(build.displayVersion == "1.2 (abcdef1) nightly")
    #expect(!build.isDevBuild)
    #expect(BuildInfo(infoDictionary: info, bundleIdentifier: nil).isDevBuild)
    #expect(BuildInfo(infoDictionary: nil, bundleIdentifier: nil).sha == "unknown")
    #expect(BuildInfo(infoDictionary: nil, bundleIdentifier: nil).displayVersion == "development build")
    #expect(BuildInfo(version: "1.2", sha: updateSHA, channel: "stable").displayVersion == "1.2")
    for sha in ["unknown", "abcdef1", String(repeating: "z", count: 40), ""] {
        #expect(BuildInfo(version: "1", sha: sha, channel: "nightly").isDevBuild)
    }
    #expect(BuildInfo(version: "1", sha: updateSHA, channel: "dev").isDevBuild)
}

@Test func updateStableOffersNewerAndKeepsDigest() async throws {
    let checker = UpdateChecker { request in
        #expect(request.url?.path == "/repos/fperdigon/macpocketknife/releases/latest")
        return (Data(releaseJSON().utf8), 200)
    }
    guard case .available(let update) = try await checker.check(channel: .stable, build: updateBuild) else {
        Issue.record("Expected an update"); return
    }
    #expect(update.asset.digest == "sha256:abc")
    #expect(update.label == "2.0.0")
    for version in ["2", "3.0"] {
        #expect(try await checker.check(channel: .stable, build: BuildInfo(version: version)) == .upToDate(current: version))
    }
}

@Test func updateNightlySelectsNewestValidReleaseAndComparesSHA() async throws {
    let json = "[" + [
        releaseJSON(),
        releaseJSON(tag: "nightly-20261024-1111111", prerelease: true, date: "2026-10-24T00:00:00Z"),
        releaseJSON(tag: "nightly-20261025-abcdef1", prerelease: true),
        releaseJSON(tag: "nightly-20261026-2222222", prerelease: true, draft: true, date: "2026-10-26T00:00:00Z"),
        releaseJSON(tag: "v3-beta", prerelease: true, date: "2026-10-27T00:00:00Z")
    ].joined(separator: ",") + "]"
    let checker = fakeChecker(json)
    #expect(try await checker.check(channel: .nightly, build: updateBuild) == .upToDate(current: "nightly abcdef1"))
    for build in [BuildInfo(version: "1"), BuildInfo(version: "1", sha: updateSHA, channel: "dev"),
                  BuildInfo(version: "1", sha: String(repeating: "2", count: 40), channel: "nightly")] {
        guard case .available(let update) = try await checker.check(channel: .nightly, build: build) else {
            Issue.record("Expected nightly offer"); continue
        }
        #expect(update.release.tag == "nightly-20261025-abcdef1")
    }
}

@Test func updateCheckerErrors() async {
    for (status, error) in [(403, UpdateChecker.CheckError.rateLimited), (429, .rateLimited),
                            (404, .noRelease(.stable)), (500, .http(500)), (401, .http(401))] {
        await #expect(throws: error) { try await fakeChecker("", status: status).check(channel: .stable, build: updateBuild) }
    }
    await #expect(throws: UpdateChecker.CheckError.invalidResponse) {
        try await fakeChecker("invalid").check(channel: .stable, build: updateBuild)
    }
    await #expect(throws: UpdateChecker.CheckError.noAsset("v2.0.0")) {
        try await fakeChecker(releaseJSON(asset: false)).check(channel: .stable, build: updateBuild)
    }
    await #expect(throws: UpdateChecker.CheckError.noRelease(.nightly)) {
        try await fakeChecker("[]").check(channel: .nightly, build: updateBuild)
    }
    await #expect(throws: UpdateChecker.CheckError.noRelease(.stable)) {
        try await fakeChecker(releaseJSON(draft: true)).check(channel: .stable, build: updateBuild)
    }
}

@Test func updateAssetAndSHAValidation() {
    #expect(UpdateChecker.selectAsset([ReleaseAsset(name: "MacPocketKnife-2.dmg", downloadURL: updateAssetURL)]) != nil)
    for name in ["Other-2.dmg", "MacPocketKnife-2.zip", "MacPocketKnife-../2.dmg"] {
        #expect(UpdateChecker.selectAsset([ReleaseAsset(name: name, downloadURL: updateAssetURL)]) == nil)
    }
    #expect(UpdateChecker.nightlySHA(of: ReleaseInfo(tag: "nightly-20261025-ABCDEF1", name: "Nightly", prerelease: true)) == "abcdef1")
    #expect(UpdateChecker.nightlySHA(of: ReleaseInfo(tag: "nightly-20261025-abcdef12", name: "Nightly", prerelease: true)) == nil)
}

private struct FakeUpdateClock: UpdateClock { let now: Date }

@Test func updateThrottleAndSkippedVersion() {
    let now = Date(timeIntervalSince1970: 100_000)
    let policy = UpdateCheckPolicy(clock: FakeUpdateClock(now: now))
    var prefs = UpdatePreferences()
    #expect(prefs.channel == .stable)
    #expect(prefs.automatically)
    #expect(policy.isDue(preferences: prefs, lastAttempt: nil))
    #expect(!policy.isDue(preferences: prefs, lastAttempt: now.addingTimeInterval(-86399)))
    #expect(policy.isDue(preferences: prefs, lastAttempt: now.addingTimeInterval(-86400)))
    #expect(!policy.isDue(preferences: prefs, lastAttempt: now.addingTimeInterval(1)))
    prefs.automatically = false
    #expect(!policy.isDue(preferences: prefs, lastAttempt: nil))
    prefs.skippedVersion = "v2"
    #expect(!policy.shouldOffer(tag: "v2", preferences: prefs, userInitiated: false))
    #expect(policy.shouldOffer(tag: "v2", preferences: prefs, userInitiated: true))
    #expect(policy.shouldOffer(tag: "v3", preferences: prefs, userInitiated: false))
}

private final class InstallationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func record(_ event: String) { lock.lock(); defer { lock.unlock() }; storage.append(event) }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

private struct FakeUpdateFiles: UpdateFileSystem {
    let recorder: InstallationRecorder
    var badIdentity = false
    func sha256(of file: URL) throws -> String { recorder.record("digest"); return String(repeating: "a", count: 64) }
    func createDirectory(_ directory: URL) throws { recorder.record("directory") }
    func remove(_ url: URL) throws { recorder.record(url.lastPathComponent.hasPrefix(".cam-backup-") ? "removeBackup" : "remove") }
    func copy(_ source: URL, to destination: URL) throws { recorder.record("copy") }
    func bundleIdentifier(at app: URL) -> String? {
        recorder.record("identity")
        return badIdentity && app.path.contains("mount") ? "example.other" : "example.app"
    }
    func replace(_ current: URL, with staged: URL, backupName: String) throws { recorder.record("replace") }
    func restore(_ current: URL, from backup: URL) throws { recorder.record("restore") }
}

private struct FakeUpdateProcesses: UpdateProcessRunning {
    let recorder: InstallationRecorder
    var failSignatureAt = 0
    var failMount = false
    func run(_ executable: String, arguments: [String]) throws {
        if arguments.first == "attach" {
            #expect(arguments.contains("-readonly"))
            recorder.record("mount")
            if failMount { throw UpdateInstallError.operationFailed }
        } else if arguments.first == "detach" { recorder.record("unmount") }
        else {
            #expect(arguments.starts(with: ["--verify", "--deep", "--strict"]))
            recorder.record("signature")
            if recorder.events.filter({ $0 == "signature" }).count == failSignatureAt { throw UpdateInstallError.signatureInvalid }
        }
    }
}

private let fakeUpdateRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("synthetic-update")

@Test func updateDigestMismatchNeverMountsOrReplaces() {
    let recorder = InstallationRecorder()
    let installer = UpdateInstaller(files: FakeUpdateFiles(recorder: recorder), processes: FakeUpdateProcesses(recorder: recorder))
    #expect(throws: UpdateInstallError.checksumMismatch) {
        try installer.install(dmg: fakeUpdateRoot, expectedDigest: "sha256:" + String(repeating: "b", count: 64),
                              over: fakeUpdateRoot.appendingPathComponent("App.app"), work: fakeUpdateRoot)
    }
    #expect(recorder.events == ["digest"])
    for digest in ["", "md5:abc", "sha256:123"] {
        #expect(throws: UpdateInstallError.invalidDigest) { try installer.verify(file: fakeUpdateRoot, expected: digest) }
    }
}

@Test func updateInstallValidatesSwapsAndCleansUp() throws {
    let recorder = InstallationRecorder()
    let installer = UpdateInstaller(files: FakeUpdateFiles(recorder: recorder), processes: FakeUpdateProcesses(recorder: recorder))
    try installer.install(dmg: fakeUpdateRoot, expectedDigest: "sha256:" + String(repeating: "a", count: 64),
                          over: fakeUpdateRoot.appendingPathComponent("App.app"), work: fakeUpdateRoot)
    #expect(recorder.events.filter { $0 == "signature" }.count == 3)
    let replace = try #require(recorder.events.firstIndex(of: "replace"))
    let backupRemoved = try #require(recorder.events.firstIndex(of: "removeBackup"))
    #expect(replace < backupRemoved)
    #expect(recorder.events.contains("unmount"))
    #expect(!recorder.events.contains("restore"))
}

@Test func updateInstallFailureUnmountsAndRestoresBackup() {
    for failure in [1, 2, 3] {
        let recorder = InstallationRecorder()
        let installer = UpdateInstaller(files: FakeUpdateFiles(recorder: recorder),
                                        processes: FakeUpdateProcesses(recorder: recorder, failSignatureAt: failure))
        #expect(throws: UpdateInstallError.signatureInvalid) {
            try installer.install(dmg: fakeUpdateRoot, expectedDigest: nil,
                                  over: fakeUpdateRoot.appendingPathComponent("App.app"), work: fakeUpdateRoot)
        }
        #expect(!recorder.events.contains("digest"))
        #expect(recorder.events.contains("unmount"))
        #expect(recorder.events.contains("restore") == (failure == 3))
        #expect(!recorder.events.contains("removeBackup"))
    }
}

@Test func updateRejectsWrongBundleAndUnmountsFailedAttach() {
    for mountFails in [false, true] {
        let recorder = InstallationRecorder()
        let installer = UpdateInstaller(files: FakeUpdateFiles(recorder: recorder, badIdentity: true),
                                        processes: FakeUpdateProcesses(recorder: recorder, failMount: mountFails))
        #expect(throws: (any Error).self) {
            try installer.install(dmg: fakeUpdateRoot, expectedDigest: nil,
                                  over: fakeUpdateRoot.appendingPathComponent("App.app"), work: fakeUpdateRoot)
        }
        #expect(recorder.events.contains("unmount"))
        #expect(!recorder.events.contains("replace"))
    }
}

@Test func updateRelaunchWaitsForQuitAndPassesPathAsArgument() {
    let url = fakeUpdateRoot.appendingPathComponent("App's Bundle.app")
    let helper = UpdateInstaller.relaunchProcess(appURL: url, processID: 42)
    #expect(helper.arguments?.last == url.path)
    #expect(helper.arguments?.contains("42") == true)
    #expect(helper.arguments?[1].contains("kill -0") == true)
}

private struct FakeUpdateDownloadTransport: UpdateDownloadTransport {
    let status: Int
    let recorder: InstallationRecorder
    func download(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, Int) {
        #expect(url == updateAssetURL)
        recorder.record("download")
        progress(0.5)
        return (fakeUpdateRoot.appendingPathComponent("download"), status)
    }
}

private struct FakeDownloadFiles: UpdateDownloadFileSystem {
    let recorder: InstallationRecorder
    func createDirectory(_ directory: URL) throws { recorder.record("directory") }
    func move(_ source: URL, to destination: URL) throws { recorder.record("move") }
    func remove(_ url: URL) throws { recorder.record("cleanup") }
}

@Test func updateDownloadProgressAndHTTPFailuresUseFakeTransport() async throws {
    for status in [200, 404, 500] {
        let recorder = InstallationRecorder()
        let downloader = UpdateDownloader(transport: FakeUpdateDownloadTransport(status: status, recorder: recorder),
                                          files: FakeDownloadFiles(recorder: recorder))
        let asset = ReleaseAsset(name: "MacPocketKnife-2.dmg", downloadURL: updateAssetURL)
        let progress: @Sendable (Double) -> Void = { recorder.record("progress-\($0)") }
        if status == 200 {
            #expect(try await downloader.download(asset, to: fakeUpdateRoot, progress: progress).lastPathComponent == "update.dmg")
            #expect(recorder.events == ["directory", "download", "progress-0.5", "move", "progress-1.0", "cleanup"])
        } else {
            await #expect(throws: UpdateInstallError.downloadFailed(status)) {
                try await downloader.download(asset, to: fakeUpdateRoot, progress: progress)
            }
            #expect(!recorder.events.contains("move"))
            #expect(recorder.events.last == "cleanup")
        }
    }
}

@Test func updateNightlySearchesLaterReleasePages() async throws {
    let firstPage = "[" + Array(repeating: releaseJSON(), count: 100).joined(separator: ",") + "]"
    let checker = UpdateChecker { request in
        let query = request.url?.query ?? ""
        return (Data((query.contains("page=2") ? "[" + releaseJSON(tag: "nightly-20261025-abcdef1", prerelease: true) + "]" : firstPage).utf8), 200)
    }
    #expect(try await checker.check(channel: .nightly, build: updateBuild) == .upToDate(current: "nightly abcdef1"))
}

@Test func updateProcessTimeout() {
    let runner = UpdateProcessRunner(timeout: 0.05)
    let start = Date()
    #expect(throws: UpdateInstallError.operationFailed) {
        try runner.run("/bin/sleep", arguments: ["30"])
    }
    #expect(Date().timeIntervalSince(start) < 5)
}

@Test func updateProcessExitStatus() throws {
    let runner = UpdateProcessRunner(timeout: 5)
    try runner.run("/usr/bin/true", arguments: [])
    #expect(throws: UpdateInstallError.operationFailed) {
        try runner.run("/usr/bin/false", arguments: [])
    }
}

@Test func updateProcessTimeoutKillsChildIgnoringTermination() {
    let runner = UpdateProcessRunner(timeout: 0.2)
    let start = Date()
    #expect(throws: UpdateInstallError.operationFailed) {
        // Ignored signals survive exec, so sleep also ignores SIGTERM.
        try runner.run("/bin/sh", arguments: ["-c", "trap '' TERM; exec /bin/sleep 30"])
    }
    #expect(Date().timeIntervalSince(start) < 5)
}
