import FluidJS
import Foundation

func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw JSONDecodingError(message) }
}

/// Exact 122-bit UUID arithmetic, ports utilities.ts (version and variant bits are removed).
public struct NumericUuid: Comparable, Equatable, Sendable {
  public let value: UInt128
  public init(value: UInt128) { self.value = value }
  public init(_ stable: String) throws {
    let chars = Array(stable.utf8)
    try require(chars.count == 36, "0x4a3")
    for i in chars.indices {
      let c = chars[i]
      if [8, 13, 18, 23].contains(i) {
        try require(c == 45, "0x4a3")
      } else if i == 14 {
        try require(c == 52, "0x4a3")
      } else if i == 19 {
        try require([56, 57, 97, 98].contains(c), "0x4a3")
      } else {
        try require(
          (48...57).contains(c) || (97...102).contains(c) || (65...70).contains(c), "0x4a3")
      }
    }
    guard let raw = UInt128(stable.replacingOccurrences(of: "-", with: ""), radix: 16) else {
      throw JSONDecodingError("0x4a3")
    }
    value =
      ((raw & (UInt128(0xffff_ffff_ffff) << 80)) >> 6)
      | ((raw & (UInt128(0xfff) << 64)) >> 2)
      | (raw & UInt128(0x3fff_ffff_ffff_ffff))
  }
  public var stableId: String {
    let raw =
      ((value & (UInt128(0xffff_ffff_ffff) << 74)) << 6)
      | ((value & (UInt128(0xfff) << 62)) << 2)
      | (value & UInt128(0x3fff_ffff_ffff_ffff))
      | (UInt128(4) << 76)
      | (UInt128(8) << 60)
    let hex = String(raw, radix: 16)
    let chars = Array((String(repeating: "0", count: max(0, 32 - hex.count)) + hex))
    return String(chars[0..<8]) + "-" + String(chars[8..<12]) + "-" + String(chars[12..<16]) + "-"
      + String(chars[16..<20]) + "-" + String(chars[20..<32])
  }
  public func offset(_ amount: Double) throws -> NumericUuid {
    guard let delta = UInt128(exactly: amount) else {
      throw JSONDecodingError("Invalid UUID offset")
    }
    let result = value.addingReportingOverflow(delta)
    try require(!result.overflow, "UUID arithmetic overflow")
    return NumericUuid(value: result.partialValue)
  }
  public static func < (a: Self, b: Self) -> Bool { a.value < b.value }
}
