import FluidLZ4
import Foundation

/// `npm run lz4-check` helper: compresses every lz4js fixture input plus fresh random inputs with
/// FluidLZ4 and writes `[{ input, compressed }]` (base64) for Node to verify with lz4js.
/// Usage: FluidLZ4Check <fixtures/lz4.json> <output.json>
struct Fixture: Decodable { let compressed: String }
struct Result: Encodable { let input: String; let compressed: String }

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: FluidLZ4Check <fixture> <output>\n".utf8))
    exit(2)
}
let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
var inputs = try fixtures.map { try FluidLZ4.decompress(Array(Data(base64Encoded: $0.compressed)!)) }
for size in [1, 257, 8192, 70_000] {
    inputs.append((0..<size).map { _ in UInt8.random(in: .min ... .max) })
}
let results = try inputs.map {
    Result(input: Data($0).base64EncodedString(), compressed: Data(try FluidLZ4.compress($0)).base64EncodedString())
}
try JSONEncoder().encode(results).write(to: URL(fileURLWithPath: arguments[2]))
