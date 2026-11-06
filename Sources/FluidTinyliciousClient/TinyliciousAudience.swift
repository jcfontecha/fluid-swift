import FluidDriverDefinitions
import FluidJS

/// Ports tinylicious-client/src/TinyliciousAudience.ts `createTinyliciousAudienceMember`: the
/// audience member of a client whose user is a `TinyliciousUser` (string `id` and `name`).
public func createTinyliciousAudienceMember(_ audienceMember: IClient) throws -> TinyliciousMember {
    let user = audienceMember.user
    // TinyliciousAudience.ts assert 0x313; IClient already requires a string `id`.
    guard case .string(let name) = try user.json.asObject()["name"] else {
        throw JSONDecodingError(#"0x313: Specified user was not of type "TinyliciousUser"."#)
    }
    return TinyliciousMember(id: user.id.description, name: name.description, connections: [])
}
