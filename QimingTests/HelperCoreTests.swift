import Foundation
import Testing

/// Exercises the production helper state machine with isolated power I/O and a private temporary journal.
/// No test changes the host's power settings, screen saver, or service registration.
private final class TestPower: HelperPower, @unchecked Sendable {
    var now = Date()
    var awakeTime: TimeInterval = 0
    var power = PowerSnapshot(onAC: false, battery: 80, lidClosed: false, sleepDisabled: false)
    var verifiedSystem = false
    var verifiedDisplay = false
    var idle: Int? = 600
    var commands: [[String]] = []
    var failEnable = false
    var failRestore = false
    var failAssertions = false
    var failScreenOff = false
    func snapshot() -> PowerSnapshot { power }
    func pmset(_ arguments: [String]) throws {
        commands.append(arguments)
        if arguments == ["-a", "disablesleep", "1"] {
            if failEnable { throw PowerError.unavailable("injected enable failure") }
            power.sleepDisabled = true
        } else if arguments == ["-a", "disablesleep", "0"] {
            if failRestore { throw PowerError.unavailable("injected restore failure") }
            power.sleepDisabled = false
        } else if arguments == ["displaysleepnow"], failScreenOff {
            throw PowerError.unavailable("injected display sleep failure")
        }
    }
    func applyAssertions(system: Bool, display: Bool) throws {
        if failAssertions { throw PowerError.unavailable("injected assertion failure") }
        verifiedSystem = system; verifiedDisplay = display
    }
    func releaseAssertions() -> [String] { verifiedSystem = false; verifiedDisplay = false; return [] }
    func idleTime(user: String) -> Int? { idle }
    func setIdleTime(_ value: Int?, user: String) throws { idle = value }
}

private final class Fixture {
    let power = TestPower()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Qiming-test-\(UUID())")
    let owner = UUID()
    var core: HelperCore!
    init() throws { core = try HelperCore(powerSystem: power, directory: directory) }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func send(_ action: HelperRequest.Action, session: Session? = nil, id: UUID? = nil,
              owner: UUID? = nil, deadline: Date? = nil) async throws -> HelperStatus {
        let data = try JSONEncoder().encode(HelperRequest(action: action, session: session, sessionID: id, deadline: deadline))
        let response: Data = await withCheckedContinuation { continuation in
            core.submit(data, owner: owner ?? self.owner, uid: getuid()) { continuation.resume(returning: $0) }
        }
        return try JSONDecoder().decode(HelperStatus.self, from: response)
    }
    func start(_ mode: DisplayMode = .closed, seconds: Double? = nil,
               policy: ProtectionPolicy = ProtectionPolicy()) async throws -> HelperStatus {
        try await send(.start, session: Session(mode: mode, deadline: seconds.map { power.now.addingTimeInterval($0) }, policy: policy))
    }
}

