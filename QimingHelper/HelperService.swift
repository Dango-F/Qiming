import Foundation
import IOKit
import OSLog
import Darwin

protocol HelperPower: AnyObject {
    var now: Date { get }
    var awakeTime: TimeInterval { get }
    func snapshot() -> PowerSnapshot
    func pmset(_ arguments: [String]) throws
    func waitForSleepDisabled(_ expected: Bool) -> Bool
    func applyAssertions(system: Bool, display: Bool) throws
    @discardableResult func releaseAssertions() -> [String]
    var verifiedSystem: Bool { get }
    var verifiedDisplay: Bool { get }
    func idleTime(user: String) -> Int?
    func setIdleTime(_ value: Int?, user: String) throws
}

extension HelperPower {
    func waitForSleepDisabled(_ expected: Bool) -> Bool { snapshot().sleepDisabled == expected }
}

final class NativeHelperPower: HelperPower {
    private let assertions = PowerAssertions()
    var now: Date { Date() }
    var awakeTime: TimeInterval { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
    func snapshot() -> PowerSnapshot { SystemPower.snapshot() }
    func pmset(_ arguments: [String]) throws { try SystemPower.pmset(arguments) }
    func waitForSleepDisabled(_ expected: Bool) -> Bool {
        // pmset may return before the IORegistry notification reaches readers.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        repeat {
            if snapshot().sleepDisabled == expected { return true }
            Thread.sleep(forTimeInterval: 0.02)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return snapshot().sleepDisabled == expected
    }
    func applyAssertions(system: Bool, display: Bool) throws { try assertions.apply(system: system, display: display) }
    @discardableResult func releaseAssertions() -> [String] { assertions.release() }
    var verifiedSystem: Bool { assertions.verifiedSystem }
    var verifiedDisplay: Bool { assertions.verifiedDisplay }
    func idleTime(user: String) -> Int? {
        CFPreferencesCopyValue("idleTime" as CFString, "com.apple.screensaver" as CFString,
                               user as CFString, kCFPreferencesCurrentHost) as? Int
    }
    func setIdleTime(_ value: Int?, user: String) throws {
        let domain = "com.apple.screensaver" as CFString
        CFPreferencesSetValue("idleTime" as CFString, value.map { NSNumber(value: $0) },
                              domain, user as CFString, kCFPreferencesCurrentHost)
        guard CFPreferencesSynchronize(domain, user as CFString, kCFPreferencesCurrentHost),
              idleTime(user: user) == value else { throw PowerError.unavailable("screensaver policy verification") }
    }
}

private struct RecoveryRecord: Codable {
    var sessionID: UUID
    var originalSleepDisabled: Bool
    var sleepChangePlanned = true
    var user: String?
    var originalIdleTime: Int?
    var screenSaverChangePlanned = false
}

/// All mutable power state and journal operations are confined to queue.
final class HelperCore: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.qiming.mac.helper.power")
    private let powerSystem: any HelperPower
    private let journalURL: URL
    private var session: Session?
    private var owner: UUID?
    private var record: RecoveryRecord?
    private var timer: DispatchSourceTimer?
    private var recoveryTimer: DispatchSourceTimer?
    private var leaseDeadline: TimeInterval?
    // Display-only sessions can span intentional lid sleep. Their lease runs while awake.
    private var leaseNow: TimeInterval {
        session?.mode == .displayOnly ? powerSystem.awakeTime : powerSystem.now.timeIntervalSinceReferenceDate
    }
    private var phase = "idle"
    private var manuallyOff = false
    private var lastLid: Bool?
    private var error: (any Error)?
    private var screenSleepFailed: Bool {
        if case .screenSleep? = error as? PowerError { return true }
        return false
    }
    private var reason: EndReason?
    private var endedSession: (id: UUID, owner: UUID, reason: EndReason)?
    private var recovery: [String] = []
    private let log = Logger(subsystem: ServiceIdentity.helper, category: "Power")

