import FluidDriverBase
import FluidDriverDefinitions
import FluidJS
import Foundation

/// Ports routerlicious-driver/src/documentDeltaConnection.ts. The TS class subclasses driver-base's
/// DocumentDeltaConnection only to build the connect message and map service errors, which
/// DriverError already does, so `create` returns a driver-base connection.
public enum R11sDocumentDeltaConnection {
    /// documentDeltaConnection.ts: socket.io's connect timeout.
    public static let timeoutMs = 20000

    /// The connect_document payload, before driver-base adds `supportedFeatures`.
    public static func connectMessage(tenantId: String, id: String, token: String?, client: IClient) throws -> IConnect {
        var message = JSObject<JSONValue>()
        message["client"] = client.json
        message["id"] = .string(JSString(id))
        message["mode"] = client.mode.json
        message["tenantId"] = .string(JSString(tenantId))
        message["token"] = token.map { .string(JSString($0)) } ?? .null
        message["versions"] = .array(["^0.4.0", "^0.3.0", "^0.2.0", "^0.1.0"].map { .string(JSString($0)) })
        let environment = client.details.environment?.description ?? ""
        message["relayUserAgent"] = .string(JSString(environment + "; driverVersion:3.11.0"))
        return try IConnect(json: .object(message))
    }

    public static func create(
        tenantId: String, id: String, token: String?, client: IClient, url: String
    ) async throws -> DocumentDeltaConnection {
        guard let endpoint = URL(string: url) else { throw JSONDecodingError("invalid delta stream URL") }
        let connection = DocumentDeltaConnection()
        try await connection.initialize(
            url: endpoint,
            connectMessage: connectMessage(tenantId: tenantId, id: id, token: token, client: client),
            timeoutMs: timeoutMs)
        return connection
    }
}
