import FluidDriverDefinitions
import FluidJS

/// Ports azure-client/src/AzureAudience.ts `createAzureAudienceMember`: the audience member of a
/// client whose user is an `AzureUser` (`id`, `name` and optional `additionalDetails`).
///
/// AzureAudience.ts `assertIsAzureUser` also rejects a user without `id`; `IClient` cannot decode
/// one, so only the `name` check remains. TS declares `name` a string and copies it unchecked; a
/// non-string name fails decoding here.
public func createAzureAudienceMember(_ audienceMember: IClient) throws -> AzureMember {
    let user = audienceMember.user
    let fields = try user.json.asObject()
    guard let name = fields["name"] else {
        throw JSONDecodingError(#"Provided user data was not an "AzureUser". Missing required "name" property."#)
    }
    return AzureMember(
        id: user.id.description,
        name: try name.asString().description,
        additionalDetails: fields["additionalDetails"],
        connections: [])
}
