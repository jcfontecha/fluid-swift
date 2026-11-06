import FluidContainerDefinitions
import FluidJS
import FluidRouterliciousDriver
import FluidStatic

/// Ports azure-client/src/interfaces.ts `AzureConnectionConfigType`.
public enum AzureConnectionConfigType: String, Sendable {
    case local
    case remote
}

/// Ports interfaces.ts `AzureRemoteConnectionConfig`: a connection to the Azure Fluid Relay
/// service.
public struct AzureRemoteConnectionConfig: Sendable {
    /// URI to the Azure Fluid Relay service discovery endpoint.
    public let endpoint: String
    /// Provides Azure Fluid Relay endpoint tokens.
    public let tokenProvider: any ITokenProvider
    /// Unique tenant identifier.
    public let tenantId: String

    public init(endpoint: String, tokenProvider: any ITokenProvider, tenantId: String) {
        self.endpoint = endpoint
        self.tokenProvider = tokenProvider
        self.tenantId = tenantId
    }
}

/// Ports interfaces.ts `AzureLocalConnectionConfig`: a connection to a local Fluid relay
/// (tinylicious).
public struct AzureLocalConnectionConfig: Sendable {
    /// URI to the local service endpoint.
    public let endpoint: String
    /// Provides the service's endpoint tokens.
    public let tokenProvider: any ITokenProvider

    public init(endpoint: String, tokenProvider: any ITokenProvider) {
        self.endpoint = endpoint
        self.tokenProvider = tokenProvider
    }
}

/// Ports interfaces.ts `AzureConnectionConfig` as TS uses it: the
/// `AzureRemoteConnectionConfig | AzureLocalConnectionConfig` union, discriminated by `type`.
/// The cases take the place of utils.ts `isAzureRemoteConnectionConfig` and
/// `isAzureLocalConnectionConfig`.
public enum AzureConnectionConfig: Sendable {
    case remote(AzureRemoteConnectionConfig)
    case local(AzureLocalConnectionConfig)

    public var type: AzureConnectionConfigType {
        switch self {
        case .remote:
            .remote
        case .local:
            .local
        }
    }

    public var endpoint: String {
        switch self {
        case .remote(let config):
            config.endpoint
        case .local(let config):
            config.endpoint
        }
    }

    public var tokenProvider: any ITokenProvider {
        switch self {
        case .remote(let config):
            config.tokenProvider
        case .local(let config):
            config.tokenProvider
        }
    }
}

/// Ports interfaces.ts `AzureClientProps`. `logger` and `summaryCompression` are not ported: the
/// Swift client has no telemetry logger, and driver-utils `applyStorageCompression` is not
/// ported (TS leaves the factory unchanged when `summaryCompression` is unset).
public struct AzureClientProps: Sendable {
    /// Configuration for establishing a connection with the Azure Fluid Relay.
    public let connection: AzureConnectionConfig
    /// Feature gates for experimental features, under the client's defaults.
    public let configProvider: (any IConfigProviderBase)?

    public init(connection: AzureConnectionConfig, configProvider: (any IConfigProviderBase)? = nil) {
        self.connection = connection
        self.configProvider = configProvider
    }
}

/// Ports interfaces.ts `AzureContainerVersion`.
public struct AzureContainerVersion: Sendable, Equatable {
    public let id: String
    /// When the version was generated, ISO 8601 (YYYY-MM-DDTHH:MM:SSZ).
    public let date: String?

    public init(id: String, date: String?) {
        self.id = id
        self.date = date
    }
}

/// Ports interfaces.ts `AzureGetVersionsOptions`.
public struct AzureGetVersionsOptions: Sendable {
    public let maxCount: Int

    public init(maxCount: Int) {
        self.maxCount = maxCount
    }
}

/// Ports interfaces.ts `AzureMember`: an audience member with the name Azure gives every user.
/// `additionalDetails` is the user's custom, app-specific JSON.
public struct AzureMember: IMember {
    public let id: String
    public let name: String
    public let additionalDetails: JSONValue?
    public var connections: [IConnection]

    public init(id: String, name: String, additionalDetails: JSONValue?, connections: [IConnection]) {
        self.id = id
        self.name = name
        self.additionalDetails = additionalDetails
        self.connections = connections
    }
}

/// Ports interfaces.ts `IAzureAudience`.
public typealias IAzureAudience = ServiceAudience<AzureMember>

/// Ports interfaces.ts `AzureContainerServices`: the Azure-specific services of one container,
/// on the container's owner.
public struct AzureContainerServices {
    /// The users present in this session, and events for roster changes.
    public let audience: IAzureAudience
}