    init(powerSystem: any HelperPower = NativeHelperPower(),
         directory: URL = URL(fileURLWithPath: "/Library/Application Support/Qiming", isDirectory: true)) throws {
        self.powerSystem = powerSystem
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700, .ownerAccountID: geteuid()])
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
              directoryInfo.st_uid == geteuid(), directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_mode & 0o022 == 0 else { throw PowerError.unavailable("unsafe journal directory") }
        journalURL = directory.appendingPathComponent("recovery.json")
        if FileManager.default.fileExists(atPath: journalURL.path) {
            var journalInfo = stat()
            guard lstat(journalURL.path, &journalInfo) == 0, journalInfo.st_uid == geteuid(),
                  journalInfo.st_mode & S_IFMT == S_IFREG,
                  journalInfo.st_mode & 0o077 == 0 else { throw PowerError.unavailable("unsafe recovery journal") }
            // A malformed journal is preserved and blocks further modifications.
            record = try JSONDecoder().decode(RecoveryRecord.self, from: Data(contentsOf: journalURL))
            try restore()
        }
    }

    func submit(_ data: Data, owner: UUID, uid: uid_t, reply: @escaping (Data) -> Void) {
        // NSXPC invokes this on its own serial queue. Reply is transferred only to our power queue.
        let response = ReplyBox(reply)
        queue.async {
            do {
                guard data.count <= 16_384 else { throw PowerError.unavailable("request size") }
                let request = try JSONDecoder().decode(HelperRequest.self, from: data)
                switch request.action {
                case .start:
                    guard let next = request.session, next.mode != .system,
                          (0...90).contains(next.policy.minimumBattery),
                          (1...1440).contains(next.policy.reminderMinutes),
                          next.deadline.map({ $0 > self.powerSystem.now && $0.timeIntervalSinceNow <= 604_800 }) ?? true,
                          self.owner == nil || self.owner == owner else {
                        throw PowerError.unavailable("invalid session or another client owns the session")
                    }
                    let old = self.session
                    let oldOwner = self.owner
                    if old != nil { try self.finish(.manual) }
                    do { try self.begin(next, owner: owner, uid: uid) }
                    catch {
                        let original = error
                        if let old, let oldOwner { try? self.begin(old, owner: oldOwner, uid: uid) }
                        throw original
                    }
                case .renew:
                    if self.isCompletedExpiry(owner: owner, id: request.sessionID) { break }
                    try self.checkOwner(owner, id: request.sessionID)
                    self.leaseDeadline = self.leaseNow + 45
                    try self.reconcile()
                case .stop:
                    if self.record == nil, self.isCompletedExpiry(owner: owner, id: request.sessionID) { break }
                    if self.session != nil { try self.checkOwner(owner, id: request.sessionID) }
                    try self.finish(.manual)
                case .screenOff:
                    try self.checkOwner(owner, id: request.sessionID)
                    try self.screenOff()
                case .resumeDisplay:
                    if self.isCompletedExpiry(owner: owner, id: request.sessionID) { break }
                    try self.checkOwner(owner, id: request.sessionID)
                    self.manuallyOff = false
                    try self.reconcile()
                case .setDeadline:
                    try self.checkOwner(owner, id: request.sessionID)
                    let now = self.powerSystem.now
                    if self.session?.deadline.map({ $0 <= now }) == true
                        || self.leaseDeadline.map({ $0 <= self.leaseNow }) == true {
                        try self.reconcile()
                        break
                    }
                    guard request.deadline.map({ $0 > now && $0.timeIntervalSince(now) <= 604_800 }) ?? true else {
                        throw PowerError.unavailable("invalid deadline")
                    }
                    self.session?.deadline = request.deadline
                    self.armTimer()
                case .extend:
                    try self.checkOwner(owner, id: request.sessionID)
                    if let deadline = self.session?.deadline {
                        guard deadline.addingTimeInterval(1800).timeIntervalSinceNow <= 604_800 else {
                            throw PowerError.unavailable("maximum duration is seven days")
                        }
                        self.session?.deadline = deadline.addingTimeInterval(1800)
                        self.armTimer()
                    }
                case .status:
                    try self.reconcile()
                }
                if self.session == nil && self.record != nil {
                    throw PowerError.unavailable("pending recovery; use Restore Normal Sleep to retry")
                }
                // A read-only status refresh must not erase the reason an action failed.
                if request.action != .status && (request.action != .renew || !self.screenSleepFailed) {
                    self.error = nil
                }
            } catch {
                self.error = error
                self.log.error("Power operation failed: \(error.localizedDescription, privacy: .public)")
            }
            let status = self.status()
            response.send((try? JSONEncoder().encode(status)) ?? Data())
        }
    }

    func clientDisconnected(_ id: UUID) {
        queue.async {
            guard self.owner == id else { return }
            do { try self.finish(.disconnected) }
            catch { self.error = error }
        }
    }

    func powerChanged() {
        queue.async {
            do { try self.reconcile() }
            catch { self.error = error; try? self.finish(.failure) }
        }
    }

    private func checkOwner(_ owner: UUID, id: UUID?) throws {
        guard self.owner == owner, let id, id == session?.id else { throw PowerError.unavailable("stale session") }
    }

    private func isCompletedExpiry(owner: UUID, id: UUID?) -> Bool {
        guard session == nil, let endedSession, let id else { return false }
        return endedSession.reason == .expired && endedSession.owner == owner && endedSession.id == id
    }

    private func screenOff() throws {
        let system = powerSystem.verifiedSystem
        let display = powerSystem.verifiedDisplay
        do {
            try powerSystem.applyAssertions(system: phase == "active" && session?.mode.keepsSystemAwake == true, display: false)
            try powerSystem.pmset(["displaysleepnow"])
            manuallyOff = true
        } catch {
            var detail = error.localizedDescription
            do { try powerSystem.applyAssertions(system: system, display: display) }
            catch { detail += "\nassertions.restore: \(error.localizedDescription)" }
            throw PowerError.screenSleep(detail)
        }
    }

    private func begin(_ next: Session, owner: UUID, uid: uid_t) throws {
        guard record == nil, recoveryTimer == nil else { throw PowerError.unavailable("pending recovery") }
        let power = self.powerSystem.snapshot()
        guard power.lidClosed != nil else { throw PowerError.unavailable("built-in lid sensor") }
        let decision = SessionRules.evaluate(next, power: power, now: self.powerSystem.now)
        if case let .stop(reason) = decision {
            throw PowerError.unavailable("protection.\(reason.rawValue)")
        }
        if decision == .waitForPower {
            session = next; self.owner = owner; waitingUID = uid
            leaseDeadline = leaseNow + 45
            manuallyOff = false; reason = nil; recovery = []; lastLid = nil
            endedSession = nil
            phase = "waiting"
            armTimer()
            return
        }
        if next.mode.keepsSystemAwake {
            guard power.sleepDisabled == false else { throw PowerError.unavailable("SleepDisabled conflict or unreadable baseline") }
            record = RecoveryRecord(sessionID: next.id, originalSleepDisabled: false)
            // Persist intention BEFORE the system change, including the crash window before pmset returns.
            try saveRecord()
        }
        do {
            if next.mode.keepsSystemAwake {
                try self.powerSystem.pmset(["-a", "disablesleep", "1"])
                guard self.powerSystem.waitForSleepDisabled(true) else { throw PowerError.unavailable("SleepDisabled verification") }
            }
            if next.mode == .always { try pauseScreenSaver(uid: uid) }
            self.session = next
            self.owner = owner
            waitingUID = uid
            leaseDeadline = leaseNow + 45
            manuallyOff = false
            reason = nil
            endedSession = nil
            recovery = []
            lastLid = nil
            phase = "active"
            try reconcile()
            guard self.session?.id == next.id else { throw PowerError.unavailable("power changed during activation") }
            log.notice("Session started: \(next.mode.rawValue, privacy: .public)")
        } catch {
            self.powerSystem.releaseAssertions()
            try? restoreWithRetry()
            session = nil; self.owner = nil; phase = "idle"
            throw error
        }
    }

    private func reconcile() throws {
        guard let session else { return }
        let power = self.powerSystem.snapshot()
        if let leaseDeadline, leaseDeadline <= leaseNow { try finish(.disconnected); return }
        switch SessionRules.evaluate(session, power: power, now: self.powerSystem.now) {
        case let .stop(reason):
            // Thermal protection: release display assertion, request screen sleep, then restore global state.
            if reason == .thermal {
                self.powerSystem.releaseAssertions()
                do { try self.powerSystem.pmset(["displaysleepnow"]); recovery.append("display.sleep.request: accepted") }
                catch { recovery.append("display.sleep.request: \(error.localizedDescription)") }
            }
            try finish(reason)
            return
        case .waitForPower:
            if phase != "waiting" {
                self.powerSystem.releaseAssertions()
                try restoreWithRetry()
                phase = "waiting"
            }
        case .run:
            if phase == "waiting" {
                // Never silently recreate a lease unless the user explicitly enabled this preference.
                guard session.policy.resumeOnPower else { armTimer(); return }
                let oldOwner = owner
                self.session = nil; owner = nil
                guard let oldOwner, let user = waitingUID else { throw PowerError.unavailable("resume identity") }
                try begin(session, owner: oldOwner, uid: user)
                return
            }
            if session.mode.keepsSystemAwake, power.sleepDisabled != true { try finish(.conflict); return }
            if lastLid == true && power.lidClosed == false { manuallyOff = false }
            let shouldDisplay = SessionRules.wantsDisplay(session.mode, lidClosed: power.lidClosed, manuallyOff: manuallyOff)
            try self.powerSystem.applyAssertions(system: session.mode.keepsSystemAwake, display: shouldDisplay)
            if session.mode == .closed, power.lidClosed == true, lastLid != true {
                do {
                    try self.powerSystem.pmset(["displaysleepnow"])
                    if screenSleepFailed { error = nil }
                } catch { throw PowerError.screenSleep(error.localizedDescription) }
            }
            lastLid = power.lidClosed
            phase = "active"
        }
        armTimer()
    }

    private var waitingUID: uid_t?

    private func pauseScreenSaver(uid: uid_t) throws {
        guard let pw = getpwuid(uid) else { throw PowerError.unavailable("user identity") }
        let user = String(cString: pw.pointee.pw_name)
        record?.user = user
        record?.originalIdleTime = self.powerSystem.idleTime(user: user)
        record?.screenSaverChangePlanned = true
        try saveRecord()
        try self.powerSystem.setIdleTime(0, user: user)
        waitingUID = uid
    }

    private func armTimer() {
        timer?.cancel()
        guard let session, let leaseDeadline else { timer = nil; return }
        let remaining = min(session.deadline?.timeIntervalSince(powerSystem.now) ?? .infinity, leaseDeadline - leaseNow)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(0, remaining), leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do { try self.reconcile() } catch { self.error = error; try? self.finish(.failure) }
        }
        self.timer = timer
        timer.resume()
    }

    private func finish(_ reason: EndReason) throws {
        timer?.cancel(); timer = nil
        let failures = self.powerSystem.releaseAssertions()
        recovery.append(contentsOf: failures.isEmpty ? ["assertions.release: complete"] : failures)
        // Even if restoration fails, end the session. Preserve the journal for explicit retry and restart recovery.
        if let session, let owner { endedSession = (session.id, owner, reason) }
        session = nil; owner = nil; leaseDeadline = nil; manuallyOff = false; phase = "idle"
        self.reason = reason
        try restoreWithRetry()
        log.notice("Session ended: \(reason.rawValue, privacy: .public)")
    }

    private func saveRecord() throws {
        guard let record else { return }
        try JSONEncoder().encode(record).write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        // Ensure the rename and record survive an unclean shutdown before modifying power settings.
        let descriptor = open(journalURL.path, O_RDONLY | O_NOFOLLOW)
        if descriptor >= 0 { _ = fsync(descriptor); close(descriptor) }
        let parent = open(journalURL.deletingLastPathComponent().path, O_RDONLY | O_NOFOLLOW)
        if parent >= 0 { _ = fsync(parent); close(parent) }
    }

    private func restoreWithRetry() throws {
        defer { if recovery.count > 64 { recovery.removeFirst(recovery.count - 64) } }
        do {
            try restore()
            let failures = self.powerSystem.releaseAssertions()
            guard failures.isEmpty else { throw PowerError.unavailable(failures.joined(separator: "; ")) }
            recoveryTimer?.cancel(); recoveryTimer = nil
        } catch {
            recoveryTimer?.cancel()
            let retry = DispatchSource.makeTimerSource(queue: queue)
            retry.schedule(deadline: .now() + 15, leeway: .seconds(2))
            retry.setEventHandler { [weak self] in
                guard let self else { return }
                do { try self.restoreWithRetry(); self.error = nil }
                catch { self.error = error }
            }
            recoveryTimer = retry; retry.resume()
            throw error
        }
    }

    private func restore() throws {
        guard let record else { return }
        if record.screenSaverChangePlanned, let user = record.user {
            let current = self.powerSystem.idleTime(user: user)
            if current == 0 {
                try self.powerSystem.setIdleTime(record.originalIdleTime, user: user)
                recovery.append("screensaver.restore: complete")
            } else { recovery.append("screensaver.restore: external change preserved") }
        }
        if record.sleepChangePlanned {
            guard let current = self.powerSystem.snapshot().sleepDisabled else { throw PowerError.unavailable("SleepDisabled restore read") }
            if current != record.originalSleepDisabled {
                try self.powerSystem.pmset(["-a", "disablesleep", record.originalSleepDisabled ? "1" : "0"])
                guard self.powerSystem.waitForSleepDisabled(record.originalSleepDisabled) else {
                    throw PowerError.unavailable("SleepDisabled restore verification")
                }
            }
            recovery.append("sleep.restore: complete")
        }
        if FileManager.default.fileExists(atPath: journalURL.path) { try FileManager.default.removeItem(at: journalURL) }
        self.record = nil
    }

    private func status() -> HelperStatus {
        HelperStatus(session: session, power: self.powerSystem.snapshot(), phase: phase,
            systemAssertion: self.powerSystem.verifiedSystem, displayAssertion: self.powerSystem.verifiedDisplay,
            manualDisplayOff: manuallyOff, screenSaverPaused: record?.screenSaverChangePlanned == true,
            error: error?.localizedDescription, endReason: reason, recovery: recovery,
            screenSleepFailed: screenSleepFailed ? true : nil, endedSessionID: endedSession?.id)
    }
}

