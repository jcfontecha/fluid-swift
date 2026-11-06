import Foundation
import Testing
import FluidJS
@testable import FluidSocketIO

@Test func oraclePackets() throws {
    let url = Bundle.module.url(forResource: "packets", withExtension: "json", subdirectory: "Fixtures")!
    let fixtures = try JSON.parse(String(contentsOf: url, encoding: .utf8)).asArray()
    for fixture in fixtures {
        let frame = try fixture.asString().description
        #expect(try EnginePacket.decode(frame).encode() == frame)
    }
}

@Test func invalidPackets() {
    for frame in ["", "9", "45-[]", "42/admin,[\"op\"]", "42[]", "43[]", "41{}", "44null", "42-1[\"x\"]"] {
        #expect(throws: (any Error).self) { try EnginePacket.decode(frame) }
    }
}

@Test func driverOptions() throws {
    let url = try SocketIOOptions(query: ["tenantId": "a b&c", "documentId": "x/💧"], path: "/custom")
        .websocketURL(URL(string: "https://localhost:7172")!)
    let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    #expect(parts.scheme == "wss")
    #expect(parts.path == "/custom/")
    let query = Dictionary(uniqueKeysWithValues: parts.queryItems!.map { ($0.name, $0.value!) })
    #expect(query == ["tenantId": "a b&c", "documentId": "x/💧", "EIO": "4", "transport": "websocket"])
    #expect(throws: (any Error).self) {
        try SocketIOOptions().websocketURL(URL(string: "ftp://localhost")!)
    }
}

@Test func packetSemantics() throws {
    let event = try EnginePacket.decode(#"420["ping"]"#)
    #expect(event == .message(SocketPacket(.event, id: 0, data: .array([.string("ping")]))))
    #expect(try EnginePacket.decode("1") == .close)
    #expect(try EnginePacket.decode("2probe") == .ping("probe"))
    #expect(try EnginePacket.decode("3probe") == .pong("probe"))
    let packet = try SocketPacket.decode(#"2["op",{"contents":"\ud800","sequenceNumber":1}]"#)
    let arguments = try packet.data!.asArray()
    #expect(try arguments[1].member("contents").asString().utf16 == [0xd800])
    #expect(try SocketPacket(.event, id: 42, data: .array([.string("x"), .number(1e21)])).encode() == #"242["x",1e+21]"#)
}
