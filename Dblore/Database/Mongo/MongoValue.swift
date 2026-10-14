// MongoValue.swift
// A BSON value as a pure Swift tree: documents keep their key order and duplicate keys.
// Parsed and rendered by `MongoRelaxedJSON`; mapped to and from driver types elsewhere.

import Foundation

/// A 12-byte ObjectId as 24 lowercase hex characters.
nonisolated struct MongoObjectId: Hashable, Sendable {
  let hex: String

  /// Accepts exactly 24 hex characters in any case and stores them lowercased.
  init?(hex: String) {
    guard hex.utf8.count == 24, hex.utf8.allSatisfy({ $0.isASCIIHexDigit }) else { return nil }
    self.hex = hex.lowercased()
  }
}

/// One BSON value. Documents are ordered key/value lists (duplicate keys stay, in order).
///
/// Equality is structural, with one deliberate rule for doubles: every NaN equals every other
/// NaN (a rendered NaN loses its payload), and `-0.0` differs from `0.0` (the sign is kept by
/// every renderer). Other doubles compare by value.
nonisolated indirect enum MongoValue: Equatable, Sendable {
  nonisolated struct Field: Equatable, Sendable {
    var key: String
    var value: MongoValue

    init(_ key: String, _ value: MongoValue) {
      self.key = key
      self.value = value
    }
  }

  case document([Field])
  case array([MongoValue])
  case string(String)
  case int32(Int32)
  case int64(Int64)
  case double(Double)
  /// The decimal text as written (syntax checked by the parser, not normalized).
  case decimal128(String)
  case bool(Bool)
  case null
  case objectId(MongoObjectId)
  /// Milliseconds since the Unix epoch (UTC).
  case date(Int64)
  case binary(subtype: UInt8, data: Data)
  case regex(pattern: String, options: String)
  case timestamp(t: UInt32, i: UInt32)
  case minKey
  case maxKey

  static func == (lhs: MongoValue, rhs: MongoValue) -> Bool {
    switch (lhs, rhs) {
    case (.document(let a), .document(let b)): return a == b
    case (.array(let a), .array(let b)): return a == b
    case (.string(let a), .string(let b)): return a == b
    case (.int32(let a), .int32(let b)): return a == b
    case (.int64(let a), .int64(let b)): return a == b
    case (.double(let a), .double(let b)):
      return (a.isNaN && b.isNaN) || a.bitPattern == b.bitPattern
    case (.decimal128(let a), .decimal128(let b)): return a == b
    case (.bool(let a), .bool(let b)): return a == b
    case (.null, .null), (.minKey, .minKey), (.maxKey, .maxKey): return true
    case (.objectId(let a), .objectId(let b)): return a == b
    case (.date(let a), .date(let b)): return a == b
    case (.binary(let s1, let d1), .binary(let s2, let d2)): return s1 == s2 && d1 == d2
    case (.regex(let p1, let o1), .regex(let p2, let o2)): return p1 == p2 && o1 == o2
    case (.timestamp(let t1, let i1), .timestamp(let t2, let i2)): return t1 == t2 && i1 == i2
    default: return false
    }
  }

  /// Number of nested documents and arrays on the deepest path (a scalar is 0).
  var nestingDepth: Int {
    switch self {
    case .document(let fields): 1 + (fields.map(\.value.nestingDepth).max() ?? 0)
    case .array(let items): 1 + (items.map(\.nestingDepth).max() ?? 0)
    default: 0
    }
  }
}

extension UInt8 {
  /// `0-9`, `A-F` or `a-f`.
  nonisolated var isASCIIHexDigit: Bool {
    (0x30...0x39).contains(self) || (0x41...0x46).contains(self) || (0x61...0x66).contains(self)
  }
}
