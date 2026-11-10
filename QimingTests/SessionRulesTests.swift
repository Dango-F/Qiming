import Foundation
import Testing

@Suite("Power event fast path and deferred refresh")
@MainActor struct PowerEventTests {
    @Test func fastSupplyReadingPreservesUnknownState() {
        #expect(SystemPower.supplyState(timeRemaining: -2) == true)
        #expect(SystemPower.supplyState(timeRemaining: 0) == false)
        #expect(SystemPower.supplyState(timeRemaining: 3600) == false)
        #expect(SystemPower.supplyState(timeRemaining: -1) == nil)
        #expect(SystemPower.supplyState(timeRemaining: .nan) == nil)
        #expect(SystemPower.supplyState(timeRemaining: .infinity) == nil)
    }

    @Test func lateHelperSamplesCannotRearmAnAlreadyNotifiedDisconnect() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var source = PowerSourceTracker(onAC: true, checkedAt: start)
        let first = source.disconnected(onAC: false, checkedAt: start.addingTimeInterval(1))
        let stale = source.disconnected(onAC: true, checkedAt: start.addingTimeInterval(0.5))
        #expect(first && !stale)
        #expect(source.lastOnAC == false)
        let repeated = source.disconnected(onAC: false, checkedAt: start.addingTimeInterval(1.1))
        let unknown = source.disconnected(onAC: nil, checkedAt: start.addingTimeInterval(1.2))
        #expect(!repeated && !unknown)
        #expect(source.lastOnAC == false)
        let connected = source.disconnected(onAC: true, checkedAt: start.addingTimeInterval(2))
        let second = source.disconnected(onAC: false, checkedAt: start.addingTimeInterval(3))
        #expect(!connected && second)
    }

    @Test func eventsWhileBusyAreRetainedAndCoalesced() async throws {
        var busy = true
        var calls = 0
        let refresh = PowerEventRefresh(isBlocked: { busy }, refresh: { calls += 1 })
        for _ in 0..<20 { refresh.request() }
        try await Task.sleep(for: .milliseconds(120))
        #expect(calls == 0)
        busy = false
        try await Task.sleep(for: .milliseconds(180))
        #expect(calls == 1)
    }

    @Test func anEventDuringARefreshIsProcessedWithoutWaitingForTheLease() async throws {
        var calls = 0
        var pending: CheckedContinuation<Void, Never>?
        let refresh = PowerEventRefresh(isBlocked: { false }, refresh: {
            calls += 1
            if calls == 1 { await withCheckedContinuation { pending = $0 } }
        })
        refresh.request()
        for _ in 0..<100 where pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(calls == 1)
        for _ in 0..<20 { refresh.request() }
        pending?.resume()
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls == 2)
    }
}

@Suite("Deadline synchronization without host power changes")
@MainActor struct SessionDeadlineTests {
    @Test func countdownKeepsLastSecondAndElapsedTimeStillRoundsDown() {
        #expect(SessionTiming.clock(0.01, roundingUp: true) == "00:00:01")
        #expect(SessionTiming.clock(0.99, roundingUp: true) == "00:00:01")
        #expect(SessionTiming.clock(60.01, roundingUp: true) == "00:01:01")
        #expect(SessionTiming.clock(0, roundingUp: true) == "00:00:00")
        #expect(SessionTiming.clock(-0.1, roundingUp: true) == "00:00:00")
        #expect(SessionTiming.clock(60.99) == "00:01:00")
    }

    @Test func expiryIsCheckedWithoutWaitingForTheLeaseOrOpeningAPanel() async throws {
        let session = Session(mode: .closed, deadline: Date().addingTimeInterval(0.05), policy: ProtectionPolicy())
        var calls: [UUID] = []
        let monitor = SessionDeadlineMonitor { id, deadline in
            #expect(Date() >= deadline)
            calls.append(id)
            return false
        }
        monitor.update(session)
        monitor.update(session)
        try await Task.sleep(for: .milliseconds(250))
        #expect(calls == [session.id])
        monitor.update(nil)
    }

