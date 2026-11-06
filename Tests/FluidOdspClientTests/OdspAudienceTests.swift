import Testing
import FluidJS
import FluidDriverDefinitions
import FluidStatic
@testable import FluidOdspClient

struct OdspAudienceTests {
    private func client(user: String) throws -> IClient {
        try IClient(json: JSON.parse(
            #"{"mode":"write","details":{"capabilities":{"interactive":true}},"permission":[],"scopes":[],"user":"# + user + "}"))
    }

    /// odspAudience.ts: id comes from `oid`, not the protocol user `id`; connections start empty.
    @Test func mapsJoinSessionUserToMember() throws {
        let member = try createOdspAudienceMember(client(
            user: #"{"id":"protocol-id","oid":"object-id","name":"Ada","email":"ada@example.com"}"#))
        #expect(member.id == "object-id")
        #expect(member.name == "Ada")
        #expect(member.email == "ada@example.com")
        #expect(member.connections.isEmpty)
    }

    /// The 0x836 assert passes when any one of the three fields is present; the others stay
    /// undefined, as the unchecked TS cast leaves them.
    @Test func acceptsUserWithOnlyName() throws {
        let member = try createOdspAudienceMember(client(user: #"{"id":"protocol-id","name":"Ada"}"#))
        #expect(member.id == nil)
        #expect(member.name == "Ada")
        #expect(member.email == nil)
    }

    /// odspAudience.ts copies the fields through an unchecked cast; 0x836 only needs one of them
    /// to be `!== undefined`, so a null email (app-only or guest identities) is present.
    @Test func nullEmailIsCopiedNotRejected() throws {
        let member = try createOdspAudienceMember(client(user: #"{"id":"protocol-id","oid":"object-id","name":"Ada","email":null}"#))
        #expect(member.id == "object-id")
        #expect(member.name == "Ada")
        #expect(member.email == nil)
        let onlyNull = try createOdspAudienceMember(client(user: #"{"id":"protocol-id","email":null}"#))
        #expect(onlyNull.id == nil)
        #expect(onlyNull.name == nil)
        #expect(onlyNull.email == nil)
    }

    @Test func rejectsUserWithoutOdspFields() throws {
        #expect(throws: (any Error).self) {
            try createOdspAudienceMember(client(user: #"{"id":"protocol-id"}"#))
        }
        do {
            _ = try createOdspAudienceMember(client(user: #"{"id":"protocol-id"}"#))
        } catch {
            #expect(String(describing: error) == #"0x836: Provided user was not an "OdspUser"."#)
        }
    }
}

struct OdspTokenProviderTests {
    private struct StaticTokenProvider: IOdspTokenProvider {
        func fetchWebsocketToken(siteUrl: String, refresh: Bool) async throws -> TokenResponse {
            TokenResponse(token: "socket:" + siteUrl, fromCache: !refresh)
        }

        func fetchStorageToken(siteUrl: String, refresh: Bool) async throws -> TokenResponse {
            TokenResponse(token: "storage:" + siteUrl)
        }
    }

    @Test func connectionConfigCarriesTheProvider() async throws {
        let config = OdspConnectionConfig(
            tokenProvider: StaticTokenProvider(), siteUrl: "https://contoso.sharepoint.com",
            driveId: "drive", filePath: "folder")
        let props = OdspClientProps(connection: config)
        let socket = try await props.connection.tokenProvider.fetchWebsocketToken(siteUrl: config.siteUrl, refresh: true)
        #expect(socket.token == "socket:https://contoso.sharepoint.com")
        #expect(socket.fromCache == false)
        let storage = try await props.connection.tokenProvider.fetchStorageToken(siteUrl: config.siteUrl, refresh: false)
        #expect(storage.fromCache == nil)
    }
}
