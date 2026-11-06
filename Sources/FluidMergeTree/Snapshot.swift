import FluidJS

extension Client {
  public func snapshot(version: JSString, catchup: [JSONValue] = []) throws -> JSONValue {
    switch version {
    case "legacy": return try SnapshotLegacy(client: self).emit(catchup: catchup)
    case "v1":
      guard catchup.isEmpty else {
        throw JSONDecodingError("V1 does not support catchup operations")
      }
      return try SnapshotV1(client: self).emit()
    default: throw JSONDecodingError("unsupported snapshot version")
    }
  }
}