    @Test func changedDeadlinesAndCancelledTimersCannotEndTheNextSession() async throws {
        var session = Session(mode: .closed, deadline: Date().addingTimeInterval(0.04), policy: ProtectionPolicy())
        var calls = 0
        let monitor = SessionDeadlineMonitor { _, _ in calls += 1; return false }
        monitor.update(session)
        session.deadline = Date().addingTimeInterval(1)
        monitor.update(session)
        try await Task.sleep(for: .milliseconds(150))
        #expect(calls == 0)
        session.deadline = nil
        monitor.update(session)
        session.id = UUID()
        session.deadline = Date().addingTimeInterval(0.04)
        monitor.update(session)
        monitor.update(nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(calls == 0)
    }

    @Test func busyExpiryRetriesPromptlyAndStopsAfterAConfirmedReply() async throws {
        let session = Session(mode: .closed, deadline: Date().addingTimeInterval(-1), policy: ProtectionPolicy())
        var calls = 0
        let monitor = SessionDeadlineMonitor { _, _ in
            calls += 1
            return calls < 3
        }
        monitor.update(session)
        try await Task.sleep(for: .milliseconds(500))
        #expect(calls == 3)
        monitor.update(nil)
    }

    @Test func anOldInFlightReplyCannotRearmACancelledDeadline() async throws {
        let session = Session(mode: .closed, deadline: Date().addingTimeInterval(-1), policy: ProtectionPolicy())
        var calls = 0
        var pending: CheckedContinuation<Bool, Never>?
        let monitor = SessionDeadlineMonitor { _, _ in
            calls += 1
            return await withCheckedContinuation { pending = $0 }
        }
        monitor.update(session)
        for _ in 0..<100 where pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(calls == 1)
        monitor.update(nil)
        pending?.resume(returning: true)
        try await Task.sleep(for: .milliseconds(200))
        #expect(calls == 1)
    }
}

@Suite("Notification triggers without host power or permission changes")
struct SessionNotificationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func active(_ mode: DisplayMode = .always) -> HelperStatus {
        HelperStatus(session: Session(mode: mode, policy: ProtectionPolicy()),
            power: PowerSnapshot(onAC: true, battery: 80), phase: "active",
            systemAssertion: true, displayAssertion: true, manualDisplayOff: false,
            screenSaverPaused: mode == .always, recovery: [])
    }

    @Test(arguments: [EndReason.manual, .expired, .lowBattery, .thermal, .locked, .sleep, .conflict, .disconnected, .failure])
    func eachConfirmedSessionEndProducesItsOwnReason(reason: EndReason) {
        let previous = active(.closed)
        var ended = previous
        ended.session = nil
        ended.phase = "idle"
        ended.endReason = reason
        #expect(SessionNotificationRules.endedSession(previous: previous.session, status: ended) == reason)
        #expect(SessionNotificationRules.endedSession(previous: nil, status: ended) == nil)
        #expect(SessionNotificationRules.endedSession(previous: previous.session, status: previous) == nil)
    }

    @Test(arguments: [EndReason.locked, .sleep])
    func clientRequestedStopKeepsTheActualCause(reason: EndReason) {
        let previous = active()
        var ended = previous
        ended.session = nil
        ended.endReason = .manual
        #expect(SessionNotificationRules.endedSession(previous: previous.session, status: ended, requestedReason: reason) == reason)
        ended.endReason = .thermal
        #expect(SessionNotificationRules.endedSession(previous: previous.session, status: ended, requestedReason: reason) == .thermal)
    }

    @Test func warmthOnlyWarnsOnEntryWithASession() {
        #expect(SessionNotificationRules.warnsAboutWarmth(previous: 0, next: 1, hasSession: true))
        #expect(!SessionNotificationRules.warnsAboutWarmth(previous: 1, next: 1, hasSession: true))
        #expect(!SessionNotificationRules.warnsAboutWarmth(previous: 0, next: 1, hasSession: false))
        #expect(!SessionNotificationRules.warnsAboutWarmth(previous: 1, next: 2, hasSession: true))
    }

    @Test func reminderFollowsIntervalAndRequiresActualAlwaysOnAssertions() {
        let status = active()
        let previousReminder = now.addingTimeInterval(-3600)
        #expect(!SessionNotificationRules.reminderDue(status: status, lastReminder: previousReminder,
                                                     now: now.addingTimeInterval(-1), intervalMinutes: 60))
        #expect(SessionNotificationRules.reminderDue(status: status, lastReminder: previousReminder, now: now, intervalMinutes: 60))
        #expect(!SessionNotificationRules.reminderDue(status: status, lastReminder: now, now: now, intervalMinutes: 60))
        var waiting = status
        waiting.phase = "waiting"
        #expect(!SessionNotificationRules.reminderDue(status: waiting, lastReminder: previousReminder, now: now, intervalMinutes: 60))
        var off = status
        off.manualDisplayOff = true
        #expect(!SessionNotificationRules.reminderDue(status: off, lastReminder: previousReminder, now: now, intervalMinutes: 60))
        off = status
        off.displayAssertion = false
        #expect(!SessionNotificationRules.reminderDue(status: off, lastReminder: previousReminder, now: now, intervalMinutes: 60))
        #expect(!SessionNotificationRules.reminderDue(status: active(.closed), lastReminder: previousReminder,
                                                     now: now, intervalMinutes: 60))
    }
}

