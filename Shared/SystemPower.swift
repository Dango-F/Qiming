import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps

enum PowerError: LocalizedError {
    case operation(String, Int32)
    case unavailable(String)
    case screenSleep(String)
    var errorDescription: String? {
        switch self {
        case let .operation(name, code): return "\(name): IOReturn \(code)"
        case let .unavailable(name): return "Unavailable: \(name)"
        case let .screenSleep(detail): return detail
        }
    }
}

struct ExternalSleepBlocker: Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case idleSystem, system, idleDisplay

        init?(assertionType: String) {
            switch assertionType {
            case "PreventUserIdleSystemSleep", "NoIdleSleepAssertion": self = .idleSystem
            case "PreventSystemSleep": self = .system
            case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion": self = .idleDisplay
            default: return nil
            }
        }
    }

    let process: String
    let kind: Kind
}

enum SystemPower {
    static func supplyState(timeRemaining: TimeInterval) -> Bool? {
        guard timeRemaining.isFinite else { return nil }
        if timeRemaining == kIOPSTimeRemainingUnlimited { return true }
        return timeRemaining >= 0 ? false : nil
    }

    /// Reads the published supply state without fetching the full power-source dictionary.
    static func activeSupply() -> Bool? {
        supplyState(timeRemaining: IOPSGetTimeRemainingEstimate())
    }

    static func rootProperty(_ key: String) -> Any? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func snapshot() -> PowerSnapshot {
        var result = PowerSnapshot()
        result.lidClosed = rootProperty("AppleClamshellState") as? Bool
        result.sleepDisabled = rootProperty("SleepDisabled") as? Bool
        result.thermal = ProcessInfo.processInfo.thermalState.rawValue
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            result.onAC = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPSACPowerValue
            let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
            for source in sources {
                guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                if let current = d[kIOPSCurrentCapacityKey] as? Int,
                   let maximum = d[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                    result.battery = min(100, max(0, current * 100 / maximum))
                }
                result.charging = d[kIOPSIsChargingKey] as? Bool
            }
        }
        return result
    }

    /// Only fixed, internal arguments are passed. No shell or caller-supplied command is accepted.
    @discardableResult static func pmset(_ arguments: [String]) throws -> String {
        let allowed = [["-a", "disablesleep", "0"], ["-a", "disablesleep", "1"], ["displaysleepnow"]]
        guard allowed.contains(arguments) else { throw PowerError.unavailable("pmset arguments") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // pmset is a local system utility with bounded output. A stalled child is terminated.
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw PowerError.unavailable("pmset [\(process.terminationStatus)]: \(output)")
        }
        return output
    }

    static func assertionDetails() -> String {
        var unmanaged: Unmanaged<CFDictionary>?
        let code = IOPMCopyAssertionsByProcess(&unmanaged)
        guard code == kIOReturnSuccess, let dictionary = unmanaged?.takeRetainedValue() as? [AnyHashable: Any] else {
            return "IOPMCopyAssertionsByProcess: \(code)"
        }
        // No process paths, arguments, network addresses or environment are collected.
        return dictionary.map { pid, assertions in "PID \(pid): \(assertions)" }.sorted().joined(separator: "\n")
    }

    static func externalSleepBlockers() -> [ExternalSleepBlocker] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let dictionary = unmanaged?.takeRetainedValue() as? [AnyHashable: Any] else { return [] }
        return classifySleepBlockers(dictionary)
    }

    static func classifySleepBlockers(_ dictionary: [AnyHashable: Any]) -> [ExternalSleepBlocker] {
        let systemProcesses: Set<String> = ["powerd", "WindowServer", "loginwindow", "mds", "mds_stores",
                                            "Qiming", "Qiming Dev", "QimingHelper"]
        var blockers: Set<ExternalSleepBlocker> = []
        for value in dictionary.values {
            guard let entries = value as? [[String: Any]] else { continue }
            for entry in entries {
                let effective = (entry["AssertTrueType"] as? String).flatMap(ExternalSleepBlocker.Kind.init(assertionType:))
                let declared = (entry["AssertType"] as? String).flatMap(ExternalSleepBlocker.Kind.init(assertionType:))
                guard let name = entry["Process Name"] as? String, !systemProcesses.contains(name),
                      let kind = effective ?? declared,
                      let level = entry["AssertLevel"] as? Int, level > 0 else { continue }
                blockers.insert(ExternalSleepBlocker(process: name, kind: kind))
            }
        }
        return blockers.sorted { ($0.kind.rawValue, $0.process) < ($1.kind.rawValue, $1.process) }
    }
}

