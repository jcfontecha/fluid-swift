import FluidDriverBase
import FluidDriverDefinitions
import FluidJS
import Foundation

/// Ports routerlicious-driver/src/documentDeltaConnection.ts: handshake construction.
public enum R11sDocumentDeltaConnection {
    public static func message(document: String, token: String, client: IClient) throws -> IConnect
    {
        var message = JSObject<JSONValue>()
        message["client"] = client.json
        message["id"] = .string(JSString(document))
        message["mode"] = client.mode.json
        message["tenantId"] = .string("tinylicious")
        message["token"] = .string(JSString(token))
        message["versions"] = .array(
            ["^0.4.0", "^0.3.0", "^0.2.0", "^0.1.0"].map { .string(JSString($0)) })
        let environment = client.details.environment?.description ?? ""
        message["relayUserAgent"] = .string(JSString(environment + "; driverVersion:3.11.0"))
        return try IConnect(json: .object(message))
    }
}