@Test func firstDisconnectIsDetectedAndRepeatedOrUnknownReadingsDoNotDuplicateIt() {
    var source = PowerSourceTracker(onAC: true)
    let observations: [Bool?] = [false, false, nil, true, nil, false]
    let changes = observations.map { source.disconnected(onAC: $0) }
    #expect(changes == [true, false, false, false, false, true])
}

@Test func startingOnBatteryOrWithUnknownSupplyDoesNotInventADisconnect() {
    var source = PowerSourceTracker(onAC: nil)
    let observations: [Bool?] = [nil, false, false, true, false]
    let changes = observations.map { source.disconnected(onAC: $0) }
    #expect(changes == [false, false, false, false, true])
}

@Test func lidSleepNotificationDoesNotCancelLidPolicies() {
    for mode in [DisplayMode.closed, .displayOnly] {
        #expect(!SessionRules.endsOnSleep(mode, lidClosed: true))
        #expect(SessionRules.endsOnSleep(mode, lidClosed: false))
        #expect(SessionRules.endsOnSleep(mode, lidClosed: nil))
    }
    #expect(SessionRules.endsOnSleep(.always, lidClosed: true))
}

@Test func externalAssertionsKeepBothKindsAndIgnoreInactiveOrOwnedEntries() {
    let assertions: [AnyHashable: Any] = [1: [
        ["Process Name": "coreaudiod", "AssertType": "NoIdleSleepAssertion",
         "AssertTrueType": "PreventUserIdleSystemSleep", "AssertLevel": 255],
        ["Process Name": "coreaudiod", "AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 255],
        ["Process Name": "coreaudiod", "AssertType": "NoDisplaySleepAssertion", "AssertLevel": 255],
        ["Process Name": "Backup", "AssertType": "PreventSystemSleep", "AssertLevel": 255],
        ["Process Name": "Inactive", "AssertType": "PreventUserIdleDisplaySleep", "AssertLevel": 0],
        ["Process Name": "QimingHelper", "AssertType": "PreventUserIdleDisplaySleep", "AssertLevel": 255],
        ["Process Name": "WindowServer", "AssertType": "UserIsActive", "AssertLevel": 255],
    ]]
    #expect(Set(SystemPower.classifySleepBlockers(assertions)) == [
        ExternalSleepBlocker(process: "coreaudiod", kind: .idleSystem),
        ExternalSleepBlocker(process: "coreaudiod", kind: .idleDisplay),
        ExternalSleepBlocker(process: "Backup", kind: .system),
    ])
}

