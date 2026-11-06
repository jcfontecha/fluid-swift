import FluidJS
import Testing

@testable import Fluid

private struct Nested: Codable, Equatable {
    var title: String
    var count: Int
    var ratio: Double
    var tags: [String]
    var note: String?
    var child: Child?

    struct Child: Codable, Equatable {
        var flag: Bool
    }
}

private enum Status: String, Codable {
    case open
    case done
}

struct JSONValueCodingTests {
    @Test func roundTripsNestedValues() throws {
        let value = Nested(title: "a", count: 2, ratio: 0.5, tags: ["x", "y"], note: nil, child: .init(flag: true))
        let json = try JSONValueCoding.encode(value)
        #expect(JSON.stringify(json) == #"{"title":"a","count":2,"ratio":0.5,"tags":["x","y"],"child":{"flag":true}}"#)
        #expect(try JSONValueCoding.decode(Nested.self, from: json) == value)
    }

    @Test func encodesPrimitivesAsJSValues() throws {
        #expect(try JSONValueCoding.encode(42) == .number(42))
        #expect(try JSONValueCoding.encode("hi") == .string("hi"))
        #expect(try JSONValueCoding.encode(Status.done) == .string("done"))
        #expect(try JSONValueCoding.encode([1, 2]) == .array([.number(1), .number(2)]))
        #expect(try JSONValueCoding.encode(["k": true]) == .object({ var o = JSObject<JSONValue>(); o["k"] = .bool(true); return o }()))
        #expect(try JSONValueCoding.encode(Int?.none) == .null)
    }

    /// Integers must be exact JS numbers: at most 2^53 in magnitude.
    @Test func rejectsIntegersBeyondTwoToThe53() throws {
        #expect(try JSONValueCoding.encode(Int64(1) << 53) == .number(9_007_199_254_740_992))
        #expect(throws: EncodingError.self) { try JSONValueCoding.encode((Int64(1) << 53) + 1) }
        #expect(throws: EncodingError.self) { try JSONValueCoding.encode(Double.nan) }
    }

    @Test func decodingChecksTypes() throws {
        #expect(throws: DecodingError.self) { try JSONValueCoding.decode(Int.self, from: .number(1.5)) }
        #expect(throws: DecodingError.self) { try JSONValueCoding.decode(String.self, from: .number(1)) }
        #expect(throws: DecodingError.self) { try JSONValueCoding.decode(Nested.Child.self, from: .object(JSObject())) }
        #expect(try JSONValueCoding.decode(Int.self, from: .number(3)) == 3)
        #expect(try JSONValueCoding.decode(Status.self, from: .string("open")) == .open)
    }
}
