import Foundation
import OSLog

// Fail closed for unsigned / ad-hoc binaries. Never weaken privileged XPC authentication in Debug.
guard geteuid() == 0, let team = Signing.teamID() else {
    fputs("QimingHelper requires root and an Apple-issued signing identity.\n", stderr)
    exit(78)
}
do {
    let core = try HelperCore()
    let delegate = HelperListener(core: core, team: team)
    let listener = NSXPCListener(machServiceName: ServiceIdentity.helper)
    listener.delegate = delegate
    let events = PowerEvents()
    events.changed = { _ in core.powerChanged() }
    events.start()
    listener.resume()
    withExtendedLifetime((delegate, events, listener)) { RunLoop.main.run() }
} catch {
    Logger(subsystem: ServiceIdentity.helper, category: "Recovery").fault("Recovery failed: \(error.localizedDescription, privacy: .public)")
    exit(78)
}
