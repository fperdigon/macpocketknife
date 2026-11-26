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
    var symlink = false
    var stagedVersion = "2.0.0"
    var stagedChannel = "stable"
    var stagedSHA = "unknown"
    func sha256(of file: URL) throws -> String { recorder.record("digest"); return String(repeating: "a", count: 64) }
    func createDirectory(_ directory: URL) throws { recorder.record("directory") }
    func remove(_ url: URL) throws { recorder.record(url.lastPathComponent.hasPrefix(".cam-backup-") ? "removeBackup" : "remove") }
    func copy(_ source: URL, to destination: URL) throws { recorder.record("copy") }
    func bundleMetadata(at app: URL) -> UpdateBundleMetadata? {
        recorder.record("identity")
        if app.lastPathComponent == "App.app" && !app.path.contains("synthetic-update/.cam-update")
            && !app.path.contains("mount") && !app.path.contains(".cam-update") {
            return UpdateBundleMetadata(identifier: "example.app", version: "1.0.0")
        }
        let id = badIdentity && app.path.contains("mount") ? "example.other" : "example.app"
        return UpdateBundleMetadata(identifier: id, version: stagedVersion, sha: stagedSHA, channel: stagedChannel)
    }
    func hasSymlinkInBundleSkeleton(at app: URL) -> Bool { recorder.record("symlinkCheck"); return symlink }
    func replace(_ current: URL, with staged: URL, backupName: String) throws { recorder.record("replace") }
    func restore(_ current: URL, from backup: URL) throws { recorder.record("restore") }
}

private struct FakeUpdateProcesses: UpdateProcessRunning {
    let recorder: InstallationRecorder
    var failSignatureAt = 0
    var failMount = false
    var identifier = "example.app"
    var flags = "0x10002(adhoc,runtime)"
    var runningSigner = "Signature=adhoc\n"
    var updateSigner = "Signature=adhoc\n"
    var installedSigner: String?
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
    func runCapturing(_ executable: String, arguments: [String]) throws -> String {
        if arguments.first == "-dvv" {
            recorder.record("signer")
            let isInstalledPath = arguments.last == fakeApp.path
            if isInstalledPath && !recorder.events.contains("replace") { return runningSigner }
            if isInstalledPath, let installedSigner { return installedSigner }
            return updateSigner
        }
        recorder.record("details")
        return "Executable=/x\nIdentifier=\(identifier)\nCodeDirectory v=20500 size=1 flags=\(flags) hashes=1\n"
    }
}

private let fakeUpdateRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("synthetic-update")
private let fakeApp = fakeUpdateRoot.appendingPathComponent("App.app")
private let stableExpectation = UpdateExpectation(tag: "v2.0.0", channel: .stable, runningVersion: "1.0.0")
private let goodDigest = "sha256:" + String(repeating: "a", count: 64)

private func installer(_ recorder: InstallationRecorder, files: FakeUpdateFiles? = nil,
                       processes: FakeUpdateProcesses? = nil) -> UpdateInstaller {
    UpdateInstaller(files: files ?? FakeUpdateFiles(recorder: recorder),
                    processes: processes ?? FakeUpdateProcesses(recorder: recorder))
}

private func tryInstall(_ installer: UpdateInstaller, digest: String? = goodDigest,
                        expectation: UpdateExpectation = stableExpectation) throws {
    try installer.install(dmg: fakeUpdateRoot, expectedDigest: digest, expectation: expectation,
                          over: fakeApp, work: fakeUpdateRoot)
}

@Test func updateDigestMismatchNeverMountsOrReplaces() {
    let recorder = InstallationRecorder()
    let sut = installer(recorder)
    #expect(throws: UpdateInstallError.checksumMismatch) {
        try tryInstall(sut, digest: "sha256:" + String(repeating: "b", count: 64))
    }
    #expect(recorder.events == ["digest"])
    for digest in ["", "md5:abc", "sha256:123"] {
        #expect(throws: UpdateInstallError.invalidDigest) { try sut.verify(file: fakeUpdateRoot, expected: digest) }
    }
}

@Test func updateMissingDigestIsRefusedBeforeAnyWork() {
    let recorder = InstallationRecorder()
    #expect(throws: UpdateInstallError.missingDigest) { try tryInstall(installer(recorder), digest: nil) }
    #expect(recorder.events.isEmpty)
}

@Test func updateInstallValidatesSwapsAndCleansUp() throws {
    let recorder = InstallationRecorder()
    try tryInstall(installer(recorder))
    #expect(recorder.events.filter { $0 == "signature" }.count == 3)
    #expect(recorder.events.filter { $0 == "details" }.count == 3)
    let replace = try #require(recorder.events.firstIndex(of: "replace"))
    let backupRemoved = try #require(recorder.events.firstIndex(of: "removeBackup"))
    #expect(replace < backupRemoved)
    #expect(recorder.events.contains("unmount"))
    #expect(!recorder.events.contains("restore"))
}

