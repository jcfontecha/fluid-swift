import CryptoKit
import FluidLZ4
import Foundation
import Testing

/// Golden frames produced by lz4js (`npm run lz4-fixtures` in harness/).
struct FluidLZ4Tests {
    struct Fixture: Decodable {
        let name: String
        let input: String?
        let inputLength: Int
        let inputSHA256: String
        let compressed: String
    }

    let fixtures: [Fixture]

    init() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("harness/fixtures/lz4.json")
        fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
    }

    private func sha256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    @Test func decompressesLz4jsFramesAndRoundTrips() throws {
        #expect(!fixtures.isEmpty)
        for fixture in fixtures {
            let decompressed = try FluidLZ4.decompress(Array(try #require(Data(base64Encoded: fixture.compressed))))
            #expect(decompressed.count == fixture.inputLength, "\(fixture.name)")
            #expect(sha256(decompressed) == fixture.inputSHA256, "\(fixture.name)")
            if let input = fixture.input {
                #expect(decompressed == Array(try #require(Data(base64Encoded: input))), "\(fixture.name)")
            }
            #expect(try FluidLZ4.decompress(FluidLZ4.compress(decompressed)) == decompressed, "\(fixture.name)")
        }
    }

    @Test func malformedFramesThrow() throws {
        #expect(throws: FluidLZ4.Error.self) { try FluidLZ4.decompress([]) }
        #expect(throws: FluidLZ4.Error.self) { try FluidLZ4.decompress([1, 2, 3]) }
        let frame = try FluidLZ4.compress(Array("fluid".utf8))
        #expect(throws: FluidLZ4.Error.self) { try FluidLZ4.decompress(Array(frame.dropLast())) }
        #expect(throws: FluidLZ4.Error.self) { try FluidLZ4.decompress(frame + [0]) }
    }
}
