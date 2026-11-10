import Foundation

enum DisplayMode: String, Codable, CaseIterable, Sendable {
    case system, closed, displayOnly, always
    var titleKey: String { "mode.\(rawValue)" }
    var detailKey: String { "mode.\(rawValue).detail" }
    var keepsSystemAwake: Bool { self == .closed || self == .always }
}

enum EndReason: String, Codable, Sendable {
    case manual, expired, lowBattery, thermal, disconnected, locked, sleep, conflict, failure
    var key: String { "reason.\(rawValue)" }
}

struct ProtectionPolicy: Codable, Equatable, Sendable {
    var allowBattery = true
    var endOnLowBattery = false
    var minimumBattery = 20
    var pauseOnDisconnect = false
    var resumeOnPower = false
    var reminderMinutes = 60

    init() {}

    private enum CodingKeys: String, CodingKey {
        case allowBattery, endOnLowBattery, minimumBattery, pauseOnDisconnect, resumeOnPower, reminderMinutes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        allowBattery = try values.decodeIfPresent(Bool.self, forKey: .allowBattery) ?? true
        // Existing preferences predate the opt-in switch; preserve their other settings.
        endOnLowBattery = try values.decodeIfPresent(Bool.self, forKey: .endOnLowBattery) ?? false
        minimumBattery = try values.decodeIfPresent(Int.self, forKey: .minimumBattery) ?? 20
        pauseOnDisconnect = try values.decodeIfPresent(Bool.self, forKey: .pauseOnDisconnect) ?? false
        resumeOnPower = try values.decodeIfPresent(Bool.self, forKey: .resumeOnPower) ?? false
        reminderMinutes = try values.decodeIfPresent(Int.self, forKey: .reminderMinutes) ?? 60
    }
}

struct PowerSnapshot: Codable, Equatable, Sendable {
    var onAC: Bool?
    var battery: Int?
    var charging: Bool?
    var lidClosed: Bool?
    var sleepDisabled: Bool?
    var thermal: Int = 0
    var checkedAt = Date()
}

struct PowerSourceTracker {
    private(set) var lastOnAC: Bool?
    private var checkedAt: Date

    init(onAC: Bool?, checkedAt: Date = .distantPast) {
        lastOnAC = onAC
        self.checkedAt = checkedAt
    }

    mutating func disconnected(onAC: Bool?, checkedAt: Date = Date()) -> Bool {
        guard let onAC, checkedAt >= self.checkedAt else { return false }
        let disconnected = lastOnAC == true && !onAC
        lastOnAC = onAC
        self.checkedAt = checkedAt
        return disconnected
    }
}

/// Coalesces event-driven refreshes, including an event that arrives during an XPC request.
@MainActor final class PowerEventRefresh {
    private var pending = false
    private var task: Task<Void, Never>?
    private let isBlocked: @MainActor () -> Bool
    private let refresh: @MainActor () async -> Void

    init(isBlocked: @escaping @MainActor () -> Bool, refresh: @escaping @MainActor () async -> Void) {
        self.isBlocked = isBlocked
        self.refresh = refresh
    }

    func request() {
        pending = true
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            while self.pending, !Task.isCancelled {
                if self.isBlocked() {
                    do { try await Task.sleep(for: .milliseconds(50)) }
                    catch { return }
                } else {
                    self.pending = false
                    await self.refresh()
                }
            }
        }
    }
}

struct Session: Codable, Equatable, Sendable {
    var id = UUID()
    var mode: DisplayMode
    var startedAt = Date()
    var deadline: Date?
    var policy: ProtectionPolicy
}

enum SessionTiming {
    static func clock(_ seconds: TimeInterval, roundingUp: Bool = false) -> String {
        let seconds = seconds.isFinite ? max(0, seconds) : 0
        let n = Int(roundingUp ? ceil(seconds) : floor(seconds))
        return String(format: "%02d:%02d:%02d", n / 3600, (n % 3600) / 60, n % 60)
    }
}

/// Confirms expiry independently of panel visibility and the 15-second lease.
@MainActor final class SessionDeadlineMonitor {
    private struct Target: Equatable {
        var id: UUID
        var deadline: Date
    }
    private var target: Target?
    private var generation: UInt64 = 0
    private var timer: Timer?
    // Return true only when an in-flight operation requires a short retry.
    private let check: @MainActor (UUID, Date) async -> Bool

