import Foundation
import ServiceManagement

@MainActor final class HelperClient {
    private var connection: NSXPCConnection?
    private var connectionID: UUID?
    private(set) var connected = false
    var disconnected: (() -> Void)?
    var service: SMAppService { .daemon(plistName: ServiceIdentity.plist) }
    var statusKey: String {
        if Signing.teamID() == nil { return "helper.signing" }
        switch service.status {
        case .enabled: return connected ? "helper.connected" : "helper.ready"
        case .requiresApproval: return "helper.approval"
        case .notRegistered: return "helper.missing"
        case .notFound: return "helper.notFound"
        @unknown default: return "helper.unknown"
        }
    }
    var ready: Bool { Signing.teamID() != nil && service.status == .enabled }

    func checkAtLaunch(repairRegistration: Bool) async throws -> HelperStatus {
        let request = HelperRequest(action: .status)
        do {
            return try await perform(request)
        } catch {
            let failure = error as NSError
            guard repairRegistration, ready, failure.domain == NSCocoaErrorDomain else { throw error }
            switch failure.code {
            case 4102: // NSXPCConnectionCodeSigningRequirementFailure
                try await replaceRegistration()
                try await registerService(promptForApproval: false)
            case CocoaError.Code.xpcConnectionInterrupted.rawValue, CocoaError.Code.xpcConnectionInvalid.rawValue:
                invalidate()
            default:
                throw error
            }
            return try await perform(request)
        }
    }

    func register() async throws {
        guard Signing.teamID() != nil else { throw ClientError.message("helper.signing.detail") }
        if service.status == .enabled {
            do { _ = try await perform(HelperRequest(action: .status)); return }
            catch {
                // Moving/replacing the development app can leave launchd bound to its old helper.
                // An explicit Configure action repairs registration using this app's embedded helper.
                try await replaceRegistration()
            }
        }
        try await registerService(promptForApproval: true)
    }

    private func replaceRegistration() async throws {
        try await unregister()
        // Allow Background Task Management to commit the removal before re-registering.
        try await Task.sleep(for: .seconds(2))
    }

    private func registerService(promptForApproval: Bool) async throws {
        for attempt in 0..<3 {
            do { try service.register(); break }
            catch {
                if service.status == .requiresApproval {
                    if promptForApproval { SMAppService.openSystemSettingsLoginItems() }
                    return
                }
                let failure = error as NSError
                guard attempt < 2, failure.domain == "SMAppServiceErrorDomain", failure.code == 1 else { throw error }
                try await Task.sleep(for: .seconds(1))
            }
        }
        if promptForApproval, service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
    func unregister() async throws {
        invalidate()
        try await service.unregister()
    }
    func invalidate() {
        let old = connection
        connection = nil; connectionID = nil; connected = false
        old?.invalidate()
    }

    private func connect() throws -> NSXPCConnection {
        if let connection { return connection }
        guard ready, let team = Signing.teamID() else { throw ClientError.message(statusKey) }
        let connection = NSXPCConnection(machServiceName: ServiceIdentity.helper, options: .privileged)
        let id = UUID()
        connectionID = id
        connection.setCodeSigningRequirement(Signing.requirement(identifier: ServiceIdentity.helper, team: team))
        connection.remoteObjectInterface = NSXPCInterface(with: QimingHelperProtocol.self)
        connection.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor in
                guard self?.connectionID == id else { return }
                self?.connection = nil; self?.connectionID = nil; self?.connected = false
                self?.disconnected?()
            }
        }
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor in
                guard self?.connectionID == id else { return }
                self?.connection = nil; self?.connectionID = nil; self?.connected = false
            }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    func perform(_ request: HelperRequest) async throws -> HelperStatus {
        let data = try JSONEncoder().encode(request)
        let connection = try connect()
        let response: Data = try await withCheckedThrowingContinuation { continuation in
            let gate = ReplyGate(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in gate.complete(.failure(error)) }
            guard let service = proxy as? QimingHelperProtocol else {
                gate.complete(.failure(ClientError.message("error.connection"))); return
            }
            service.perform(data) { @Sendable data in gate.complete(.success(data)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
                gate.complete(.failure(ClientError.message("error.timeout")))
            }
        }
        let status = try JSONDecoder().decode(HelperStatus.self, from: response)
        connected = true
        return status
    }
}

enum ClientError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case let .message(key): return key }
    }
}

private final class ReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    init(_ continuation: CheckedContinuation<Data, any Error>) { self.continuation = continuation }
    func complete(_ result: Result<Data, any Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
