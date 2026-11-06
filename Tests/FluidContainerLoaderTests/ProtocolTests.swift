import Testing
import FluidJS
import FluidContainerLoader
import FluidTinyliciousDriver

private func snapshot() throws -> JSONValue {
    try JSON.parse(#"{"attributes":{"sequenceNumber":0,"minimumSequenceNumber":0},"quorumMembers":[],"quorumProposals":[],"quorumValues":[]}"#)
}
private func message(_ number: Int, msn: Int = 0, type: String, client: JSONValue = .null, csn: Int = 0, contents: JSONValue = .null, data: String = "") -> JSONValue {
    var object = JSObject<JSONValue>()
    object["sequenceNumber"] = .number(Double(number)); object["minimumSequenceNumber"] = .number(Double(msn)); object["type"] = .string(JSString(type)); object["clientId"] = client
    object["clientSequenceNumber"] = .number(Double(csn)); object["contents"] = contents; object["data"] = .string(JSString(data))
    return .object(object)
}
@Test func proposalCommitsAtMSNAndAudienceTracksQuorum() throws {
    var state = try ProtocolHandler(snapshot: snapshot())
    _ = try state.process(message(1, type: "join", data: #"{"clientId":"a","detail":{"mode":"write","user":{"id":"a"}}}"#))
    #expect(try state.view.member("audience").asArray().count == 1)
    #expect(try state.process(message(2, type: "propose", client: .string("a"), csn: 1, contents: .string(#"{"key":"code","value":{"package":"test"}}"#))))
    #expect(try state.view.member("proposals").asArray().count == 1)
    _ = try state.process(message(3, msn: 2, type: "accept", client: .string("a"), csn: 2))
    #expect(try state.view.member("proposals").asArray().isEmpty)
    let committed = try state.view.member("values").asArray()[0].asArray()[1]
    #expect(try committed.member("approvalSequenceNumber") == .number(3))
    #expect(try committed.member("commitSequenceNumber") == .number(-1))
    _ = try state.process(message(4, msn: 3, type: "leave", data: #""a""#))
    #expect(try state.view.member("members").asArray().isEmpty)
    #expect(try state.view.member("audience").asArray().isEmpty)
}
@Test func rejectsNonSequentialAndInvalidMSN() throws {
    var state = try ProtocolHandler(snapshot: snapshot())
    #expect(throws: JSONDecodingError.self) { _ = try state.process(message(2, type: "noop")) }
    #expect(throws: JSONDecodingError.self) { _ = try state.process(message(1, msn: 2, type: "noop")) }
}
@Test func tokenMatchesJSRSASignFixture() throws {
    let token = InsecureTinyliciousTokenProvider().signedToken(tenant: "tinylicious", document: "doc", userID: "12345678-1234-4234-8234-123456789abc", now: 1700000000)
    #expect(token == "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJkb2N1bWVudElkIjoiZG9jIiwic2NvcGVzIjpbImRvYzpyZWFkIiwiZG9jOndyaXRlIiwic3VtbWFyeTp3cml0ZSJdLCJ0ZW5hbnRJZCI6InRpbnlsaWNpb3VzIiwidXNlciI6eyJpZCI6IjEyMzQ1Njc4LTEyMzQtNDIzNC04MjM0LTEyMzQ1Njc4OWFiYyIsIm5hbWUiOiIxMjM0NTY3OC0xMjM0In0sImlhdCI6MTcwMDAwMDAwMCwiZXhwIjoxNzAwMDAzNjAwLCJ2ZXIiOiIxLjAifQ.XaQ1fPm2F73s_ICmPgXG2qznvxakL96dQP4TQLwq4Rs")
}
@Test func resolverPreservesEndpointAndEncodesOnlyDocument() throws {
    let resolver = try InsecureTinyliciousURLResolver(endpoint: "http://localhost:7073/path")
    let resolved = try resolver.resolve("http://localhost:7073/doc space/route?x=1")
    #expect(try resolved.member("id") == .string("doc space"))
    #expect(try resolved.member("url") == .string("http://localhost:7073/tinylicious/doc%20space/route?x=1"))
    #expect(try resolver.getAbsoluteURL(resolved, relative: "child") == "doc space/route?x=1/child")
    let created = try resolver.resolve("", createNew: true)
    #expect(try created.member("id") == .string("new"))
}