@Test func updateInstallFailureUnmountsAndRestoresBackup() {
    for failure in [1, 2, 3] {
        let recorder = InstallationRecorder()
        let sut = installer(recorder, processes: FakeUpdateProcesses(recorder: recorder, failSignatureAt: failure))
        #expect(throws: UpdateInstallError.signatureInvalid) { try tryInstall(sut) }
        #expect(recorder.events.contains("unmount"))
        #expect(recorder.events.contains("restore") == (failure == 3))
        #expect(!recorder.events.contains("removeBackup"))
    }
}

@Test func updateRejectsWrongSignatureIdentityOrMissingRuntime() {
    for processes in [FakeUpdateProcesses(recorder: InstallationRecorder(), identifier: "example.evil"),
                      FakeUpdateProcesses(recorder: InstallationRecorder(), flags: "0x2(adhoc)")] {
        let recorder = InstallationRecorder()
        let sut = installer(recorder, processes: FakeUpdateProcesses(recorder: recorder, identifier: processes.identifier,
                                                                      flags: processes.flags))
        #expect(throws: UpdateInstallError.signatureInvalid) { try tryInstall(sut) }
        #expect(!recorder.events.contains("replace"))
        #expect(recorder.events.contains("unmount"))
    }
}

@Test func updateRejectsWrongBundleAndUnmountsFailedAttach() {
    for mountFails in [false, true] {
        let recorder = InstallationRecorder()
        let sut = installer(recorder, files: FakeUpdateFiles(recorder: recorder, badIdentity: true),
                            processes: FakeUpdateProcesses(recorder: recorder, failMount: mountFails))
        #expect(throws: (any Error).self) { try tryInstall(sut) }
        #expect(recorder.events.contains("unmount"))
        #expect(!recorder.events.contains("replace"))
    }
}

@Test func updateRejectsSymlinkedBundle() {
    let recorder = InstallationRecorder()
    let sut = installer(recorder, files: FakeUpdateFiles(recorder: recorder, symlink: true))
    #expect(throws: UpdateInstallError.unsafeBundle) { try tryInstall(sut) }
    #expect(!recorder.events.contains("copy"))
    #expect(!recorder.events.contains("replace"))
    #expect(recorder.events.contains("unmount"))
}

@Test func updateRejectsVersionChannelAndDowngradeMismatches() {
    let cases: [(FakeUpdateFiles, UpdateExpectation)] = [
        (FakeUpdateFiles(recorder: InstallationRecorder(), stagedVersion: "2.0.1"), stableExpectation),
        (FakeUpdateFiles(recorder: InstallationRecorder(), stagedChannel: "nightly"), stableExpectation),
        (FakeUpdateFiles(recorder: InstallationRecorder(), stagedVersion: "2.0.0"),
         UpdateExpectation(tag: "v2.0.0", channel: .stable, runningVersion: "3.0.0")),
        (FakeUpdateFiles(recorder: InstallationRecorder(), stagedChannel: "nightly", stagedSHA: "1111111" + String(repeating: "0", count: 33)),
         UpdateExpectation(tag: "nightly-20261025-abcdef1", channel: .nightly, runningVersion: "1.0.0")),
        (FakeUpdateFiles(recorder: InstallationRecorder(), stagedChannel: "stable"),
         UpdateExpectation(tag: "nightly-20261025-abcdef1", channel: .nightly, runningVersion: "1.0.0")),
        (FakeUpdateFiles(recorder: InstallationRecorder()), UpdateExpectation(tag: "2.0.0", channel: .stable, runningVersion: "1.0.0")),
        (FakeUpdateFiles(recorder: InstallationRecorder()), UpdateExpectation(tag: "nightly-bad", channel: .nightly, runningVersion: "1.0.0"))
    ]
    for (files, expectation) in cases {
        let sut = UpdateInstaller(files: files, processes: FakeUpdateProcesses(recorder: files.recorder))
        #expect(throws: UpdateInstallError.unexpectedVersion) { try tryInstall(sut, expectation: expectation) }
        #expect(!files.recorder.events.contains("replace"))
        #expect(files.recorder.events.contains("unmount"))
    }
}