final class PowerAssertions {
    private(set) var system: IOPMAssertionID = 0
    private(set) var display: IOPMAssertionID = 0

    private func create(_ type: CFString, suffix: String) throws -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let code = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             "Qiming · \(suffix)" as CFString, &id)
        guard code == kIOReturnSuccess else { throw PowerError.operation(suffix, code) }
        return id
    }
    func apply(system enabled: Bool, display displayEnabled: Bool) throws {
        // Release conflicting display assertions before acquiring a different policy.
        if !displayEnabled, display != 0 {
            let code = IOPMAssertionRelease(display)
            guard code == kIOReturnSuccess else { throw PowerError.operation("display.release", code) }
            display = 0
        }
        if !enabled, system != 0 {
            let code = IOPMAssertionRelease(system)
            guard code == kIOReturnSuccess else { throw PowerError.operation("system.release", code) }
            system = 0
        }
        do {
            if enabled, system == 0 { system = try create(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, suffix: "system") }
            if displayEnabled, display == 0 {
                display = try create(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, suffix: "display")
            }
        } catch { release(); throw error }
    }
    @discardableResult func release() -> [String] {
        var failures: [String] = []
        if display != 0 {
            let code = IOPMAssertionRelease(display)
            if code == kIOReturnSuccess { display = 0 } else { failures.append("display.release: \(code)") }
        }
        if system != 0 {
            let code = IOPMAssertionRelease(system)
            if code == kIOReturnSuccess { system = 0 } else { failures.append("system.release: \(code)") }
        }
        return failures
    }
    var verifiedSystem: Bool { system != 0 && IOPMAssertionCopyProperties(system) != nil }
    var verifiedDisplay: Bool { display != 0 && IOPMAssertionCopyProperties(display) != nil }
    deinit { release() }
}

/// Event driven in both processes. IOKit and power-source callbacks run on the main run loop.
enum PowerEvent: String, Sendable { case supply, information, system, thermal }

final class PowerEvents: @unchecked Sendable {
    var changed: (@MainActor @Sendable (PowerEvent) -> Void)?
    private var port: IONotificationPortRef?
    private var interest: io_object_t = 0
    private var source: CFRunLoopSource?
    private var supplySource: CFRunLoopSource?
    private var thermalObserver: NSObjectProtocol?

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerEvents>.fromOpaque(context).takeUnretainedValue().deliver(.information)
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        supplySource = IOPSCreateLimitedPowerNotification({ context in
            guard let context else { return }
            Unmanaged<PowerEvents>.fromOpaque(context).takeUnretainedValue().deliver(.supply)
        }, context)?.takeRetainedValue()
        if let supplySource { CFRunLoopAddSource(CFRunLoopGetMain(), supplySource, .commonModes) }
        port = IONotificationPortCreate(kIOMainPortDefault)
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        if let port, root != 0 {
            IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { context, _, _, _ in
                guard let context else { return }
                Unmanaged<PowerEvents>.fromOpaque(context).takeUnretainedValue().deliver(.system)
            }, context, &interest)
            if let loop = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
                CFRunLoopAddSource(CFRunLoopGetMain(), loop, .commonModes)
            }
        }
        if root != 0 { IOObjectRelease(root) }
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.deliver(.thermal) }
    }
    private func deliver(_ event: PowerEvent) {
        // Both CF sources and IOKit port are registered on the main run loop;
        // thermal notifications are explicitly delivered on the main queue.
        MainActor.assumeIsolated { changed?(event) }
    }
    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let supplySource { CFRunLoopRemoveSource(CFRunLoopGetMain(), supplySource, .commonModes) }
        if interest != 0 { IOObjectRelease(interest) }
        if let port { IONotificationPortDestroy(port) }
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
    }
}
