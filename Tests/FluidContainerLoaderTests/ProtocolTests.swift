import FluidDriverDefinitions
import FluidJS
import FluidTinyliciousDriver
import Testing

@Test func tokenMatchesJSRSASignFixture() throws {
    let token = try InsecureTinyliciousTokenProvider().signedToken(
        tenant: "tinylicious", document: "doc", userID: "12345678-1234-4234-8234-123456789abc",
        now: 1_700_000_000)
    #expect(
        token
            == "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJkb2N1bWVudElkIjoiZG9jIiwic2NvcGVzIjpbImRvYzpyZWFkIiwiZG9jOndyaXRlIiwic3VtbWFyeTp3cml0ZSJdLCJ0ZW5hbnRJZCI6InRpbnlsaWNpb3VzIiwidXNlciI6eyJpZCI6IjEyMzQ1Njc4LTEyMzQtNDIzNC04MjM0LTEyMzQ1Njc4OWFiYyIsIm5hbWUiOiIxMjM0NTY3OC0xMjM0In0sImlhdCI6MTcwMDAwMDAwMCwiZXhwIjoxNzAwMDAzNjAwLCJ2ZXIiOiIxLjAifQ.XaQ1fPm2F73s_ICmPgXG2qznvxakL96dQP4TQLwq4Rs"
    )
}
@Test func resolverPreservesEndpointAndEncodesOnlyDocument() async throws {
    let resolver = try InsecureTinyliciousUrlResolver(endpoint: "http://localhost:7073/path")
    let resolved = try #require(try await resolver.resolve(IRequest(url: "http://localhost:7073/doc space/route?x=1")))
    #expect(try resolved.json.member("id") == .string("doc space"))
    #expect(
        try resolved.json.member("url")
            == .string("http://localhost:7073/tinylicious/doc%20space/route?x=1")
    )
    #expect(try await resolver.getAbsoluteUrl(resolved, relativeUrl: "child") == "doc space/route?x=1/child")
    var headers = JSObject<JSONValue>()
    headers["createNew"] = .bool(true)
    let created = try #require(try await resolver.resolve(IRequest(url: "", headers: headers)))
    #expect(try created.json.member("id") == .string("new"))
}