@Suite("Helper lifecycle with isolated power I/O")
struct HelperCoreTests {
    @Test func defaultBatterySessionActuallyAcquiresAndRestoresAssertions() async throws {
        let f = try Fixture(); let active = try await f.start()
        #expect(active.error == nil && active.phase == "active")
        #expect(active.systemAssertion && active.displayAssertion && active.power.sleepDisabled == true)
        let idle = try await f.send(.stop, id: active.session?.id)
        #expect(idle.session == nil && !idle.systemAssertion && !idle.displayAssertion)
        #expect(idle.power.sleepDisabled == false && idle.error == nil)
        #expect(!FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("recovery.json").path))
    }
    @Test(arguments: [DisplayMode.closed, .displayOnly, .always], [false, true])
    func defaultPoliciesKeepTheSameSessionAcrossPowerChanges(mode: DisplayMode, startsOnAC: Bool) async throws {
        let f = try Fixture()
        f.power.power.onAC = startsOnAC
        let started = try await f.start(mode)
        let initialCommands = f.power.commands
        for onAC in [startsOnAC, !startsOnAC, startsOnAC] {
            f.power.power.onAC = onAC
            f.core.powerChanged()
            let status = try await f.send(.status)
            #expect(status.error == nil && status.phase == "active")
            #expect(status.session?.id == started.session?.id && status.session?.mode == mode)
            #expect(status.power.onAC == onAC && status.displayAssertion)
            #expect(status.systemAssertion == mode.keepsSystemAwake)
            #expect(status.power.sleepDisabled == mode.keepsSystemAwake)
            #expect(f.power.commands == initialCommands)
        }
        let stopped = try await f.send(.stop, id: started.session?.id)
        #expect(stopped.error == nil && stopped.power.sleepDisabled == false)
        #expect(!stopped.systemAssertion && !stopped.displayAssertion)
    }
    @Test func displayOnlyAllowsLidSleepAndRestoresDisplayAssertionAfterWake() async throws {
        let f = try Fixture()
        let open = try await f.start(.displayOnly)
        #expect(open.error == nil && open.displayAssertion && !open.systemAssertion)
        #expect(open.power.sleepDisabled == false && f.power.commands.isEmpty)
        f.power.power.lidClosed = true
        let closed = try await f.send(.status)
        #expect(closed.session?.id == open.session?.id && !closed.displayAssertion && !closed.systemAssertion)
        #expect(f.power.commands.isEmpty)
        f.power.now.addTimeInterval(600)
        f.power.power.lidClosed = false
        let reopened = try await f.send(.status)
        #expect(reopened.session?.id == open.session?.id && reopened.displayAssertion && !reopened.systemAssertion)
        f.power.awakeTime += 46
        let expired = try await f.send(.status)
        #expect(expired.session == nil && expired.endReason == .disconnected && !expired.displayAssertion)
        #expect(f.power.commands.isEmpty)
    }
    @Test func switchingFromKeepAwakeToDisplayOnlyRestoresSystemSleep() async throws {
        let f = try Fixture()
        _ = try await f.start(.closed)
        let display = try await f.start(.displayOnly)
        #expect(display.session?.mode == .displayOnly && display.power.sleepDisabled == false)
        #expect(display.displayAssertion && !display.systemAssertion)
        let dark = try await f.send(.screenOff, id: display.session?.id)
        #expect(dark.manualDisplayOff && !dark.systemAssertion && !dark.displayAssertion)
        let resumed = try await f.send(.resumeDisplay, id: display.session?.id)
        #expect(resumed.displayAssertion && !resumed.systemAssertion)
        _ = try await f.send(.stop, id: display.session?.id)
    }
    @Test func acOnlyStartWaitsWithoutChangingSystemAndCanBeCancelled() async throws {
        let f = try Fixture(); var p = ProtectionPolicy(); p.allowBattery = false
        let waiting = try await f.start(policy: p)
        #expect(waiting.phase == "waiting" && waiting.session != nil && waiting.error == nil)
        #expect(!waiting.systemAssertion && !waiting.displayAssertion && f.power.commands.isEmpty)
        let idle = try await f.send(.stop, id: waiting.session?.id)
        #expect(idle.phase == "idle" && idle.session == nil && idle.error == nil)
    }
    @Test func waitingSessionResumesOnceWhenPowerReturns() async throws {
        let f = try Fixture(); var p = ProtectionPolicy(); p.allowBattery = false; p.resumeOnPower = true
        let waiting = try await f.start(policy: p)
        f.power.power.onAC = true
        let active = try await f.send(.status)
        #expect(active.session?.id == waiting.session?.id && active.phase == "active")
        #expect(active.systemAssertion && active.displayAssertion && active.error == nil)
        _ = try await f.send(.stop, id: active.session?.id)
    }
    @Test func powerReturnDoesNotOverrideDisabledAutoResume() async throws {
        let f = try Fixture(); var p = ProtectionPolicy(); p.allowBattery = false
        _ = try await f.start(policy: p); f.power.power.onAC = true
        let waiting = try await f.send(.status)
        #expect(waiting.phase == "waiting" && !waiting.systemAssertion && f.power.commands.isEmpty)
        _ = try await f.send(.stop, id: waiting.session?.id)
    }
    @Test func disconnectPausesAndRestoresGlobalState() async throws {
        let f = try Fixture(); f.power.power.onAC = true
        var p = ProtectionPolicy(); p.pauseOnDisconnect = true; p.resumeOnPower = true
        _ = try await f.start(.always, policy: p)
        f.power.power.onAC = false
        let waiting = try await f.send(.status)
        #expect(waiting.phase == "waiting" && !waiting.systemAssertion && !waiting.displayAssertion)
        #expect(waiting.power.sleepDisabled == false && f.power.idle == 600)
        f.power.power.onAC = true
        let active = try await f.send(.status)
        #expect(active.phase == "active" && active.systemAssertion && active.displayAssertion && f.power.idle == 0)
        _ = try await f.send(.stop, id: active.session?.id)
        #expect(f.power.idle == 600 && f.power.power.sleepDisabled == false)
    }
    @Test func lidTransitionsAndManualScreenOffPreserveSystemWork() async throws {
        let f = try Fixture(); let active = try await f.start()
        f.power.power.lidClosed = true
        let closed = try await f.send(.status)
        #expect(closed.systemAssertion && !closed.displayAssertion)
        #expect(f.power.commands.contains(["displaysleepnow"]))
        f.power.power.lidClosed = false
        #expect(try await f.send(.status).displayAssertion)
        let off = try await f.send(.screenOff, id: active.session?.id)
        #expect(off.manualDisplayOff && off.systemAssertion && !off.displayAssertion)
        let resumed = try await f.send(.resumeDisplay, id: active.session?.id)
        #expect(!resumed.manualDisplayOff && resumed.displayAssertion)
        _ = try await f.send(.stop, id: active.session?.id)
    }
    @Test func failedManualScreenSleepPreservesAssertionsAndCanBeRetried() async throws {
        let f = try Fixture()
        let active = try await f.start()
        f.power.failScreenOff = true
        let failed = try await f.send(.screenOff, id: active.session?.id)
        #expect(failed.screenSleepFailed == true && failed.error?.contains("injected display sleep failure") == true)
        #expect(!failed.manualDisplayOff && failed.systemAssertion && failed.displayAssertion)
        #expect(failed.session?.id == active.session?.id)
        #expect(try await f.send(.renew, id: active.session?.id).screenSleepFailed == true)
        f.power.failScreenOff = false
        let retried = try await f.send(.screenOff, id: active.session?.id)
        #expect(retried.error == nil && retried.screenSleepFailed == nil)
        #expect(retried.manualDisplayOff && retried.systemAssertion && !retried.displayAssertion)
        _ = try await f.send(.stop, id: active.session?.id)
    }
    @Test func failedLidScreenSleepReportsDisplayErrorAndRecoversPowerState() async throws {
        let f = try Fixture()
        _ = try await f.start()
        f.power.power.lidClosed = true
        f.power.failScreenOff = true
        f.core.powerChanged()
        let failed = try await f.send(.status)
        #expect(failed.screenSleepFailed == true && failed.error?.contains("injected display sleep failure") == true)
        #expect(failed.session == nil && !failed.systemAssertion && failed.power.sleepDisabled == false)
    }
    @Test func alwaysOnPausesAndRestoresScreenSaverIncludingAbsentValue() async throws {
        for original in [nil, 600] as [Int?] {
            let f = try Fixture(); f.power.idle = original
            let active = try await f.start(.always)
            #expect(active.screenSaverPaused && f.power.idle == 0)
            f.power.power.lidClosed = true
            #expect(try await f.send(.status).displayAssertion)
            _ = try await f.send(.stop, id: active.session?.id)
            #expect(f.power.idle == original)
        }
    }
    @Test func externalScreenSaverEditIsPreserved() async throws {
        let f = try Fixture(); let active = try await f.start(.always)
        f.power.idle = 120
        let stopped = try await f.send(.stop, id: active.session?.id)
        #expect(f.power.idle == 120 && stopped.recovery.contains("screensaver.restore: external change preserved"))
    }
    @Test func modeSwitchReleasesOldPolicyAndCreatesNewSession() async throws {
        let f = try Fixture(); let first = try await f.start(.always)
        let second = try await f.start(.closed)
        #expect(first.session?.id != second.session?.id && second.session?.mode == .closed)
        #expect(f.power.idle == 600 && second.systemAssertion && second.displayAssertion)
        _ = try await f.send(.stop, id: second.session?.id)
    }
    @Test func deadlineExpiresWithoutRenewalAndRestoresSystem() async throws {
        let f = try Fixture(); _ = try await f.start(seconds: 5)
        f.power.now.addTimeInterval(6)
        let ended = try await f.send(.status)
        #expect(ended.session == nil && ended.endReason == .expired && ended.power.sleepDisabled == false)
    }
    @Test(arguments: [false, true])
    func renewalAtOrAfterDeadlineReturnsNormalExpiry(timerRanFirst: Bool) async throws {
        let f = try Fixture()
        let active = try await f.start(seconds: 5)
        f.power.now.addTimeInterval(6)
        if timerRanFirst {
            f.core.powerChanged()
            #expect(try await f.send(.status).endReason == .expired)
        }
        for action in [HelperRequest.Action.renew, .renew, .resumeDisplay, .stop] {
            let ended = try await f.send(action, id: active.session?.id)
            #expect(ended.error == nil && ended.session == nil && ended.phase == "idle")
            #expect(ended.endReason == .expired && ended.endedSessionID == active.session?.id)
            #expect(!ended.systemAssertion && !ended.displayAssertion && ended.power.sleepDisabled == false)
        }
    }
    @Test func completedExpiryOnlyAcceptsTheOriginalOwnerAndSession() async throws {
        let f = try Fixture()
        let active = try await f.start(seconds: 5)
        f.power.now.addTimeInterval(6)
        _ = try await f.send(.status)
        #expect(try await f.send(.renew, id: UUID()).error != nil)
        #expect(try await f.send(.renew, id: active.session?.id, owner: UUID()).error != nil)
        let ended = try await f.send(.renew, id: active.session?.id)
        #expect(ended.error == nil && ended.endReason == .expired)
        let next = try await f.start()
        #expect(next.session?.deadline == nil && next.endedSessionID == nil)
        #expect(try await f.send(.renew, id: active.session?.id).error != nil)
        #expect(try await f.send(.status).session?.id == next.session?.id)
        _ = try await f.send(.stop, id: next.session?.id)
    }
    @Test func failedExpiryRecoveryStaysAnErrorAndCanBeRetried() async throws {
        let f = try Fixture()
        let active = try await f.start(seconds: 5)
        f.power.failRestore = true
        f.power.now.addTimeInterval(6)
        let failed = try await f.send(.status)
        #expect(failed.error != nil && failed.endReason == .expired && failed.power.sleepDisabled == true)
        #expect(try await f.send(.renew, id: active.session?.id).error != nil)
        f.power.failRestore = false
        let restored = try await f.send(.stop, id: active.session?.id)
        #expect(restored.error == nil && restored.power.sleepDisabled == false && restored.session == nil)
    }
    @Test func extendAddsThirtyMinutesWithoutChangingIdentity() async throws {
        let f = try Fixture(); let active = try await f.start(seconds: 60)
        let extended = try await f.send(.extend, id: active.session?.id)
        #expect(extended.session?.id == active.session?.id)
        #expect(extended.session?.deadline == active.session?.deadline?.addingTimeInterval(1800))
        _ = try await f.send(.stop, id: active.session?.id)
    }
    @Test func changingDurationUpdatesTheSameSessionAndClearsTheOldTimer() async throws {
        let f = try Fixture()
        let active = try await f.start(seconds: 5)
        let id = active.session?.id
        let commands = f.power.commands
        let unlimited = try await f.send(.setDeadline, id: id)
        #expect(unlimited.error == nil && unlimited.session?.deadline == nil)
        #expect(unlimited.session?.id == id && unlimited.session?.startedAt == active.session?.startedAt)
        #expect(unlimited.systemAssertion && unlimited.displayAssertion && f.power.commands == commands)
        f.power.now.addTimeInterval(6)
        #expect(try await f.send(.status).session?.id == id)

        let deadline = f.power.now.addingTimeInterval(10)
        #expect(try await f.send(.setDeadline, id: id, owner: UUID(), deadline: deadline).error != nil)
        #expect(try await f.send(.setDeadline, id: id, deadline: f.power.now).error != nil)
        let timed = try await f.send(.setDeadline, id: id, deadline: deadline)
        #expect(timed.error == nil && timed.session?.deadline == deadline && timed.session?.id == id)
        f.power.now.addTimeInterval(11)
        let ended = try await f.send(.setDeadline, id: id)
        #expect(ended.session == nil && ended.endReason == .expired && ended.power.sleepDisabled == false)
    }
    @Test func renewalKeepsSessionAliveAndLeaseExpiryCleansUp() async throws {
        let f = try Fixture(); let active = try await f.start()
        f.power.now.addTimeInterval(30)
        #expect(try await f.send(.renew, id: active.session?.id).session != nil)
        f.power.now.addTimeInterval(30)
        #expect(try await f.send(.status).session != nil)
        f.power.now.addTimeInterval(16)
        let ended = try await f.send(.status)
        #expect(ended.endReason == .disconnected && ended.session == nil && !ended.systemAssertion)
    }
    @Test func disconnectCleansUpOnlyTheOwner() async throws {
        let f = try Fixture(); _ = try await f.start()
        f.core.clientDisconnected(UUID())
        #expect(try await f.send(.status).session != nil)
        f.core.clientDisconnected(f.owner)
        let ended = try await f.send(.status)
        #expect(ended.session == nil && ended.endReason == .disconnected && ended.power.sleepDisabled == false)
    }
    @Test func staleSessionAndOtherClientCannotMutateCurrentSession() async throws {
        let f = try Fixture(); let active = try await f.start()
        #expect(try await f.send(.stop, id: UUID()).error != nil)
        #expect(try await f.send(.stop, id: active.session?.id, owner: UUID()).error != nil)
        let replacement = Session(mode: .always, policy: ProtectionPolicy())
        #expect(try await f.send(.start, session: replacement, owner: UUID()).error != nil)
        #expect(try await f.send(.status).session?.id == active.session?.id)
        _ = try await f.send(.stop, id: active.session?.id)
    }
    @Test func lowBatteryAndHeatEndActiveSession() async throws {
        for reason in [EndReason.lowBattery, .thermal] {
            let f = try Fixture()
            var policy = ProtectionPolicy(); policy.endOnLowBattery = true
            _ = try await f.start(policy: policy)
            if reason == .lowBattery { f.power.power.battery = 20 } else { f.power.power.thermal = 2 }
            let ended = try await f.send(.status)
            #expect(ended.endReason == reason && ended.session == nil && !ended.systemAssertion && !ended.displayAssertion)
            #expect(ended.power.sleepDisabled == false)
            if reason == .thermal { #expect(f.power.commands.contains(["displaysleepnow"])) }
        }
    }
    @Test(arguments: [DisplayMode.closed, .displayOnly, .always])
    func lowBatteryOptInReachesTheHelperAndControlsActiveSessions(mode: DisplayMode) async throws {
        for enabled in [false, true] {
            let f = try Fixture()
            var policy = ProtectionPolicy(); policy.endOnLowBattery = enabled
            let active = try await f.start(mode, policy: policy)
            f.power.power.battery = 10
            let result = try await f.send(.status)
            #expect(result.error == nil)
            if enabled {
                #expect(result.session == nil && result.endReason == .lowBattery)
                #expect(!result.systemAssertion && !result.displayAssertion && result.power.sleepDisabled == false)
            } else {
                #expect(result.session?.id == active.session?.id && result.phase == "active")
                #expect(result.displayAssertion)
                _ = try await f.send(.stop, id: active.session?.id)
            }
        }
    }
    @Test func conflictsAndUnknownSensorsDoNotChangeSystem() async throws {
        let f = try Fixture(); f.power.power.sleepDisabled = true
        #expect(try await f.start().error != nil)
        #expect(f.power.commands.isEmpty)
        f.power.power.sleepDisabled = false; f.power.power.lidClosed = nil
        #expect(try await f.start().error != nil)
        #expect(f.power.commands.isEmpty)
    }
    @Test func partialActivationFailureRollsBackAndErrorSurvivesRefresh() async throws {
        let f = try Fixture(); f.power.failAssertions = true
        #expect(try await f.start().error != nil)
        let status = try await f.send(.status)
        #expect(status.error != nil && status.session == nil && status.power.sleepDisabled == false)
        f.power.failAssertions = false
        let active = try await f.start()
        #expect(active.error == nil && active.phase == "active")
        _ = try await f.send(.stop, id: active.session?.id)
    }
    @Test func failedRestoreCanBeRetriedAndRestartJournalRecovers() async throws {
        let f = try Fixture(); let active = try await f.start(.always)
        f.power.failRestore = true
        let failed = try await f.send(.stop, id: active.session?.id)
        #expect(failed.error != nil && failed.session == nil && !failed.systemAssertion)
        #expect(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("recovery.json").path))
        f.power.failRestore = false
        let restored = try await f.send(.stop)
        #expect(restored.error == nil && restored.power.sleepDisabled == false && f.power.idle == 600)
        _ = try await f.start(.always)
        f.core = nil
        _ = f.power.releaseAssertions() // The kernel releases assertions when the old process exits.
        f.core = try HelperCore(powerSystem: f.power, directory: f.directory)
        let restarted = try await f.send(.status)
        #expect(restarted.session == nil && !restarted.systemAssertion && !restarted.displayAssertion)
        #expect(restarted.power.sleepDisabled == false && f.power.idle == 600)
    }
}
