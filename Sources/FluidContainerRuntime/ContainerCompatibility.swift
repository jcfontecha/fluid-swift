import FluidJS

private func parseCompatibilityVersion(_ version: String) throws -> [Int] {
  try require(version.utf16.count <= 256, "invalid semver")
  // npm semver accepts String.trim() whitespace and a lowercase v prefix, but the Fluid
  // validator additionally rejects build metadata (compatibilityBase.ts parsed.build).
  func whitespace(_ unit: UInt16) -> Bool {
    (9...13).contains(unit) || unit == 32 || unit == 160 || unit == 5760
      || (8192...8202).contains(unit) || unit == 8232 || unit == 8233
      || unit == 8239 || unit == 8287 || unit == 12288 || unit == 65279
  }
  var units = ArraySlice(version.utf16)
  while let unit = units.first, whitespace(unit) { units.removeFirst() }
  while let unit = units.last, whitespace(unit) { units.removeLast() }
  if units.first == 118 { units.removeFirst() }
  let parts = String(decoding: units, as: UTF16.self).split(separator: ".", omittingEmptySubsequences: false)
  try require(parts.count == 3, "invalid semver")
  return try parts.map { part -> Int in
    try require(!part.isEmpty && (part.count == 1 || part.first != "0") && part.allSatisfy { $0.isASCII && $0.isNumber }, "invalid semver")
    guard let value = Int(part), value <= 9_007_199_254_740_991 else { throw JSONDecodingError("invalid semver") }
    return value
  }
}

/// Ports runtime-utils/compatibilityBase.ts active collaborator version validation.
public func validateMinimumVersionForCollab(_ version: String) throws {
  let values = try parseCompatibilityVersion(version)
  try require(values[0] >= 2 && (values[0] < 3 || (values[0] == 3 && values[1] <= 11 && values[2] == 0)), "invalid OldestSupportedClientVersion")
}

/// Ports containerCompatibility.ts. All currently supported floors share the same defaults.
public func getMinVersionForCollabDefaults(_ version: String) throws -> JSONValue {
  try validateMinimumVersionForCollab(version)
  return object([("enableGroupedBatching", .bool(true)), ("compressionOptions", object([("minimumBatchSizeInBytes", number(614400)), ("compressionAlgorithm", string("lz4"))])), ("explicitSchemaControl", .bool(true)), ("flushMode", number(1)), ("gcOptions", object([]))])
}

/// Ports the createBlobPayloadPending compatibility gate in containerCompatibility.ts.
public func validateRuntimeOptions(_ version: String, options: JSONValue) throws {
  try validateMinimumVersionForCollab(version)
  if try field(options, "createBlobPayloadPending") == .bool(true) {
    let parts = try parseCompatibilityVersion(version)
    try require(parts[0] > 2 || parts[1] >= 40, "createBlobPayloadPending requires 2.40.0")
  }
}
