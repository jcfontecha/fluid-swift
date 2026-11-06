import FluidDriverDefinitions
import FluidJS

/// Ports odsp-client/src/odspAudience.ts `createOdspAudienceMember`. The TS `OdspUser` cast
/// reads `oid`, `name` and `email` from the join-session user payload.
public func createOdspAudienceMember(_ audienceMember: IClient) throws -> OdspMember {
    let user = try audienceMember.user.json.asObject()
    let oid = try user["oid"].map { try $0.asString().description }
    let name = try user["name"].map { try $0.asString().description }
    let email = try user["email"].map { try $0.asString().description }
    // odspAudience.ts assert 0x836: Provided user was not an "OdspUser".
    guard name != nil || email != nil || oid != nil else {
        throw JSONDecodingError("0x836: Provided user was not an \"OdspUser\".")
    }
    return OdspMember(id: oid, name: name, email: email, connections: [])
}