@Test func updateAcceptsMatchingNightly() throws {
    let recorder = InstallationRecorder()
    let sha = "abcdef1" + String(repeating: "0", count: 33)
    let sut = installer(recorder, files: FakeUpdateFiles(recorder: recorder, stagedChannel: "nightly", stagedSHA: sha))
    try tryInstall(sut, expectation: UpdateExpectation(tag: "nightly-20261025-abcdef1", channel: .nightly, runningVersion: "2.0.0"))
    #expect(recorder.events.contains("replace"))
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

private let sumURL = URL(string: "https://github.com/fperdigon/macpocketknife/releases/download/v2/MacPocketKnife-2.dmg.sha256")!

@Test func updateDigestResolverUsesAssetDigestThenChecksumFileElseRefuses() async throws {
    let hex = String(repeating: "c", count: 64)
    let dmg = ReleaseAsset(name: "MacPocketKnife-2.dmg", downloadURL: updateAssetURL)
    let sum = ReleaseAsset(name: "MacPocketKnife-2.dmg.sha256", downloadURL: sumURL)
    let release = ReleaseInfo(tag: "v2", name: "v2", prerelease: false, assets: [dmg, sum])
    func resolver(_ body: String, _ status: Int = 200) -> UpdateDigestResolver {
        UpdateDigestResolver { _ in (Data(body.utf8), status) }
    }
    let withDigest = ReleaseAsset(name: dmg.name, downloadURL: dmg.downloadURL, digest: "sha256:abc")
    #expect(try await resolver("").resolve(asset: withDigest, in: release) == "sha256:abc")
    #expect(try await resolver(hex.uppercased() + "  MacPocketKnife-2.dmg\n").resolve(asset: dmg, in: release) == "sha256:" + hex)
    #expect(try await resolver(hex).resolve(asset: dmg, in: release) == "sha256:" + hex)
    for body in ["zz", hex + "  Other.dmg", hex + " MacPocketKnife-2.dmg extra"] {
        await #expect(throws: UpdateInstallError.invalidDigest) { try await resolver(body).resolve(asset: dmg, in: release) }
    }
    await #expect(throws: UpdateInstallError.invalidDigest) {
        try await resolver(String(repeating: "a", count: 5000)).resolve(asset: dmg, in: release)
    }
    await #expect(throws: UpdateInstallError.downloadFailed(404)) { try await resolver("", 404).resolve(asset: dmg, in: release) }
    let noSum = ReleaseInfo(tag: "v2", name: "v2", prerelease: false, assets: [dmg])
    await #expect(throws: UpdateInstallError.missingDigest) { try await resolver(hex).resolve(asset: dmg, in: noSum) }
    let evil = ReleaseAsset(name: sum.name, downloadURL: URL(string: "https://evil.example/MacPocketKnife-2.dmg.sha256")!)
    let evilRelease = ReleaseInfo(tag: "v2", name: "v2", prerelease: false, assets: [dmg, evil])
    await #expect(throws: UpdateInstallError.missingDigest) { try await resolver(hex).resolve(asset: dmg, in: evilRelease) }
}

@Test func updateExpectationFromAvailableUpdate() {
    let release = ReleaseInfo(tag: "v2.0.0", name: "v2", prerelease: false)
    let asset = ReleaseAsset(name: "MacPocketKnife-2.dmg", downloadURL: updateAssetURL)
    let update = AvailableUpdate(channel: .stable, release: release, asset: asset, label: "2.0.0")
    #expect(UpdateExpectation(update: update, runningVersion: "1.0.0") == stableExpectation)
}

private func certificateSigner(_ name: String, hash: String = "ab12") -> String {
    "Authority=\(name)\ndesignated => identifier \"example.app\" and certificate leaf = H\"\(hash)\"\n"
}

private func signerInstaller(_ recorder: InstallationRecorder, running: String, update: String,
                             installed: String? = nil) -> UpdateInstaller {
    var processes = FakeUpdateProcesses(recorder: recorder)
    processes.runningSigner = running
    processes.updateSigner = update
    processes.installedSigner = installed
    return installer(recorder, processes: processes)
}

@Test func updateSignerParsing() {
    #expect(UpdateSigner.parse("Identifier=x\nSignature=adhoc\nTeamIdentifier=not set\n") == .adhoc)
    let parsed = UpdateSigner.parse("Authority=Leaf CN\nAuthority=Root CN\n(designated) certificate leaf = H\"ABCD\"\n")
    #expect(parsed == .certificate(authorities: ["Leaf CN", "Root CN"], leafHash: "abcd"))
    #expect(parsed?.marker == "Leaf CN>Root CN|abcd")
    #expect(UpdateSigner.parse("Authority=Only\n")?.marker == "Only|")
    #expect(UpdateSigner.adhoc.marker == nil)
    #expect(UpdateSigner.parse("") == nil)
    #expect(UpdateSigner.parse("Identifier=x\nAuthority=\n") == nil)
    #expect(UpdateSigner.parse("certificate leaf = H\"abcd\" no end") == nil)
    #expect(UpdateSigner.parse("Authority=A\ncertificate leaf = H\"abcd\nmissing quote\n")
        == .certificate(authorities: ["A"], leafHash: nil))
}

