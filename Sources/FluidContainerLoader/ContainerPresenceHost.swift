import FluidContainerRuntime
import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS
import FluidPresence
import Foundation

/// Adapts the loader's `Audience` to presence's `IAudience`. In TS the extension host receives the
/// container's *signal* audience (container.ts `signalAudience`), which holds every client the
/// service reports, read and write; see `Container.signalAudience`.
///
/// A TS listener's exception propagates to whoever raised the event. `Audience` raises events
/// through the non-throwing `ListenerList`, so a throwing presence listener reports to `onError`,
/// which fails the container.
final class PresenceAudienceAdapter: IAudience {
    private let audience: Audience
    private let onError: (any Error) -> Void
    private var registrations: [Int: Int] = [:]
    private var nextToken = 0

    init(audience: Audience, onError: @escaping (any Error) -> Void) {
        self.audience = audience
        self.onError = onError
    }

    func getMembers() -> JSMap<JSString, IClient> {
        var members = JSMap<JSString, IClient>()
        for member in audience.getMembers() { members.set(member.clientId, member.client) }
        return members
    }

    func getMember(_ clientId: JSString) -> IClient? { audience.getMember(clientId) }

    @discardableResult
    func onAddMember(_ listener: @escaping (JSString, IClient) throws -> Void) -> Int {
        register { [onError] event in
            guard case .addMember(let clientId, let client) = event else { return }
            do { try listener(clientId, client) } catch { onError(error) }
        }
    }

    @discardableResult
    func onRemoveMember(_ listener: @escaping (JSString) throws -> Void) -> Int {
        register { [onError] event in
            guard case .removeMember(let clientId, _) = event else { return }
            do { try listener(clientId) } catch { onError(error) }
        }
    }

    func off(_ token: Int) {
        guard let registration = registrations.removeValue(forKey: token) else { return }
        audience.events.off(registration)
    }

    private func register(_ listener: @escaping (AudienceEvent) -> Void) -> Int {
        nextToken += 1
        registrations[nextToken] = audience.events.on(listener)
        return nextToken
    }
}

/// The JS timers and clock presence uses, backed by real time. `setTimeout` callbacks run on the
/// container's executor (`fire` hops back onto the owning `Container`), never on a detached task,
/// so presence stays synchronous (ARCHITECTURE.md section 2).
final class ContainerPresenceClock: PresenceClock {
    private var callbacks: [Int: () throws -> Void] = [:]
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var nextHandle = 0
    private let fire: @Sendable (Int) async -> Void

    /// `fire(handle)` must call `takeCallback(handle)` on the container's executor and run what it returns.
    init(fire: @escaping @Sendable (Int) async -> Void) {
        self.fire = fire
    }

    /// `Date.now()`.
    func now() -> Double { (Date().timeIntervalSince1970 * 1000).rounded(.down) }

    /// `Math.random()`.
    func random() -> Double { Double.random(in: 0..<1) }

    func setTimeout(_ callback: @escaping () throws -> Void, delay: Double) -> Int {
        nextHandle += 1
        let handle = nextHandle
        callbacks[handle] = callback
        let fire = fire
        // JS clamps a non-positive or NaN delay to 1 ms.
        let milliseconds = delay.isNaN ? 1 : max(1, delay)
        tasks[handle] = Task {
            do {
                try await Task.sleep(for: .milliseconds(milliseconds))
                await fire(handle)
            } catch {}
        }
        return handle
    }

    func clearTimeout(_ handle: Int) {
        callbacks[handle] = nil
        tasks.removeValue(forKey: handle)?.cancel()
    }

    /// The callback for a fired timer, or `nil` if it was cleared first. Removes the timer.
    func takeCallback(_ handle: Int) -> (() throws -> Void)? {
        tasks[handle] = nil
        return callbacks.removeValue(forKey: handle)
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        callbacks.removeAll()
    }
}

/// Ports the `ExtensionHost` that `ContainerRuntime.acquireExtensionInternal` builds
/// (containerRuntime.ts). Everything it reads is plain synchronous container state; signals go out
/// through `ContainerRuntime.submitExtensionSignal`.
final class ContainerExtensionHost: ExtensionHost {
    let clock: any PresenceClock
    /// `ILayerCompatDetails.supportedFeatures` of the runtime layer is empty in 3.11.0
    /// (runtimeLayerCompatState.ts `runtimeCompatDetailsForLoader`), so presence sees no
    /// `submit_signals_v2` even though the driver negotiates it.
    let supportedFeatures: Set<JSString> = []
    private let runtime: ContainerRuntime
    private let connectionManager: ConnectionManager
    private let audience: PresenceAudienceAdapter
    private var disconnectedListeners: [() throws -> Void] = []

    init(
        runtime: ContainerRuntime, connectionManager: ConnectionManager,
        audience: PresenceAudienceAdapter, clock: any PresenceClock
    ) {
        self.runtime = runtime
        self.connectionManager = connectionManager
        self.audience = audience
        self.clock = clock
    }

    /// containerRuntime.ts `getJoinedStatus`: a connection that has not yet seen its own join is
    /// `CatchingUp`, which can not send ops.
    func getJoinedStatus() -> JoinedStatus {
        if connectionManager.connected { return .joinedForWriting }
        return connectionManager.connection == nil ? .disconnected : .joinedForReading
    }

    func getClientId() -> ClientConnectionId? { connectionManager.clientId }

    func getQuorum() -> any IQuorumClients { runtime.getQuorum() }

    func getAudience() -> any IAudience { audience }

    func onDisconnected(_ listener: @escaping () throws -> Void) {
        disconnectedListeners.append(listener)
    }

    func submitAddressedSignal(_ addressChain: [JSString], message: JSONValue) throws {
        try runtime.submitExtensionSignal(id: presenceExtensionId, addressChain: addressChain, message: message)
    }

    /// The runtime's `disconnectedFromService` event, as presence's `events.on("disconnected")`.
    func raiseDisconnected() throws {
        for listener in disconnectedListeners { try listener() }
    }
}
