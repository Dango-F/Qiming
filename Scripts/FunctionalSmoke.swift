// Manual integration test against the installed, approved production helper.
// Compile with Shared/Session.swift and Shared/Signing.swift, then sign this temporary
// executable with the project's Apple Development identity and com.qiming.mac identifier.
// Quit Qiming first. This test changes power state briefly and always attempts cleanup.
// It never enables Always On or changes screen-saver / lock preferences.
import Foundation

private enum SmokeError: Error { case failed(String) }

private final class ResponseGate: @unchecked Sendable {
    let lock = NSLock()
    var continuation: CheckedContinuation<Data, any Error>?
    init(_ continuation: CheckedContinuation<Data, any Error>) { self.continuation = continuation }
    func complete(_ result: Result<Data, any Error>) {
        lock.lock(); let value = continuation; continuation = nil; lock.unlock()
        value?.resume(with: result)
    }
}

private final class Client {
    let connection: NSXPCConnection
    init(team: String) {
        connection = NSXPCConnection(machServiceName: ServiceIdentity.helper, options: .privileged)
        connection.setCodeSigningRequirement(Signing.requirement(identifier: ServiceIdentity.helper, team: team))
        connection.remoteObjectInterface = NSXPCInterface(with: QimingHelperProtocol.self)
        connection.resume()
    }
    func send(_ action: HelperRequest.Action, session: Session? = nil, id: UUID? = nil) async throws -> HelperStatus {
        let request = try JSONEncoder().encode(HelperRequest(action: action, session: session, sessionID: id))
        let response: Data = try await withCheckedThrowingContinuation { continuation in
            let gate = ResponseGate(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in gate.complete(.failure(error)) }
            guard let remote = proxy as? QimingHelperProtocol else {
                gate.complete(.failure(SmokeError.failed("proxy"))); return
            }
            remote.perform(request) { @Sendable data in gate.complete(.success(data)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
                gate.complete(.failure(SmokeError.failed("XPC timeout")))
            }
        }
        return try JSONDecoder().decode(HelperStatus.self, from: response)
    }
    func close() { connection.invalidate() }
    deinit { connection.invalidate() }
}

@main struct FunctionalSmoke {
    static func check(_ condition: Bool, _ name: String, _ status: HelperStatus? = nil) throws {
        guard condition else { throw SmokeError.failed("\(name): \(status?.error ?? "unexpected state")") }
        print("PASS \(name)")
        fflush(stdout)
    }
    static func main() async {
        guard let team = Signing.teamID() else { print("FAIL Apple-issued signing identity required"); exit(1) }
        let client = Client(team: team)
        var ownedID: UUID?
        do {
            let baseline = try await client.send(.status)
            try check(baseline.session == nil && baseline.power.sleepDisabled == false, "idle baseline", baseline)
            print("ENV onAC=\(String(describing: baseline.power.onAC)) battery=\(String(describing: baseline.power.battery))")

            let session = Session(mode: .closed, deadline: Date().addingTimeInterval(60), policy: ProtectionPolicy())
            let active = try await client.send(.start, session: session); ownedID = active.session?.id
            try check(active.error == nil && active.phase == "active" && active.systemAssertion && active.displayAssertion,
                      "session start and real assertions", active)
            let extended = try await client.send(.extend, id: ownedID)
            try check(extended.error == nil && extended.session?.id == session.id &&
                      extended.session?.deadline == session.deadline?.addingTimeInterval(1800), "extend 30 minutes", extended)
            let stale = try await client.send(.stop, id: UUID())
            try check(stale.error != nil && stale.session?.id == ownedID, "stale request rejected", stale)
            let renewed = try await client.send(.renew, id: ownedID)
            try check(renewed.error == nil && renewed.session?.id == ownedID, "lease renewal", renewed)
            let stopped = try await client.send(.stop, id: ownedID); ownedID = nil
            try check(stopped.error == nil && stopped.session == nil && !stopped.systemAssertion &&
                      !stopped.displayAssertion && stopped.power.sleepDisabled == false, "manual stop restores system", stopped)

            for i in 1...3 {
                let next = try await client.send(.start, session: Session(mode: .closed, policy: ProtectionPolicy()))
                ownedID = next.session?.id
                try check(next.error == nil && next.phase == "active", "rapid start \(i)", next)
                let end = try await client.send(.stop, id: ownedID); ownedID = nil
                try check(end.error == nil && end.power.sleepDisabled == false, "rapid restore \(i)", end)
            }

            if baseline.power.onAC == false {
                var policy = ProtectionPolicy(); policy.allowBattery = false
                let waiting = try await client.send(.start, session: Session(mode: .closed, policy: policy))
                ownedID = waiting.session?.id
                try check(waiting.error == nil && waiting.phase == "waiting" && !waiting.systemAssertion &&
                          !waiting.displayAssertion && waiting.power.sleepDisabled == false, "AC-only policy waits without error", waiting)
                _ = try await client.send(.stop, id: ownedID); ownedID = nil
            }

            let timed = try await client.send(.start, session: Session(mode: .closed,
                deadline: Date().addingTimeInterval(4), policy: ProtectionPolicy()))
            ownedID = timed.session?.id
            try check(timed.error == nil && timed.phase == "active", "short timer starts", timed)
            try await Task.sleep(for: .seconds(6))
            let expired = try await client.send(.status); ownedID = nil
            try check(expired.session == nil && expired.endReason == .expired && expired.power.sleepDisabled == false &&
                      !expired.systemAssertion && !expired.displayAssertion, "deadline expires without UI", expired)

            let disconnecting = Client(team: team)
            let transient = try await disconnecting.send(.start, session: Session(mode: .closed, policy: ProtectionPolicy()))
            try check(transient.error == nil && transient.phase == "active", "disconnect setup", transient)
            disconnecting.close()
            try await Task.sleep(for: .seconds(2))
            let disconnected = try await client.send(.status)
            try check(disconnected.session == nil && disconnected.endReason == .disconnected &&
                      disconnected.power.sleepDisabled == false && !disconnected.systemAssertion &&
                      !disconnected.displayAssertion, "client loss restores system", disconnected)

            let leased = try await client.send(.start, session: Session(mode: .closed, policy: ProtectionPolicy()))
            ownedID = leased.session?.id
            try check(leased.error == nil && leased.phase == "active", "lease timeout setup", leased)
            print("WAIT 46 seconds without renewal"); fflush(stdout)
            try await Task.sleep(for: .seconds(46))
            let lostLease = try await client.send(.status); ownedID = nil
            try check(lostLease.session == nil && lostLease.endReason == .disconnected &&
                      lostLease.power.sleepDisabled == false && !lostLease.systemAssertion &&
                      !lostLease.displayAssertion, "expired lease restores system", lostLease)
            print("PASS all primary integration checks; final idle, no Qiming assertions")
        } catch {
            if let ownedID { _ = try? await client.send(.stop, id: ownedID) }
            print("FAIL \(error)"); client.close(); exit(1)
        }
        client.close()
    }
}