    init(check: @escaping @MainActor (UUID, Date) async -> Bool) { self.check = check }

    func update(_ session: Session?) {
        let next = session.flatMap { session in session.deadline.map { Target(id: session.id, deadline: $0) } }
        guard next != target else { return }
        generation &+= 1
        timer?.invalidate(); timer = nil
        target = next
        if let next { arm(next, generation: generation) }
    }

    private func arm(_ expected: Target, generation: UInt64, retry: Bool = false) {
        let fireDate = retry ? max(expected.deadline, Date().addingTimeInterval(0.1)) : expected.deadline
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation, self.target == expected else { return }
                self.timer = nil
                // Wall-clock changes must not end a session early.
                if expected.deadline > Date() {
                    self.arm(expected, generation: generation)
                    return
                }
                let retry = await self.check(expected.id, expected.deadline)
                guard retry, self.generation == generation, self.target == expected else { return }
                self.arm(expected, generation: generation, retry: true)
            }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

enum PolicyDecision: Equatable {
    case run, waitForPower, stop(EndReason)
}

enum SessionRules {
    static func evaluate(_ session: Session, power: PowerSnapshot, now: Date = Date()) -> PolicyDecision {
        if power.thermal >= 2 { return .stop(.thermal) }
        if let deadline = session.deadline, deadline <= now { return .stop(.expired) }
        guard let onAC = power.onAC else { return .stop(.failure) }
        if !onAC {
            if session.policy.endOnLowBattery {
                guard let battery = power.battery else { return .stop(.failure) }
                if battery <= session.policy.minimumBattery { return .stop(.lowBattery) }
            }
            if !session.policy.allowBattery || session.policy.pauseOnDisconnect { return .waitForPower }
        }
        return .run
    }

    static func wantsDisplay(_ mode: DisplayMode, lidClosed: Bool?, manuallyOff: Bool) -> Bool {
        guard !manuallyOff else { return false }
        switch mode {
        case .system: return false
        case .closed, .displayOnly: return lidClosed == false
        case .always: return true
        }
    }

    static func endsOnSleep(_ mode: DisplayMode, lidClosed: Bool?) -> Bool {
        !(lidClosed == true && (mode == .closed || mode == .displayOnly))
    }
}

struct HelperRequest: Codable, Sendable {
    enum Action: String, Codable { case start, renew, stop, status, screenOff, resumeDisplay, extend, setDeadline }
    var action: Action
    var session: Session?
    var sessionID: UUID?
    var deadline: Date?
}

struct HelperStatus: Codable, Sendable {
    var session: Session?
    var power: PowerSnapshot
    var phase: String
    var systemAssertion: Bool
    var displayAssertion: Bool
    var manualDisplayOff: Bool
    var screenSaverPaused: Bool
    var error: String?
    var endReason: EndReason?
    var recovery: [String]
    var screenSleepFailed: Bool?
    var endedSessionID: UUID?
}

enum SessionNotificationRules {
    static func endedSession(previous: Session?, status: HelperStatus, requestedReason: EndReason? = nil) -> EndReason? {
        guard previous != nil, status.session == nil, let reason = status.endReason else { return nil }
        return reason == .manual ? requestedReason ?? reason : reason
    }

    static func warnsAboutWarmth(previous: Int, next: Int, hasSession: Bool) -> Bool {
        hasSession && previous != next && next == 1
    }

    static func reminderDue(status: HelperStatus?, lastReminder: Date, now: Date, intervalMinutes: Int) -> Bool {
        guard let status, status.session?.mode == .always, status.phase == "active",
              status.systemAssertion, status.displayAssertion, !status.manualDisplayOff, status.error == nil else { return false }
        return now.timeIntervalSince(lastReminder) >= Double(intervalMinutes) * 60
    }
}

enum ServiceIdentity {
    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Qiming"
    }
    static let app = "com.qiming.mac"
    static let helper = "com.qiming.mac.helper"
    static let plist = "com.qiming.mac.helper.plist"
    static let protocolVersion = 1
}

@objc protocol QimingHelperProtocol {
    func perform(_ request: Data, reply: @escaping (Data) -> Void)
}