@Test func updateAdhocRunningAppMayInstallCertificateSignedUpdate() throws {
    let recorder = InstallationRecorder()
    try tryInstall(signerInstaller(recorder, running: "Signature=adhoc\n", update: certificateSigner("New Cert")))
    #expect(recorder.events.contains("replace"))
}

@Test func updateSameCertificateIsAllowed() throws {
    let recorder = InstallationRecorder()
    let cert = certificateSigner("My Cert")
    try tryInstall(signerInstaller(recorder, running: cert, update: cert))
    #expect(recorder.events.contains("replace"))
    #expect(recorder.events.filter { $0 == "signer" }.count == 4)
}

@Test func updateDifferentCertificateOrAdhocIsRefused() {
    let cases: [(String, String)] = [
        (certificateSigner("My Cert"), certificateSigner("Other Cert")),
        (certificateSigner("My Cert", hash: "aa"), certificateSigner("My Cert", hash: "bb")),
        (certificateSigner("My Cert"), "Signature=adhoc\n")
    ]
    for (running, update) in cases {
        let recorder = InstallationRecorder()
        let sut = signerInstaller(recorder, running: running, update: update)
        #expect(throws: UpdateInstallError.signerMismatch) { try tryInstall(sut) }
        #expect(!recorder.events.contains("copy"))
        #expect(!recorder.events.contains("replace"))
        #expect(recorder.events.contains("unmount"))
    }
}

@Test func updateInstalledCopyWithDifferentSignerRollsBack() {
    let recorder = InstallationRecorder()
    let cert = certificateSigner("My Cert")
    let sut = signerInstaller(recorder, running: cert, update: cert, installed: certificateSigner("Other"))
    #expect(throws: UpdateInstallError.signerMismatch) { try tryInstall(sut) }
    #expect(recorder.events.contains("restore"))
}

@Test func updateUnreadableSignerFailsClosed() {
    let unreadable = "garbage\n"
    let cases: [(String, String)] = [
        (unreadable, "Signature=adhoc\n"),
        ("", certificateSigner("My Cert")),
        (certificateSigner("My Cert"), unreadable)
    ]
    for (running, update) in cases {
        let recorder = InstallationRecorder()
        let sut = signerInstaller(recorder, running: running, update: update)
        #expect(throws: UpdateInstallError.signatureInvalid) { try tryInstall(sut) }
        #expect(!recorder.events.contains("replace"))
    }
}

@Test func updateSignerReadFailsClosedWhenRunnerCannotCapture() {
    struct NoCapture: UpdateProcessRunning { func run(_ executable: String, arguments: [String]) throws {} }
    #expect(UpdateSigner.read(of: "/x", using: NoCapture()) == nil)
}

@Test func updateInstallErrorMessagesAreDistinct() {
    let errors: [UpdateInstallError] = [.missingDigest, .unexpectedVersion, .unsafeBundle, .invalidBundle, .signatureInvalid,
                                        .signerMismatch]
    #expect(Set(errors.compactMap(\.errorDescription)).count == errors.count)
}

@Test func updateLocalFileSystemReadsMetadataAndDetectsSymlinks() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("mpk-update-" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let app = root.appendingPathComponent("A.app")
    try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": "x.y", "CFBundleShortVersionString": "1.2.3",
                                "CAMGitSHA": "ABC", "CAMBuildChannel": "nightly"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    let files = LocalUpdateFileSystem()
    #expect(files.bundleMetadata(at: app) == UpdateBundleMetadata(identifier: "x.y", version: "1.2.3", sha: "abc", channel: "nightly"))
    #expect(files.bundleMetadata(at: root) == nil)
    #expect(!files.hasSymlinkInBundleSkeleton(at: app))
    try fm.createSymbolicLink(at: app.appendingPathComponent("Contents/MacOS/tool"), withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
    #expect(files.hasSymlinkInBundleSkeleton(at: app))
    let link = root.appendingPathComponent("L.app")
    try fm.createSymbolicLink(at: link, withDestinationURL: app)
    #expect(files.hasSymlinkInBundleSkeleton(at: link))
}

@Test func updateProcessRunnerCapturesOutput() throws {
    let runner = UpdateProcessRunner(timeout: 5)
    #expect(try runner.runCapturing("/bin/sh", arguments: ["-c", "echo out; echo err >&2"]).contains("err"))
    #expect(throws: UpdateInstallError.operationFailed) { try runner.runCapturing("/usr/bin/false", arguments: []) }
}
