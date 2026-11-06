import FluidDriverDefinitions
import FluidJS
import Testing

@testable import FluidTinyliciousClient

struct TinyliciousAudienceTests {
    private func client(user: String) throws -> IClient {
        try IClient(json: JSON.parse(
            #"{"mode":"write","details":{"capabilities":{"interactive":true}},"permission":[],"scopes":[],"user":"# + user + "}"))
    }

    /// TinyliciousAudience.ts: id and name from the user; connections start empty.
    @Test func mapsTinyliciousUserToMember() throws {
        let member = try createTinyliciousAudienceMember(client(user: #"{"id":"user-id","name":"Ada","extra":1}"#))
        #expect(member.id == "user-id")
        #expect(member.name == "Ada")
        #expect(member.connections.isEmpty)
    }

    /// Assert 0x313 needs `name` to be a string.
    @Test(arguments: [#"{"id":"user-id"}"#, #"{"id":"user-id","name":3}"#])
    func rejectsUserWithoutStringName(_ user: String) throws {
        do {
            _ = try createTinyliciousAudienceMember(client(user: user))
            Issue.record("accepted \(user)")
        } catch {
            #expect(String(describing: error) == #"0x313: Specified user was not of type "TinyliciousUser"."#)
        }
    }
}
