import Testing
import FluidJS
@testable import FluidTree

@Suite struct SchemaIndexCodecTests {
    @Test func metadataOnlyInVersionTwo() throws {
        let input = try JSON.parse("{\"version\":2,\"nodes\":{\"O\":{\"kind\":{\"object\":{\"z\":{\"kind\":\"Optional\",\"types\":[\"N\",\"N\"],\"metadata\":{\"description\":\"field\"}},\"a\":{\"kind\":\"Forbidden\",\"types\":[]}}},\"metadata\":{\"description\":\"node\"}},\"N\":{\"kind\":{\"leaf\":0}}},\"root\":{\"kind\":\"Value\",\"types\":[\"O\"],\"metadata\":{\"description\":\"root\"}}}")
        let codec = SchemaCodec()
        let repo = try codec.decode(input)
        let v1 = try codec.encode(repo, version: 1)
        #expect(!JSON.stringify(v1).contains("metadata"))
        let v2 = try codec.encode(repo, version: 2)
        #expect(try codec.encode(codec.decode(v2), version: 2) == v2)
        let fields = try v2.member("nodes").member("O").member("kind").member("object").asObject()
        #expect(fields.keys == ["a", "z"])
        #expect(try fields["z"]?.member("types").asArray().count == 1)
    }
    @Test func numericAndPrototypeNames() throws {
        let repo = try TreeStoredSchema(json: JSON.parse("{\"nodes\":{\"10\":{\"leaf\":0},\"2\":{\"leaf\":1},\"__proto__\":{\"leaf\":2}},\"root\":{\"kind\":\"Sequence\",\"types\":[]}}"))
        let encoded = try SchemaCodec().encode(repo, version: 1)
        #expect(try encoded.member("nodes").asObject().keys == ["2", "10", "__proto__"])
        #expect(try SchemaCodec().encode(SchemaCodec().decode(encoded), version: 1) == encoded)
    }
    @Test func emptyRepositoriesBothVersions() throws {
        for version in [1, 2] {
            let input = try JSON.parse("{\"version\":\(version),\"nodes\":{},\"root\":{\"kind\":\"Forbidden\",\"types\":[]}}")
            #expect(try SchemaCodec().encode(SchemaCodec().decode(input), version: version) == input)
        }
    }
    @Test func malformedVersionsAndLeafTags() throws {
        for text in ["{\"version\":3,\"nodes\":{},\"root\":{\"kind\":\"Forbidden\",\"types\":[]}}", "{\"version\":1,\"nodes\":{\"N\":{\"leaf\":5}},\"root\":{\"kind\":\"Forbidden\",\"types\":[]}}"] {
            #expect(throws: (any Error).self) { try SchemaCodec().decode(JSON.parse(text)) }
        }
    }
}
