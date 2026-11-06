import FluidDriverDefinitions
import FluidJS

/// Ports odsp-client/src/odspAudience.ts `createOdspAudienceMember`. The TS `OdspUser` cast
/// reads `oid`, `name` and `email` from the join-session user payload unchecked: a field that is
/// present but not a string (`"email": null` for app-only or guest identities) is copied as nil.
public func createOdspAudienceMember(_ audienceMember: IClient) throws -> OdspMember {
    let user = try audienceMember.user.json.asObject()
    let string = { (value: JSONValue?) -> String? in
        if case .string(let text) = value { return text.description }
        return nil
    }
    // odspAudience.ts assert 0x836: Provided user was not an "OdspUser". It checks `!== undefined`,
    // so a present null counts.
    guard user["name"] != nil || user["email"] != nil || user["oid"] != nil else {
        throw JSONDecodingError("0x836: Provided user was not an \"OdspUser\".")
    }
    return OdspMember(id: string(user["oid"]), name: string(user["name"]), email: string(user["email"]), connections: [])
}
