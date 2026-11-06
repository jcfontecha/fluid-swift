import FluidRouterliciousDriver
import FluidStatic

/// Ports tinylicious-client/src/interfaces.ts `TinyliciousClientProps`. `logger` is not ported:
/// the Swift client has no telemetry logger.
public struct TinyliciousClientProps: Sendable {
    /// The service connection; nil uses `TinyliciousConnectionConfig`'s defaults.
    public let connection: TinyliciousConnectionConfig?

    public init(connection: TinyliciousConnectionConfig? = nil) {
        self.connection = connection
    }
}

/// Ports interfaces.ts `TinyliciousConnectionConfig`.
public struct TinyliciousConnectionConfig: Sendable {
    /// The service port; nil is tinylicious-driver's `defaultTinyliciousPort`, 7070.
    public let port: Int?
    /// The service domain. TinyliciousClient.ts hands this config to
    /// `InsecureTinyliciousUrlResolver`, which reads `endpoint`, not `domain`, so in 3.11 the
    /// domain has no effect and the endpoint is always `http://localhost`.
    public let domain: String?
    /// Issues the service's tokens; nil is `InsecureTinyliciousTokenProvider`, with document
    /// read, document write and summary write scopes.
    public let tokenProvider: (any ITokenProvider)?

    public init(port: Int? = nil, domain: String? = nil, tokenProvider: (any ITokenProvider)? = nil) {
        self.port = port
        self.domain = domain
        self.tokenProvider = tokenProvider
    }
}

/// Ports interfaces.ts `TinyliciousMember`.
public struct TinyliciousMember: IMember, Sendable {
    public let id: String
    public let name: String
    public var connections: [IConnection]

    public init(id: String, name: String, connections: [IConnection]) {
        self.id = id
        self.name = name
        self.connections = connections
    }
}

/// Ports interfaces.ts `ITinyliciousAudience`.
public typealias ITinyliciousAudience = ServiceAudience<TinyliciousMember>

/// Ports interfaces.ts `TinyliciousContainerServices`: the Tinylicious-specific services of one
/// container, on the container's owner.
public struct TinyliciousContainerServices {
    /// The users present in this session, and events for roster changes.
    public let audience: ITinyliciousAudience
}
