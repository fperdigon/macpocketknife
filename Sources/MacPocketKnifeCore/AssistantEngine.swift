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

@preconcurrency import Darwin
@preconcurrency import Foundation

@MainActor
public final class AssistantEngine {
    public private(set) var power: PowerState
    public private(set) var blockers: [String] = []
    public var onChange: (@MainActor @Sendable () -> Void)?

    public var statusText: String {
        StatusLineFormatter.format(power: power, estimate: batteryEstimate)
    }

    public var blockersText: String? {
        StatusLineFormatter.blockersLine(blockers: blockers)
    }

    public private(set) var batteryEstimate: BatteryEstimate

    private let batteryEstimator: any BatteryEstimating
    private let powerMonitor: any PowerMonitoring
    private let assertionProvider: any AssertionProviding
    private let classifier: any ProcessClassifying
    private var policy: any PolicyEvaluating
    private var alerts: any AlertScheduling
    private let ownControllers: [CaffeinateController]
    private let notifier: CompositeNotifier
    private let terminator: any ProcessTerminating
    private let settings: any AssistantSettingsProviding
    private let clock: any AssistantClock
    private let tickScheduler: any AssistantTickScheduling
    private let tickInterval: TimeInterval
    private let ownPID: Int32
    private let currentUserID: UInt32
    private let composer: any NoticeComposing
    private var cancelTicks: (@Sendable () -> Void)?
    private var isRunning = false
    private var evaluating = false
    private var evaluationPending = false

    public init(
        powerMonitor: any PowerMonitoring, assertionProvider: any AssertionProviding,
        classifier: any ProcessClassifying,
        policyEngine: any PolicyEvaluating = PolicyEngine(),
        alertScheduler: any AlertScheduling = AlertScheduler(),
        caffeinateController: CaffeinateController,
        keepUnlockedController: CaffeinateController? = nil, channels: [any AlertNotifying],
        terminator: any ProcessTerminating, settings: any AssistantSettingsProviding,
        clock: any AssistantClock = SystemAssistantClock(),
        tickScheduler: any AssistantTickScheduling = AssistantTickScheduler(),
        tickInterval: TimeInterval = 10, ownPID: Int32 = getpid(),
        currentUserID: UInt32 = getuid(), composer: any NoticeComposing = NoticeComposer(),
        batteryEstimator: any BatteryEstimating = IOKitBatteryEstimator()
    ) {
        self.batteryEstimator = batteryEstimator
        batteryEstimate = batteryEstimator.currentEstimate()
        self.powerMonitor = powerMonitor
        self.assertionProvider = assertionProvider
        self.classifier = classifier
        policy = policyEngine
        alerts = alertScheduler
        ownControllers = [caffeinateController] + (keepUnlockedController.map { [$0] } ?? [])
        notifier = CompositeNotifier(channels: channels)
        self.terminator = terminator
        self.settings = settings
        self.clock = clock
        self.tickScheduler = tickScheduler
        self.tickInterval = tickInterval.isFinite ? max(0.1, tickInterval) : 10
        self.ownPID = ownPID
        self.currentUserID = currentUserID
        self.composer = composer
        power = powerMonitor.current
    }

