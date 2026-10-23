// VectorValue.swift
// pgvector text values -> dimension, L2 norm, min, max and the leading values. `vector` and
// `halfvec` print as `[1,2,3]`; `sparsevec` as `{1:0.5,3:2}/5`, its 1-based indices strictly
// increasing and the dimension after the slash. The text is untrusted: anything else
// (non-numeric, non-finite, an index out of range or out of order, more than
// `maxDimensions`) is nil.

import Foundation

nonisolated struct VectorValue: Equatable, Sendable {
  static let maxDimensions = 100_000
  /// Leading values kept for display; a sparse value expands only these positions.
  static let previewCount = 64

  let dimension: Int
  let norm: Double
  let minimum: Double
  let maximum: Double
  /// The first `previewCount` values (fewer for a shorter vector), zeros included.
  let leadingValues: [Double]
  /// Stored entries of a `sparsevec`; nil for a dense value.
  let nonZeroCount: Int?

  init?(text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("[") {
      guard let value = Self.dense(trimmed) else { return nil }
      self = value
    } else if trimmed.hasPrefix("{") {
      guard let value = Self.sparse(trimmed) else { return nil }
      self = value
    } else {
      return nil
    }
  }

  private init(
    dimension: Int, norm: Double, minimum: Double, maximum: Double, leadingValues: [Double],
    nonZeroCount: Int?
  ) {
    self.dimension = dimension
    self.norm = norm
    self.minimum = minimum
    self.maximum = maximum
    self.leadingValues = leadingValues
    self.nonZeroCount = nonZeroCount
  }

  /// `[v,v,...]`, at least one value.
  private static func dense(_ text: String) -> VectorValue? {
    guard text.hasSuffix("]"), text.count >= 2 else { return nil }
    let body = text.dropFirst().dropLast()
    var leading: [Double] = []
    var count = 0
    var sumOfSquares = 0.0
    var minimum = Double.infinity
    var maximum = -Double.infinity
    let valid = forEachField(of: body) { field in
      guard count < maxDimensions, let value = number(field) else { return false }
      count += 1
      sumOfSquares += value * value
      minimum = min(minimum, value)
      maximum = max(maximum, value)
      if leading.count < previewCount { leading.append(value) }
      return true
    }
    guard valid, count > 0 else { return nil }
    return VectorValue(
      dimension: count, norm: sumOfSquares.squareRoot(), minimum: minimum, maximum: maximum,
      leadingValues: leading, nonZeroCount: nil)
  }

  /// `{i:v,...}/dim`, indices 1-based and strictly increasing; `{}/dim` is all zeros.
  private static func sparse(_ text: String) -> VectorValue? {
    guard let close = text.firstIndex(of: "}") else { return nil }
    let tail = text[text.index(after: close)...]
    guard tail.first == "/",
      let dimension = Int(tail.dropFirst().trimmingCharacters(in: .whitespaces)),
      (1...maxDimensions).contains(dimension)
    else { return nil }
    let body = text[text.index(after: text.startIndex)..<close]
    var leading = [Double](repeating: 0, count: min(dimension, previewCount))
    var count = 0
    var lastIndex = 0
    var sumOfSquares = 0.0
    var minimum = Double.infinity
    var maximum = -Double.infinity
    let isEmpty = body.allSatisfy(\.isWhitespace)
    let valid =
      isEmpty
      || forEachField(of: body) { field in
        let pair = field.split(separator: ":", omittingEmptySubsequences: false)
        guard pair.count == 2,
          let index = Int(pair[0].trimmingCharacters(in: .whitespaces)),
          index > lastIndex, index <= dimension, let value = number(pair[1])
        else { return false }
        lastIndex = index
        count += 1
        sumOfSquares += value * value
        minimum = min(minimum, value)
        maximum = max(maximum, value)
        if index <= leading.count { leading[index - 1] = value }
        return true
      }
    guard valid else { return nil }
    // Positions without an entry are zeros.
    if count < dimension {
      minimum = min(minimum, 0)
      maximum = max(maximum, 0)
    }
    return VectorValue(
      dimension: dimension, norm: sumOfSquares.squareRoot(), minimum: minimum, maximum: maximum,
      leadingValues: leading, nonZeroCount: count)
  }

  /// Calls `body` with each comma-separated field until it returns false. False when it did.
  private static func forEachField(
    of text: Substring, _ body: (Substring) -> Bool
  ) -> Bool {
    var start = text.startIndex
    while true {
      let end = text[start...].firstIndex(of: ",") ?? text.endIndex
      guard body(text[start..<end]) else { return false }
      guard end < text.endIndex else { return true }
      start = text.index(after: end)
    }
  }

  private static func number(_ field: Substring) -> Double? {
    guard let value = Double(field.trimmingCharacters(in: .whitespaces)), value.isFinite else {
      return nil
    }
    return value
  }
}
