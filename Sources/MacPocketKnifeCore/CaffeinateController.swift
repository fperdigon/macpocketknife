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

@MainActor
public final class CaffeinateController {
    public static let assertionName = "MacPocketKnife keep-awake"
    public static let keepAwakeStateKey = "keepAwakeState"

    public static let keepUnlockedAssertionName = "MacPocketKnife keep-unlocked"
    public static let keepUnlockedStateKey = "keepUnlockedState"

    public static func makeKeepAwake() -> CaffeinateController { CaffeinateController() }

    public static func makeKeepUnlocked() -> CaffeinateController {
        CaffeinateController(name: keepUnlockedAssertionName, kind: .displaySleep, stateStoreKey: keepUnlockedStateKey)
    }

    public let name: String
    public let kind: SleepAssertionKind

    public var isActive: Bool { assertion != nil }
    public private(set) var expiryDate: Date?
    /// Called on the main actor only when the active state changes.
    public var onChange: (@MainActor @Sendable (Bool) -> Void)?

    private let holder: any SleepAssertionHolding
    private let scheduler: any KeepAwakeScheduling
    private let store: any KeepAwakeStateStore
    private var assertion: OwnedAssertion?
    private var cancelExpiry: (@Sendable () -> Void)?
    private var expiryID: UUID?

    public init(
        holder: any SleepAssertionHolding = IOKitSleepAssertionHolder(),
        scheduler: any KeepAwakeScheduling = KeepAwakeScheduler(),
        store: (any KeepAwakeStateStore)? = nil,
        name: String? = nil,
        kind: SleepAssertionKind = .systemSleep,
        stateStoreKey: String? = nil
    ) {
        self.holder = holder
        self.scheduler = scheduler
        self.store = store ?? UserDefaultsKeepAwakeStateStore(
            defaults: .standard,
            key: stateStoreKey ?? CaffeinateController.keepAwakeStateKey
        )
        self.name = name ?? Self.assertionName
        self.kind = kind
    }

    deinit {
        cancelExpiry?()
    }

    /// Repeated activation preserves the existing assertion and deadline.
    /// Nonpositive or nonfinite durations leave the controller inactive.
    public func activate(duration: TimeInterval? = nil) {
        guard !isActive else { return }
        if let duration, !duration.isFinite || duration <= 0 {
            store.save(nil)
            return
        }
        start(expiringAt: duration.map { scheduler.now.addingTimeInterval($0) })
    }

    public func deactivate() {
        cancelExpiry?()
        cancelExpiry = nil
        expiryID = nil
        expiryDate = nil
        let wasActive = isActive
        assertion = nil
        store.save(nil)
        if wasActive {
            AppLog.shared.info(category: "power", "\(kind == .displaySleep ? "Keep-unlocked" : "Keep-awake") off")
            onChange?(false)
        }
    }

    public func toggle() {
        if isActive {
            deactivate()
        } else {
            activate()
        }
    }

    public func restoreIfNeeded() {
        guard !isActive, let state = store.load() else { return }
        guard state.isActive,
              state.expiryDate.map({ $0 > scheduler.now }) ?? true else {
            store.save(nil)
            return
        }
        start(expiringAt: state.expiryDate)
    }

    private func start(expiringAt date: Date?) {
        guard let handle = holder.create(name: name, kind: kind) else {
            AppLog.shared.warning(category: "power", "Sleep assertion activation failed")
            store.save(nil)
            return
        }
        assertion = OwnedAssertion(holder: holder, handle: handle)
        expiryDate = date
        store.save(KeepAwakeState(isActive: true, expiryDate: date))
        if let date {
            let id = UUID()
            expiryID = id
            cancelExpiry = scheduler.schedule(at: date) { [weak self] in
                guard let self, self.expiryID == id else { return }
                self.deactivate()
            }
        }
        AppLog.shared.info(category: "power", "\(kind == .displaySleep ? "Keep-unlocked" : "Keep-awake") on")
        onChange?(true)
    }

    /// Releases the assertion on deactivation or controller destruction, while
    /// preserving saved state for restoration after the app exits.
    private final class OwnedAssertion: Sendable {
        let holder: any SleepAssertionHolding
        let handle: SleepHandle

        init(holder: any SleepAssertionHolding, handle: SleepHandle) {
            self.holder = holder
            self.handle = handle
        }

        deinit {
            holder.release(handle)
        }
    }
}