    deinit { cancelTicks?() }

    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        powerMonitor.start { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                await self.evaluate()
            }
        }
        cancelTicks = tickScheduler.schedule(every: tickInterval) { [weak self] in
            guard let self, self.isRunning else { return }
            await self.evaluate()
        }
        await evaluate()
    }

    /// Refresh a read-only snapshot without running policy actions or delivering alerts.
    public func refreshStatusSnapshot() {
        power = powerMonitor.current
        batteryEstimate = batteryEstimator.currentEstimate()
        let assertions = assertionProvider.currentAssertions()
        blockers = SleepBlockerSummary.names(
            assertions: assertions, ownPID: ownPID,
            showOtherSleepBlockers: settings.settings.showOtherSleepBlockers
        )
    }

    public func stop() {
        isRunning = false
        evaluationPending = false
        cancelTicks?()
        cancelTicks = nil
        powerMonitor.stop()
    }

    /// Coalesce events arriving during asynchronous effects without overlapping policy runs.
    public func evaluate() async {
        guard !evaluating else {
            evaluationPending = true
            return
        }
        evaluating = true
        defer { evaluating = false }
        repeat {
            evaluationPending = false
            await evaluateOnce()
        } while evaluationPending && !Task.isCancelled
    }

    private func evaluateOnce() async {
        let preferences = settings.settings.validated()
        // Updating configuration preserves detection, retry history, and alert cadence.
        if var engine = policy as? PolicyEngine {
            engine.settings = preferences.policy
            policy = engine
        }
        if var scheduler = alerts as? AlertScheduler {
            scheduler.settings = preferences.alerts
            alerts = scheduler
        }
        power = powerMonitor.current
        batteryEstimate = batteryEstimator.currentEstimate()
        let now = clock.now
        var assertions = assertionProvider.currentAssertions().filter {
            !isOwnAssertion($0) || isActiveOwnAssertion($0)
        }
        for controller in ownControllers where controller.isActive {
            let reported = assertions.contains { $0.pid == ownPID && $0.name == controller.name }
            if !reported {
                assertions.append(SleepAssertion(
                    pid: ownPID, processName: AppInfo.name, type: controller.kind.assertionType,
                    name: controller.name
                ))
            }
        }
        let classified = assertions.map { assertion in
            ClassifiedAssertion(
                assertion: assertion, origin: classifier.origin(of: assertion.pid),
                isOwnedByCurrentUser: classifier.isOwnedByCurrentUser(
                    assertion.pid, currentUserID: currentUserID
                ),
                isOwnAppAssertion: isOwnAssertion(assertion)
            )
        }
        let actions = policy.evaluate(power: power, assertions: classified, now: now)
        var removedPIDs: Set<Int32> = []
        for action in actions {
            guard !Task.isCancelled else { return }
            switch action {
            case .terminate(let pid, let name, let reason):
                AppLog.shared.info(category: "policy", "Terminate process=\(name) reason=\(reason)")
                await notifier.deliver(Notice(
                    kind: .info, title: "Stopping keep-awake process",
                    body: "Stopping \(name) (PID \(pid))."
                ))
                let result = await terminator.terminate(pid: pid, expectedName: name)
                AppLog.shared.info(category: "policy", "Termination result=\(result)")
                switch result {
                case .terminated:
                    removedPIDs.insert(pid)
                    await notifier.deliver(composer.compose(action: action))
                case .notFound:
                    removedPIDs.insert(pid)
                    await notifier.deliver(Notice(
                        kind: .terminationSkipped, title: "Process no longer available",
                        body: "PID \(pid) is no longer the expected process."
                    ))
                case .failed:
                    await notifier.deliver(Notice(
                        kind: .terminationSkipped, title: "Termination failed",
                        body: "Could not stop \(name) (PID \(pid))."
                    ))
                }
            case .releaseOwnAssertion:
                AppLog.shared.info(category: "policy", "Release own assertions reason=batteryThreshold")
                await notifier.deliver(Notice(
                    kind: .info, title: "Releasing keep-awake",
                    body: "Battery threshold reached. Releasing the app's sleep assertion."
                ))
                for controller in ownControllers { controller.deactivate() }
                await notifier.deliver(composer.compose(action: action))
            case .notifyDetected:
                AppLog.shared.info(category: "policy", "Detected keep-awake assertion")
                await notifier.deliver(composer.compose(action: action))
            case .notifyTerminationSkipped(_, let reason):
                AppLog.shared.warning(category: "policy", "Termination skipped reason=\(reason)")
                await notifier.deliver(composer.compose(action: action))
            }
        }
        let remaining = assertions.filter {
            !removedPIDs.contains($0.pid) && (!isOwnAssertion($0) || isActiveOwnAssertion($0))
        }
        blockers = SleepBlockerSummary.names(
            assertions: remaining, ownPID: ownPID,
            showOtherSleepBlockers: preferences.showOtherSleepBlockers
        )
        let watched = remaining.filter { $0.isCaffeinate || isOwnAssertion($0) }
        var alertBlockers = watched.contains { $0.isCaffeinate } ? ["caffeinate"] : []
        let ownWatched = watched.filter(isOwnAssertion)
        let displaySleepType = SleepAssertionKind.displaySleep.assertionType
        if ownWatched.contains(where: { $0.type != displaySleepType }) {
            alertBlockers.append(SleepBlockerSummary.ownKeepAwakeName)
        }
        if ownWatched.contains(where: { $0.type == displaySleepType }) {
            alertBlockers.append(SleepBlockerSummary.ownKeepUnlockedName)
        }
        if let alert = alerts.evaluate(power: power, blockerActive: !watched.isEmpty, now: now) {
            await notifier.deliver(composer.compose(
                alert: alert, blockers: alertBlockers, estimate: batteryEstimate
            ))
        }
        onChange?()
    }

    private func isOwnAssertion(_ assertion: SleepAssertion) -> Bool {
        assertion.pid == ownPID && ownControllers.contains { $0.name == assertion.name }
    }

    private func isActiveOwnAssertion(_ assertion: SleepAssertion) -> Bool {
        assertion.pid == ownPID && ownControllers.contains { $0.name == assertion.name && $0.isActive }
    }
}
