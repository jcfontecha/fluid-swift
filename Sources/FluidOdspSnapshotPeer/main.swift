import FluidJS
import FluidOdspDriver
import Foundation

// Newline-delimited `{method, params}` requests from harness/src/odsp-snapshot/peer.ts; one
// `{ok}` / `{err}` outcome per line. A codec error is an outcome; anything else is a protocol bug
// and exits nonzero.

func handle(_ method: String, _ params: JSONValue) throws -> JSONValue {
    switch method {
    case "writeSnapshot":
        let bytes = try convertToCompactSnapshot(decodeSnapshot(params))
        return ok(.string(toHex(bytes)))
    case "parseSnapshot":
        let result = try parseCompactSnapshotResponse(fromHex(params.asString()))
        return ok(try canonicalParse(result))
    case "writeTree":
        let builder = TreeBuilderSerializer()
        try fillNode(builder, params.asArray())
        return ok(.string(toHex(try builder.serialize())))
    case "parseTree":
        let builder = try TreeBuilder.load(ReadBuffer(fromHex(params.asString()))).builder
        return ok(.array(builder.children.map(dump)))
    default:
        throw JSONDecodingError("unknown method \(method)")
    }
}

while let line = readLine() {
    do {
        let request = try JSON.parse(line)
        let method = try request.member("method").asString().description
        let outcome: JSONValue
        do {
            outcome = try handle(method, request.member("params"))
        } catch let error as OdspSnapshotError {
            outcome = err(error)
        }
        FileHandle.standardOutput.write(Data((JSON.stringify(outcome) + "\n").utf8))
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}