@Suite("Session protection and display policy")
struct SessionRulesTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func session(deadline: Date? = nil, policy: ProtectionPolicy = ProtectionPolicy()) -> Session {
        Session(mode: .closed, deadline: deadline, policy: policy)
    }
    private func power(ac: Bool? = true, battery: Int? = 80, lid: Bool? = false, thermal: Int = 0) -> PowerSnapshot {
        PowerSnapshot(onAC: ac, battery: battery, charging: ac, lidClosed: lid, sleepDisabled: false, thermal: thermal)
    }

    @Test func deadlineTakesPrecedenceOverPowerResume() {
        let session = session(deadline: now)
        #expect(SessionRules.evaluate(session, power: power(), now: now) == .stop(.expired))
        #expect(SessionRules.evaluate(session, power: power(ac: false), now: now) == .stop(.expired))
    }
    @Test(arguments: [2, 3]) func heatProtectionAppliesOnAnyPowerSource(thermal: Int) {
        #expect(SessionRules.evaluate(session(), power: power(thermal: thermal), now: now) == .stop(.thermal))
        #expect(SessionRules.evaluate(session(), power: power(ac: false, thermal: thermal), now: now) == .stop(.thermal))
    }
    @Test func thermalProtectionStillRequestsExitWhenTimerExpiresSimultaneously() {
        #expect(SessionRules.evaluate(session(deadline: now), power: power(thermal: 3), now: now) == .stop(.thermal))
    }
    @Test func lowBatteryStopsBeforeWaiting() {
        var policy = ProtectionPolicy(); policy.allowBattery = false
        policy.endOnLowBattery = true
        #expect(SessionRules.evaluate(session(policy: policy), power: power(ac: false, battery: 20), now: now) == .stop(.lowBattery))
        #expect(SessionRules.evaluate(session(policy: policy), power: power(ac: false, battery: 21), now: now) == .waitForPower)
    }
    @Test func batteryPermissionAndDisconnectPauseAreIndependent() {
        var policy = ProtectionPolicy()
        policy.allowBattery = true
        policy.pauseOnDisconnect = true
        #expect(SessionRules.evaluate(session(policy: policy), power: power(ac: false), now: now) == .waitForPower)
        policy.pauseOnDisconnect = false
        #expect(SessionRules.evaluate(session(policy: policy), power: power(ac: false), now: now) == .run)
        policy.allowBattery = false
        #expect(SessionRules.evaluate(session(policy: policy), power: power(ac: false), now: now) == .waitForPower)
    }
    @Test func defaultPolicyRunsOnBattery() {
        #expect(SessionRules.evaluate(session(), power: power(ac: false), now: now) == .run)
    }
    @Test func unknownPowerFailsClosed() {
        #expect(SessionRules.evaluate(session(), power: power(ac: nil), now: now) == .stop(.failure))
        var policy = ProtectionPolicy(); policy.endOnLowBattery = true
        #expect(SessionRules.evaluate(session(policy: policy), power: power(ac: false, battery: nil), now: now) == .stop(.failure))
    }
    @Test(arguments: [DisplayMode.closed, .displayOnly, .always])
    func lowBatteryOnlyEndsSessionsWhenEnabled(mode: DisplayMode) {
        var next = Session(mode: mode, policy: ProtectionPolicy())
        for battery in [Int?(0), 10, 20, nil] {
            #expect(SessionRules.evaluate(next, power: power(ac: false, battery: battery), now: now) == .run)
        }
        next.policy.endOnLowBattery = true
        #expect(SessionRules.evaluate(next, power: power(ac: false, battery: 20), now: now) == .stop(.lowBattery))
        #expect(SessionRules.evaluate(next, power: power(ac: false, battery: 21), now: now) == .run)
        #expect(SessionRules.evaluate(next, power: power(ac: true, battery: 10), now: now) == .run)
        next.policy.endOnLowBattery = false
        #expect(SessionRules.evaluate(next, power: power(ac: false, battery: 10), now: now) == .run)
        next.policy.pauseOnDisconnect = true
        #expect(SessionRules.evaluate(next, power: power(ac: false, battery: 10), now: now) == .waitForPower)
    }
    @Test func legacyProtectionPreferencesKeepTheirValuesAndDefaultToNoBatteryLimit() throws {
        let data = Data(#"{"allowBattery":false,"minimumBattery":40,"pauseOnDisconnect":true,"resumeOnPower":true,"reminderMinutes":120}"#.utf8)
        var policy = try JSONDecoder().decode(ProtectionPolicy.self, from: data)
        #expect(!policy.endOnLowBattery && !policy.allowBattery && policy.minimumBattery == 40)
        #expect(policy.pauseOnDisconnect && policy.resumeOnPower && policy.reminderMinutes == 120)
        for enabled in [false, true] {
            policy.endOnLowBattery = enabled
            #expect(try JSONDecoder().decode(ProtectionPolicy.self, from: JSONEncoder().encode(policy)) == policy)
        }
    }
    @Test func displayAssertionsMatchLidPolicy() {
        #expect(!SessionRules.wantsDisplay(.system, lidClosed: false, manuallyOff: false))
        #expect(SessionRules.wantsDisplay(.closed, lidClosed: false, manuallyOff: false))
        #expect(!SessionRules.wantsDisplay(.closed, lidClosed: true, manuallyOff: false))
        #expect(!SessionRules.wantsDisplay(.closed, lidClosed: nil, manuallyOff: false))
        #expect(SessionRules.wantsDisplay(.always, lidClosed: true, manuallyOff: false))
    }
    @Test(arguments: DisplayMode.allCases) func manualScreenOffReleasesEveryDisplayPolicy(mode: DisplayMode) {
        #expect(!SessionRules.wantsDisplay(mode, lidClosed: false, manuallyOff: true))
        #expect(!SessionRules.wantsDisplay(mode, lidClosed: true, manuallyOff: true))
    }
    @Test func switchingToFollowSystemCannotRetainAnAssertion() {
        for lid in [true, false] { #expect(!SessionRules.wantsDisplay(.system, lidClosed: lid, manuallyOff: false)) }
    }
    @Test func requestRoundTripPreservesDeadlineAndIdentity() throws {
        let original = session(deadline: now.addingTimeInterval(3600))
        let data = try JSONEncoder().encode(HelperRequest(action: .start, session: original))
        let decoded = try JSONDecoder().decode(HelperRequest.self, from: data)
        #expect(decoded.session == original)
        #expect(decoded.action == .start)
    }
    @Test func unknownActionsAreRejected() {
        let data = Data("{\"action\":\"executeShell\"}".utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(HelperRequest.self, from: data) }
    }
}
