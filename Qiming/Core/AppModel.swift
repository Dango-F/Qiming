import AppKit
import UserNotifications
import ServiceManagement
import OSLog

struct EventEntry {
    var date = Date()
    var key: String
    var detail: String
}

@MainActor final class AppModel {
    let helper = HelperClient()
    private(set) var power = SystemPower.snapshot()
    private(set) var status: HelperStatus?
    private(set) var busy = false
    private(set) var messageKey: String?
    private(set) var technicalError: String?
    private(set) var connectionUnverified = false
    private(set) var externalBlockers: [ExternalSleepBlocker] = []
    private(set) var events: [EventEntry] = []
    private var listeners: [UUID: () -> Void] = [:]
    private var leaseTimer: Timer?
    private lazy var deadlineMonitor = SessionDeadlineMonitor { [weak self] id, deadline in
        await self?.confirmExpiry(id: id, deadline: deadline) ?? false
    }
    private let powerEvents = PowerEvents()
    private lazy var powerRefresh = PowerEventRefresh(
        isBlocked: { [weak self] in self?.busy == true || self?.querying == true },
        refresh: { [weak self] in await self?.refresh() })
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var lastThermal = -1
    private var lastThermalCheckedAt = Date.distantPast
    private var lastReminder = Date()
    private var querying = false
    private var revision: UInt64 = 0
    private var powerSource = PowerSourceTracker(onAC: nil)
    private var notificationRevision: UInt64 = 0
    private(set) var notificationDetailKey = "notifications.checking"
    private(set) var notificationError: String?
    var notificationsNeedSettings: Bool {
        notifications && ["notifications.denied", "notifications.quiet"].contains(notificationDetailKey)
    }
    private let log = Logger(subsystem: ServiceIdentity.app, category: "Session")
    var mode: DisplayMode { status?.session?.mode ?? .system }
    var session: Session? { status?.session }
    var isActive: Bool {
        guard !connectionUnverified, let status, status.phase == "active" else { return false }
        if mode == .displayOnly {
            return status.displayAssertion
                || !SessionRules.wantsDisplay(mode, lidClosed: status.power.lidClosed, manuallyOff: status.manualDisplayOff)
        }
        return status.systemAssertion
    }
    var duration: TimeInterval {
        get { UserDefaults.standard.double(forKey: "duration") }
        set { saveDuration(newValue, until: nil); changed() }
    }
    private var untilDate: Date?
    private var sessionDuration: (seconds: TimeInterval, until: Date?)?
    var panelDuration: (seconds: TimeInterval, until: Date?) {
        sessionDuration ?? (duration, untilDate)
    }

