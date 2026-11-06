internal import FluidContainerDefinitions
internal import FluidStatic
import Observation

/// Where a container stands with its service.
public enum ContainerStatus {
    /// Establishing the connection, or catching up on ops after it.
    case connecting
    case connected
    case disconnected
    /// Closed for good, by the service or by an error. Edits made from now on are dropped.
    case closed((any Error)?)
}

/// A loaded container and its typed initial objects. It belongs to the actor that loaded it, and
/// it closes when its last reference goes away.
public final class FluidContainer<Schema: ContainerSchema>: Observable {
    public let initialObjects: Schema
    private let port: FluidStatic.FluidContainer
    private let registrar = ObservationRegistrar()
    /// The error the container closed with, which only its `disposed` event carries.
    private var closeError: (any Error)?

    /// Resolves the schema over the port container. On a mismatch the port container is closed,
    /// since nothing else will ever hold it.
    init(port: FluidStatic.FluidContainer) throws(FluidError) {
        do {
            initialObjects = try InitialObjects.resolve(Schema.self, from: port.initialObjects)
        } catch {
            port.dispose()
            throw error
        }
        self.port = port
        port.events.on { [weak self] event in
            self?.receive(event)
        }
    }

    deinit {
        port.dispose()
    }

    public var status: ContainerStatus {
        registrar.access(self, keyPath: \.status)
        if port.disposed {
            return .closed(closeError)
        }
        switch port.connectionState {
        case .establishingConnection, .catchingUp:
            return .connecting
        case .connected:
            return .connected
        case .disconnected:
            return .disconnected
        }
    }

    /// Some local edits have not been acknowledged by the service yet.
    public var isDirty: Bool {
        registrar.access(self, keyPath: \.isDirty)
        return port.isDirty
    }

    private func receive(_ event: FluidContainerEvent) {
        switch event {
        case .connected, .disconnected:
            registrar.withMutation(of: self, keyPath: \.status) {}
        case .disposed(let error):
            registrar.withMutation(of: self, keyPath: \.status) {
                closeError = error
            }
        case .saved, .dirty:
            registrar.withMutation(of: self, keyPath: \.isDirty) {}
        }
    }
}
