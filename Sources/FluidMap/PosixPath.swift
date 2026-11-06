import FluidJS

/// node `path.posix`, as SharedDirectory uses it (`posix.sep`, `join`, `resolve`). Paths are UTF-16
/// code units like every JS string, so lone surrogates in names survive.
enum PosixPath {
  static let sep: JSString = "/"
  private static let slash: UInt16 = 0x2F
  private static let dot: ContiguousArray<UInt16> = [0x2E]
  private static let dotDot: ContiguousArray<UInt16> = [0x2E, 0x2E]

  /// `path.posix.join`: joins the non-empty arguments with `/`, then normalizes.
  static func join(_ parts: JSString...) -> JSString {
    let nonEmpty = parts.filter { $0.length > 0 }
    if nonEmpty.isEmpty {
      return "."
    }
    var joined = ContiguousArray<UInt16>()
    for (index, part) in nonEmpty.enumerated() {
      if index > 0 {
        joined.append(slash)
      }
      joined.append(contentsOf: part.utf16)
    }
    return normalize(JSString(utf16: joined))
  }

  /// `path.posix.resolve(from, to)` where `from` is absolute: the result is absolute, normalized and
  /// has no trailing separator.
  static func resolve(_ from: JSString, _ to: JSString) -> JSString {
    let combined: ContiguousArray<UInt16>
    if to.utf16.first == slash {
      combined = to.utf16
    } else {
      combined = from.utf16 + [slash] + to.utf16
    }
    let segments = normalizeSegments(combined, absolute: true)
    return JSString(utf16: [slash] + joinSegments(segments))
  }

  /// `path.posix.normalize`.
  private static func normalize(_ path: JSString) -> JSString {
    let absolute = path.utf16.first == slash
    let trailingSeparator = path.utf16.last == slash
    var result = joinSegments(normalizeSegments(path.utf16, absolute: absolute))
    if result.isEmpty && !absolute {
      result = dot
    }
    if !result.isEmpty && trailingSeparator {
      result.append(slash)
    }
    if absolute {
      result.insert(slash, at: 0)
    }
    return JSString(utf16: result)
  }

  /// Drops empty and `.` segments; `..` removes the previous segment, or is kept at the start of a
  /// relative path.
  private static func normalizeSegments(
    _ path: ContiguousArray<UInt16>, absolute: Bool
  ) -> [ArraySlice<UInt16>] {
    var segments: [ArraySlice<UInt16>] = []
    for segment in path.split(separator: slash, omittingEmptySubsequences: true) {
      if segment.elementsEqual(dot) {
        continue
      }
      if segment.elementsEqual(dotDot) {
        if let last = segments.last, !last.elementsEqual(dotDot) {
          segments.removeLast()
        } else if !absolute {
          segments.append(segment)
        }
        continue
      }
      segments.append(segment)
    }
    return segments
  }

  private static func joinSegments(_ segments: [ArraySlice<UInt16>]) -> ContiguousArray<UInt16> {
    var result = ContiguousArray<UInt16>()
    for (index, segment) in segments.enumerated() {
      if index > 0 {
        result.append(slash)
      }
      result.append(contentsOf: segment)
    }
    return result
  }
}