    private func saveDuration(_ seconds: TimeInterval, until date: Date?) {
        if date == nil { UserDefaults.standard.set(max(0, seconds), forKey: "duration") }
        untilDate = date
    }
    var glassAppearance: GlassAppearanceVariant {
        get { .current }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "glassAppearanceVariant"); changed() }
    }
    var glassFontColor: GlassFontColor {
        didSet {
            guard glassFontColor != oldValue else { return }
            UserDefaults.standard.set(glassFontColor.rawValue, forKey: "glassFontColor")
            changed()
        }
    }
    var glassTransparency: Double {
        get {
            guard UserDefaults.standard.object(forKey: "glassTransparency") != nil else {
                return GlassConfiguration.defaultTransparency
            }
            let value = UserDefaults.standard.double(forKey: "glassTransparency")
            return value.isFinite ? min(1, max(0, value)) : GlassConfiguration.defaultTransparency
        }
        set {
            let value = newValue.isFinite ? min(1, max(0, newValue)) : GlassConfiguration.defaultTransparency
            UserDefaults.standard.set(value, forKey: "glassTransparency")
            changed()
        }
    }
    var policy: ProtectionPolicy {
        get {
            UserDefaults.standard.data(forKey: "protection").flatMap { try? JSONDecoder().decode(ProtectionPolicy.self, from: $0) }
                ?? ProtectionPolicy()
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "protection")
            changed()
        }
    }
    var notifications: Bool {
        get { UserDefaults.standard.bool(forKey: "notifications") }
        set {
            UserDefaults.standard.set(newValue, forKey: "notifications")
            notificationRevision &+= 1
            notificationError = nil
            notificationDetailKey = newValue ? "notifications.checking" : "notifications.off"
            changed()
            if newValue { Task { await self.checkNotificationPermission(requestAuthorization: true, announce: true) } }
        }
    }

    init() {
        let defaults = UserDefaults.standard
        if let savedColor = defaults.string(forKey: "glassFontColor").flatMap(GlassFontColor.init(rawValue:)) {
            glassFontColor = savedColor
        } else {
            let variant = GlassAppearanceVariant.current
            let dark = UI.isDark(NSApp.effectiveAppearance)
            glassFontColor = variant.usesGrayBacking || (variant == .optimized && dark) ? .white : .black
            defaults.set(glassFontColor.rawValue, forKey: "glassFontColor")
        }
        powerSource = PowerSourceTracker(onAC: power.onAC, checkedAt: power.checkedAt)
        helper.disconnected = { [weak self] in
            guard let self else { return }
            self.revision &+= 1
            self.connectionUnverified = true
            self.messageKey = "error.disconnected"
            self.technicalError = "XPC interrupted; helper invalidation cleanup / 45 s lease fallback"
            self.stopLeaseTimer()
            self.record("event.disconnected")
            self.changed()
        }
        powerEvents.changed = { [weak self] event in self?.powerChanged(event) }
        powerEvents.start()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let session = self.session else { return }
                let lidClosed = SystemPower.rootProperty("AppleClamshellState") as? Bool
                guard SessionRules.endsOnSleep(session.mode, lidClosed: lidClosed) else {
                    self.log.notice("Lid is closed; keeping \(session.mode.rawValue, privacy: .public) session on sleep notification")
                    return
                }
                await self.stop(reason: .sleep)
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.powerChanged() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.resumeDisplay() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.checkNotificationPermission() }
            })
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            distributedObservers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard self?.mode == .always else { return }
                    await self?.stop(reason: .locked)
                }
            })
        }
        record("event.launch")
    }

    @discardableResult func observe(_ block: @escaping () -> Void) -> UUID {
        let id = UUID(); listeners[id] = block; return id
    }
    func removeObserver(_ id: UUID) { listeners[id] = nil }
    func changed() { for listener in Array(listeners.values) { listener() } }
    func clearMessage() { messageKey = nil; technicalError = nil; changed() }

    func checkNotificationPermission(requestAuthorization: Bool = false, announce: Bool = false) async {
        let token = notificationRevision
        guard notifications else { notificationDetailKey = "notifications.off"; changed(); return }
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        guard token == notificationRevision, notifications else { return }
        do {
            if requestAuthorization, settings.authorizationStatus == .notDetermined {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
                settings = await center.notificationSettings()
            }
            guard token == notificationRevision, notifications else { return }
            notificationError = nil
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                notificationDetailKey = settings.alertSetting == .enabled ? "notifications.ready" : "notifications.quiet"
            case .denied:
                notificationDetailKey = "notifications.denied"
            case .notDetermined:
                notificationDetailKey = "notifications.notDetermined"
            @unknown default:
                notificationDetailKey = "notifications.notDetermined"
            }
            changed()
            if announce {
                if notificationsNeedSettings { openNotificationSettings() }
                else if settings.authorizationStatus == .authorized {
                    notify("notifications.enabled", body: "notifications.enabled.body")
                }
            }
        } catch {
            guard token == notificationRevision, notifications else { return }
            notificationDetailKey = "notifications.failed"
            notificationError = error.localizedDescription
            record("notifications.failed", error.localizedDescription)
            changed()
        }
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications?id=\(ServiceIdentity.app)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// A registered helper is only ready for an update once it replies without an operation error.
    func checkHelperOnLaunch(repairRegistration: Bool) async -> String? {
        guard helper.ready else { return L(helper.statusKey) }
        busy = true
        changed()
        defer { busy = false; changed() }
        do {
            let result = try await helper.checkAtLaunch(repairRegistration: repairRegistration)
            apply(result)
            return result.error
        } catch {
            fail(error)
            return technicalError ?? messageKey.map(L) ?? error.localizedDescription
        }
    }
    func languageChanged() {
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "SCREEN_REMINDER", actions: [
                UNNotificationAction(identifier: "SWITCH", title: L("mode.closed")),
                UNNotificationAction(identifier: "STOP", title: L("stop"))
            ], intentIdentifiers: [])
        ])
        changed()
    }

    func start(_ mode: DisplayMode) async {
        guard !busy else { return }
        if mode == .system { await stop(); return }
        busy = true; revision &+= 1
        let token = revision
        clearMessage(); changed()
        defer { busy = false; changed() }
        let selection = (seconds: duration, until: untilDate)
        let deadline = selection.until ?? (selection.seconds > 0 ? Date().addingTimeInterval(selection.seconds) : nil)
        let next = Session(mode: mode, deadline: deadline, policy: policy)
        do {
            if mode == .always, CFPreferencesAppValueIsForced("idleTime" as CFString, "com.apple.screensaver" as CFString) {
                throw ClientError.message("error.managed")
            }
            let result = try await helper.perform(HelperRequest(action: .start, session: next))
            guard token == revision else { return }
            apply(result)
            if result.error == nil, result.session?.id == next.id {
                sessionDuration = selection
                UserDefaults.standard.set(mode.rawValue, forKey: "lastMode")
                record("event.start", mode.rawValue)
                lastReminder = Date()
                startLeaseTimer()
            }
        } catch { fail(error) }
    }

    func stop(reason: EndReason = .manual) async {
        guard !busy else { return }
        if session == nil && !helper.ready { clearMessage(); return }
        busy = true; revision &+= 1
        let token = revision
        changed()
        defer { busy = false; changed() }
        do {
            let result = try await helper.perform(HelperRequest(action: .stop, sessionID: session?.id))
            guard token == revision else { return }
            apply(result, requestedEndReason: reason)
            if result.session == nil {
                stopLeaseTimer()
                if result.error == nil { messageKey = reason == .manual ? nil : reason.key }
            }
        } catch { fail(error) }
    }

    func screenOff() async {
        guard !busy else { return }
        busy = true; revision &+= 1
        let token = revision
        changed()
        defer { busy = false; changed() }
        let session = self.session
        do {
            if let session {
                let result = try await helper.perform(HelperRequest(action: .screenOff, sessionID: session.id))
                guard token == revision else { return }
                apply(result, screenRequest: true)
                guard result.error == nil else { return }
            } else {
                _ = try await Task.detached { try SystemPower.pmset(["displaysleepnow"]) }.value
                guard token == revision else { return }
                if messageKey == "screen.failed" { technicalError = nil }
            }
            messageKey = "screen.requested"
            record("event.screenOff")
        } catch {
            guard token == revision else { return }
            if session != nil { connectionUnverified = true }
            messageKey = "screen.failed"
            if let client = error as? ClientError, case let .message(key) = client {
                technicalError = L(key)
            } else {
                technicalError = error.localizedDescription
            }
            record("screen.failed", technicalError ?? "")
        }
    }

    func resumeDisplay() async {
        if messageKey == "screen.requested" { clearMessage() }
        guard !busy, let session, status?.manualDisplayOff == true else { return }
        busy = true; revision &+= 1
        let token = revision
        defer { busy = false; changed() }
        do {
            let result = try await helper.perform(HelperRequest(action: .resumeDisplay, sessionID: session.id))
            guard token == revision else { return }
            apply(result)
        }
        catch { fail(error) }
    }

    func changePanelDuration(_ seconds: TimeInterval, until date: Date? = nil) async {
        guard !busy else { return }
        guard let session else {
            saveDuration(seconds, until: date)
            changed()
            return
        }
        busy = true; revision &+= 1
        let token = revision
        changed()
        defer { busy = false; changed() }
        let deadline = date ?? (seconds > 0 ? Date().addingTimeInterval(seconds) : nil)
        do {
            let result = try await helper.perform(HelperRequest(action: .setDeadline, sessionID: session.id, deadline: deadline))
            guard token == revision else { return }
            apply(result)
            if result.error == nil, result.session?.id == session.id {
                sessionDuration = (seconds, date)
                saveDuration(seconds, until: date)
            }
        } catch { if token == revision { fail(error) } }
    }

    func extendSession() async {
        guard !busy, let session, session.deadline != nil else { return }
        busy = true; revision &+= 1
        let token = revision
        changed()
        defer { busy = false; changed() }
        do {
            let result = try await helper.perform(HelperRequest(action: .extend, sessionID: session.id))
            guard token == revision else { return }
            apply(result)
        }
        catch { fail(error) }
    }

    func refresh() async {
        guard !querying, !busy else { changed(); return }
        querying = true
        let token = revision
        do {
            defer { querying = false; changed() }
            // Power-source dictionaries can require a synchronous powerd round trip.
            // Keep the main run loop free to deliver the supply/thermal fast paths.
            let nextPower = await Task.detached(priority: .userInitiated) { SystemPower.snapshot() }.value
            guard token == revision, !busy else { return }
            updatePower(nextPower)
            if helper.ready {
                do {
                    let result = try await helper.perform(HelperRequest(action: .status))
                    guard token == revision, !busy else { return }
                    apply(result)
                }
                catch { if token == revision { fail(error) } }
            }
        }
        let blockers = await Task.detached { SystemPower.externalSleepBlockers() }.value
        guard token == revision else { return }
        externalBlockers = blockers
        changed()
    }

    private func renew() async {
        guard !busy, !querying, let session else { return }
        querying = true
        let token = revision
        defer { querying = false; changed() }
        do {
            let result = try await helper.perform(HelperRequest(action: .renew, sessionID: session.id))
            guard token == revision, !busy else { return }
            apply(result)
        }
        catch { if token == revision { fail(error); helper.invalidate(); stopLeaseTimer() } }
        if !connectionUnverified, SessionNotificationRules.reminderDue(status: status,
            lastReminder: lastReminder, now: Date(), intervalMinutes: policy.reminderMinutes) {
            lastReminder = Date()
            messageKey = "reminder.body"
            notify("reminder.title", body: "reminder.body", category: "SCREEN_REMINDER")
            record("event.reminder")
        }
    }

    private func confirmExpiry(id: UUID, deadline: Date) async -> Bool {
        guard session?.id == id, session?.deadline == deadline else { return false }
        guard !busy, !querying else { return true }
        querying = true
        let token = revision
        changed()
        defer { querying = false; changed() }
        do {
            // Do not put the external-process diagnostics scan ahead of the expiry reply.
            let result = try await helper.perform(HelperRequest(action: .status))
            guard token == revision, !busy else { return true }
            apply(result)
            return result.error == nil && result.session?.id == id && result.session?.deadline == deadline
        } catch {
            if token == revision { fail(error) }
            return false
        }
    }

    private func apply(_ result: HelperStatus, screenRequest: Bool = false, requestedEndReason: EndReason? = nil) {
        let previous = session
        let screenFailure = result.screenSleepFailed == true || (screenRequest && result.error != nil)
        status = result
        deadlineMonitor.update(result.session)
        updatePower(result.power)
        if result.session == nil, result.endReason == .expired,
           let expiredID = result.endedSessionID ?? previous?.id,
           UserDefaults.standard.string(forKey: "lastExpiredSessionID") != expiredID.uuidString {
            sessionDuration = nil
            saveDuration(0, until: nil)
            UserDefaults.standard.set(expiredID.uuidString, forKey: "lastExpiredSessionID")
        }
        connectionUnverified = result.error != nil && !screenFailure
        technicalError = result.error
        if let error = result.error {
            if screenFailure { messageKey = "screen.failed" }
            else if error.contains("protection.lowBattery") { messageKey = "reason.lowBattery" }
            else if error.contains("protection.thermal") { messageKey = "reason.thermal" }
            else if error.contains("protection.expired") { messageKey = "reason.expired" }
            else { messageKey = "error.operation" }
            if events.last?.detail != error { record(screenFailure ? "screen.failed" : "event.error", error) }
        } else if messageKey == "error.operation" || messageKey == "error.disconnected" || messageKey == "screen.failed" {
            messageKey = nil
        }
        if previous != nil, result.session == nil {
            sessionDuration = nil
            stopLeaseTimer()
            if let reason = SessionNotificationRules.endedSession(previous: previous, status: result,
                                                                 requestedReason: requestedEndReason) {
                if !screenFailure { messageKey = reason.key }
                notify("notification.stopped", body: reason.key)
                record("event.stop", reason.rawValue)
            }
        }
    }

    private func powerChanged(_ event: PowerEvent = .system) {
        if event == .supply { log.notice("power.signal supply") }
        if event == .thermal { log.notice("power.signal thermal") }
        let observedAt = Date()
        updateSupply(SystemPower.activeSupply(), checkedAt: observedAt)
        updateThermal(ProcessInfo.processInfo.thermalState.rawValue, checkedAt: observedAt)
        changed()
        powerRefresh.request()
    }

    private func updatePower(_ next: PowerSnapshot) {
        guard next.checkedAt >= power.checkedAt else { return }
        updateSupply(next.onAC, checkedAt: next.checkedAt)
        if power.lidClosed != next.lidClosed { record("event.lid", next.lidClosed == true ? "closed" : "open") }
        power = next
        power.onAC = powerSource.lastOnAC
        updateThermal(next.thermal, checkedAt: next.checkedAt)
        power.thermal = lastThermal
    }

    private func updateSupply(_ onAC: Bool?, checkedAt: Date) {
        if powerSource.disconnected(onAC: onAC, checkedAt: checkedAt) {
            notify("notification.power", body: session != nil ? "notification.power.body" : "notification.power.idle")
            record("event.power", "battery")
        }
        power.onAC = powerSource.lastOnAC
    }

    private func updateThermal(_ thermal: Int, checkedAt: Date) {
        guard checkedAt >= lastThermalCheckedAt else { return }
        if SessionNotificationRules.warnsAboutWarmth(previous: lastThermal, next: thermal, hasSession: session != nil) {
            messageKey = "thermal.warm.body"
            notify("thermal.warm", body: "thermal.warm.body")
        }
        lastThermal = thermal
        lastThermalCheckedAt = checkedAt
        power.thermal = thermal
    }

    private func startLeaseTimer() {
        stopLeaseTimer()
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.renew() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        leaseTimer = timer
    }
    private func stopLeaseTimer() { leaseTimer?.invalidate(); leaseTimer = nil }
    func fail(_ error: Error) {
        connectionUnverified = true
        if let client = error as? ClientError, case let .message(key) = client { messageKey = key; technicalError = nil }
        else {
            let failure = error as NSError
            messageKey = "error.operation"
            technicalError = "\(failure.localizedDescription) [\(failure.domain):\(failure.code)]"
            if let detail = failure.userInfo[NSDebugDescriptionErrorKey] as? String { technicalError? += " \(detail)" }
        }
        record("event.error", technicalError ?? messageKey ?? "")
        changed()
    }
    func record(_ key: String, _ detail: String = "") {
        events.append(EventEntry(key: key, detail: detail))
        if events.count > 120 { events.removeFirst(events.count - 120) }
        log.notice("\(key, privacy: .public) \(detail, privacy: .public)")
    }
    func notify(_ title: String, body: String, category: String = "") {
        guard notifications else { return }
        let content = UNMutableNotificationContent()
        content.title = L(title); content.body = L(body); content.categoryIdentifier = category
        content.sound = .default
        let submittedAt = ProcessInfo.processInfo.systemUptime
        let log = self.log
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString,
            content: content, trigger: nil)) { [weak self] error in
                let elapsed = (ProcessInfo.processInfo.systemUptime - submittedAt) * 1000
                log.notice("notification.submit \(title, privacy: .public) accepted=\(error == nil) latency_ms=\(elapsed)")
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.notificationError = error.localizedDescription
                        self.record("notifications.failed", error.localizedDescription)
                    } else {
                        self.notificationError = nil
                        self.record("notifications.queued", title)
                    }
                    self.changed()
                }
            }
    }
    private var externalAssertionSummary: String {
        let lines = ExternalSleepBlocker.Kind.allCases.compactMap { kind -> String? in
            let names = externalBlockers.filter { $0.kind == kind }.map(\.process)
            guard !names.isEmpty else { return nil }
            return "\(L("assertion.\(kind.rawValue)")) · \(names.joined(separator: ", "))"
        }
        return lines.isEmpty ? "—" : lines.joined(separator: "\n")
    }

    func statusSummary() -> String {
        let state: String
        if busy { state = "state.applying" }
        else if connectionUnverified { state = "state.unverified" }
        else if status?.phase == "waiting" { state = "state.waiting" }
        else if mode == .system { state = "state.system" }
        else if !isActive { state = "state.unverified" }
        else if mode == .displayOnly { state = "state.displayOnly" }
        else { state = "state.active" }
        func assertion(_ value: Bool?) -> String {
            value.map { L($0 ? "status.assertionHeld" : "status.assertionReleased") } ?? L("unknown")
        }
        let sleep = power.sleepDisabled.map { L($0 ? "enabled" : "status.notEnabled") } ?? L("unknown")
        let lid = power.lidClosed.map { L($0 ? "lid.closed" : "lid.open") } ?? L("unknown")
        let source = power.onAC.map { L($0 ? "power.ac" : "power.battery") } ?? L("unknown")
        let recovery = status?.recovery.joined(separator: "\n") ?? ""
        return """
        \(L("status.mode"))：\(L(mode.titleKey))
        \(L("status.result"))：\(L(state))
        \(L("status.helper"))：\(L(helper.statusKey))
        \(L("status.error"))：\(technicalError ?? (connectionUnverified ? messageKey.map(L) : nil) ?? L("status.noError"))

        \(L("status.systemAssertion"))：\(assertion(status?.systemAssertion))
        \(L("status.displayAssertion"))：\(assertion(status?.displayAssertion))
        \(L("status.sleepDisabled"))：\(sleep)
        \(L("status.lid"))：\(lid)
        \(L("status.power"))：\(source) · \(power.battery.map { "\($0)%" } ?? L("unknown"))
        \(L("status.thermal"))：\(L("thermal.level.\(power.thermal)"))
        \(L("status.recovery"))：
        \(recovery.isEmpty ? "—" : recovery)

        \(L("assertion.external"))：
        \(externalAssertionSummary)
        """
    }

    func diagnosticReport(assertions: String) -> String {
        let date = ISO8601DateFormatter().string(from: Date())
        return """
        Qiming diagnostics v1 — \(date)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        \(L("status.mode")): \(L(mode.titleKey)) [\(mode.rawValue)]
        \(L("status.helper")): \(L(helper.statusKey))
        phase: \(status?.phase ?? "unconnected")
        systemAssertion: \(status?.systemAssertion.description ?? "unknown")
        displayAssertion: \(status?.displayAssertion.description ?? "unknown")
        SleepDisabled: \(power.sleepDisabled?.description ?? "unknown")
        lidClosed: \(power.lidClosed?.description ?? "unknown")
        onAC: \(power.onAC?.description ?? "unknown")
        battery: \(power.battery.map(String.init) ?? "unknown")
        thermalState: \(power.thermal) · \(L("thermal.level.\(power.thermal)"))
        \(L("status.checked")): \(ISO8601DateFormatter().string(from: power.checkedAt))
        error: \(technicalError ?? "none")
        notifications: \(notifications) · \(L(notificationDetailKey))
        notificationError: \(notificationError ?? "none")
        recovery: \(status?.recovery.joined(separator: "; ") ?? "none")
        \(L("assertion.external")):
        \(externalAssertionSummary)

        \(L("status.events")):
        \(events.map { "\(ISO8601DateFormatter().string(from: $0.date)) \(L($0.key)) [\($0.detail)]" }.joined(separator: "\n"))

        \(L("status.assertions")):
        \(assertions)
        """
    }
}
