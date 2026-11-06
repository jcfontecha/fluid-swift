import FluidDriverDefinitions
import FluidJS
import Testing

@testable import FluidAzureClient

struct AzureAudienceTests {
    private func client(user: String) throws -> IClient {
        try IClient(json: JSON.parse(
            #"{"mode":"write","details":{"capabilities":{"interactive":true}},"permission":[],"scopes":[],"user":"# + user + "}"))
    }

    /// AzureAudience.ts: id and name from the user, additionalDetails as given, connections empty.
    @Test func mapsAzureUserToMember() throws {
        let member = try createAzureAudienceMember(client(
            user: #"{"id":"user-id","name":"Ada","additionalDetails":{"role":"editor","level":2}}"#))
        #expect(member.id == "user-id")
        #expect(member.name == "Ada")
        #expect(member.additionalDetails.map(JSON.stringify) == #"{"role":"editor","level":2}"#)
        #expect(member.connections.isEmpty)
    }

    @Test func additionalDetailsAreOptional() throws {
        let member = try createAzureAudienceMember(client(user: #"{"id":"user-id","name":"Ada"}"#))
        #expect(member.additionalDetails == nil)
    }

    /// assertIsAzureUser's TypeError message.
    @Test func rejectsUserWithoutName() throws {
        do {
            _ = try createAzureAudienceMember(client(user: #"{"id":"user-id"}"#))
            Issue.record("accepted a user without a name")
        } catch {
            #expect(String(describing: error) == #"Provided user data was not an "AzureUser". Missing required "name" property."#)
        }
    }
}