private final class ReplyBox: @unchecked Sendable {
    private let reply: (Data) -> Void
    init(_ reply: @escaping (Data) -> Void) { self.reply = reply }
    func send(_ data: Data) { reply(data) }
}

private final class Endpoint: NSObject, QimingHelperProtocol {
    let core: HelperCore
    let id: UUID
    let uid: uid_t
    init(core: HelperCore, id: UUID, uid: uid_t) { self.core = core; self.id = id; self.uid = uid }
    func perform(_ request: Data, reply: @escaping (Data) -> Void) { core.submit(request, owner: id, uid: uid, reply: reply) }
}

final class HelperListener: NSObject, NSXPCListenerDelegate {
    private let core: HelperCore
    private let team: String
    init(core: HelperCore, team: String) { self.core = core; self.team = team }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier != 0 else { return false }
        // Foundation validates this requirement for each incoming message, avoiding PID-reuse authentication.
        connection.setCodeSigningRequirement(Signing.requirement(identifier: ServiceIdentity.app, team: team))
        let id = UUID()
        connection.exportedInterface = NSXPCInterface(with: QimingHelperProtocol.self)
        connection.exportedObject = Endpoint(core: core, id: id, uid: connection.effectiveUserIdentifier)
        connection.invalidationHandler = { [core] in core.clientDisconnected(id) }
        connection.interruptionHandler = { [core] in core.clientDisconnected(id) }
        connection.resume()
        return true
    }
}
