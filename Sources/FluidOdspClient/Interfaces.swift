import FluidStatic

/// Ports odsp-client/src/interfaces.ts `OdspConnectionConfig`.
public struct OdspConnectionConfig: Sendable {
    public let tokenProvider: any IOdspTokenProvider
    public let siteUrl: String
    public let driveId: String
    public let filePath: String

    public init(tokenProvider: any IOdspTokenProvider, siteUrl: String, driveId: String, filePath: String) {
        self.tokenProvider = tokenProvider
        self.siteUrl = siteUrl
        self.driveId = driveId
        self.filePath = filePath
    }
}

/// Ports interfaces.ts `OdspClientProps`. `logger` and `configProvider` are not ported: the
/// Swift client has no telemetry logger or config-provider surface yet.
public struct OdspClientProps: Sendable {
    public let connection: OdspConnectionConfig

    public init(connection: OdspConnectionConfig) {
        self.connection = connection
    }
}

/// Ports interfaces.ts `IOdspContainerServicesEvents`.
public enum OdspContainerServicesEvent {
    case readOnlyStateChanged
    case sensitivityLabelsInfoChanged
}

/// Ports interfaces.ts `TokenResponse` (distinct from odsp-driver-definitions' TokenResponse).
public struct TokenResponse: Sendable {
    public let token: String
    public let fromCache: Bool?

    public init(token: String, fromCache: Bool? = nil) {
        self.token = token
        self.fromCache = fromCache
    }
}

/// Ports interfaces.ts `OdspMember`. TS declares the fields as strings but fills them from the
/// join-session user without checking each one (odspAudience.ts), so an absent field is nil.
public struct OdspMember: IMember, Sendable {
    public let id: String?
    public let name: String?
    public let email: String?
    public var connections: [IConnection]

    public init(id: String?, name: String?, email: String?, connections: [IConnection]) {
        self.id = id
        self.name = name
        self.email = email
        self.connections = connections
    }
}
