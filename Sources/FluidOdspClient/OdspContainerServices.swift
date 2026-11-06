import FluidContainerDefinitions
import FluidStatic

/// Ports odsp-client/src/odspContainerServices.ts: the ODSP-specific services of one container,
/// on the container's owner.
public final class OdspContainerServices {
    private let container: any IContainer
    private var containerListener: Int?
    public let audience: ServiceAudience<OdspMember>
    public let events = ListenerList<OdspContainerServicesEvent>()
    public private(set) var disposed = false

    /// odspContainerServices.ts constructor: `readonly` becomes `readOnlyStateChanged`, and a
    /// `metadataUpdate` carrying `sensitivityLabelsInfo` becomes `sensitivityLabelsInfoChanged`.
    init(container: any IContainer) throws {
        self.container = container
        audience = try createServiceAudience(container: container, createServiceMember: createOdspAudienceMember)
        containerListener = container.events.on { [events] event in
            switch event {
            case .readonly:
                events.emit(.readOnlyStateChanged)
            case .metadataUpdate(let metadata):
                if metadata["sensitivityLabelsInfo"] != nil {
                    events.emit(.sensitivityLabelsInfoChanged)
                }
            default:
                break
            }
        }
    }

    public func dispose() {
        if disposed {
            return
        }
        disposed = true
        if let containerListener {
            container.events.off(containerListener)
            self.containerListener = nil
        }
    }

    public func getReadOnlyState() -> Bool? {
        container.readOnlyInfo.readonly
    }

    public func getSensitivityLabelsInfo() -> String? {
        container.containerMetadata["sensitivityLabelsInfo"]?.description
    }
}
