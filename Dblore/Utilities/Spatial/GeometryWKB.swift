// GeometryWKB.swift
// Geometry bytes -> geometry model, WKT, bounds and SRID. Reads OGC WKB in both byte orders,
// ISO type codes (+1000 Z, +2000 M, +3000 ZM), PostGIS EWKB flags (0x80000000 Z,
// 0x40000000 M, 0x20000000 SRID follows the type) and MySQL's internal value (a 4-byte
// little-endian SRID, then WKB). PostGIS text output is the same EWKB as hex.
// The bytes are untrusted: every read is checked against the bytes left, a declared count must
// fit in them before anything is read, and caps bound the points and the nesting.

import Foundation

nonisolated enum GeometryWKB {
  /// Points in one value, all parts together.
  static let maxPoints = 1_000_000
  /// Parts and rings in one value, so a value of empty parts stays bounded too.
  static let maxParts = 1_000_000
  /// Levels of geometry, the outer one included.
  static let maxDepth = 32
  /// Bytes of the largest value the caps allow (every point ZM, every part with a header, an
  /// SRID and a count, MySQL's prefix): anything longer is never read.
  static let maxBytes = maxPoints * 32 + (maxParts + 1) * 13 + 4

  enum ParseError: Error, Equatable, Sendable {
    case truncated
    case invalidHex
    case invalidByteOrder
    case unknownType(UInt32)
    case unexpectedPart
    case tooManyPoints
    case tooManyParts
    case tooDeep
    case trailingBytes
  }

  struct Coordinate: Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double?
    var m: Double?
  }

  enum Kind: UInt32, Sendable {
    case point = 1
    case lineString
    case polygon
    case multiPoint
    case multiLineString
    case multiPolygon
    case geometryCollection

    var wktName: String {
      switch self {
      case .point: "POINT"
      case .lineString: "LINESTRING"
      case .polygon: "POLYGON"
      case .multiPoint: "MULTIPOINT"
      case .multiLineString: "MULTILINESTRING"
      case .multiPolygon: "MULTIPOLYGON"
      case .geometryCollection: "GEOMETRYCOLLECTION"
      }
    }
  }

  indirect enum Shape: Equatable, Sendable {
    /// nil: an empty point, which WKB writes as NaN coordinates.
    case point(Coordinate?)
    case lineString([Coordinate])
    case polygon([[Coordinate]])
    /// `.multiPoint`, `.multiLineString`, `.multiPolygon` or `.geometryCollection`.
    case parts(Kind, [Geometry])
  }

  struct Geometry: Equatable, Sendable {
    var shape: Shape
    var hasZ: Bool
    var hasM: Bool

    var kind: Kind {
      switch shape {
      case .point: .point
      case .lineString: .lineString
      case .polygon: .polygon
      case .parts(let kind, _): kind
      }
    }
  }

  /// Extent of the finite coordinates.
  struct Bounds: Equatable, Sendable {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double
  }

  struct Value: Sendable {
    var geometry: Geometry
    var srid: UInt32?
    /// nil when no coordinate is finite (an empty geometry, NaN or infinite values).
    var bounds: Bounds?
    var pointCount: Int

    var wkt: String { wkt(maxLength: .max) }

    /// WKT cut after `maxLength` characters (WKT is ASCII), with `…` when cut. The writer stops
    /// once the text is full, so a huge geometry is never written whole.
    func wkt(maxLength: Int) -> String {
      var text = WKTText(limit: maxLength)
      GeometryWKB.writeWKT(geometry, to: &text)
      guard text.isFull else { return text.string }
      return String(text.string.prefix(maxLength)) + "…"
    }
  }

  // MARK: - Entry points

  /// EWKB / WKB, or else MySQL's SRID-prefixed WKB. Every byte must belong to the geometry.
  static func parse(_ data: Data) throws -> Value {
    guard data.count <= maxBytes else { throw ParseError.tooManyPoints }
    let bytes = [UInt8](data)
    do {
      return try parse(bytes, from: 0, srid: nil)
    } catch {
      guard bytes.count >= 4 else { throw error }
      let prefix = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16
      let srid = prefix | UInt32(bytes[3]) << 24
      guard let value = try? parse(bytes, from: 4, srid: srid) else { throw error }
      return value
    }
  }

  /// Hex text of the same bytes, as PostGIS prints a geometry; a `\x` bytea prefix is allowed.
  static func parse(hex text: String) throws -> Value {
    // Two digits a byte, an optional `\x` and a little whitespace: longer text is never decoded.
    guard text.utf8.count <= maxBytes * 2 + 16 else { throw ParseError.tooManyPoints }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var digits = trimmed.utf8[...]
    if digits.starts(with: "\\x".utf8) { digits = digits.dropFirst(2) }
    guard !digits.isEmpty, digits.count.isMultiple(of: 2) else { throw ParseError.invalidHex }
    var bytes: [UInt8] = []
    var high: UInt8?
    for char in digits {
      guard let nibble = hexValue(char) else { throw ParseError.invalidHex }
      if let first = high {
        bytes.append(first << 4 | nibble)
        high = nil
      } else {
        high = nibble
      }
    }
    return try parse(Data(bytes))
  }

  private static func hexValue(_ char: UInt8) -> UInt8? {
    switch char {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): char - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): char - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): char - UInt8(ascii: "A") + 10
    default: nil
    }
  }

  private static func parse(
    _ bytes: [UInt8], from offset: Int, srid prefixSRID: UInt32?
  ) throws
    -> Value
  {
    var reader = Reader(bytes: bytes, offset: offset)
    let geometry = try reader.geometry(depth: 0)
    guard reader.remaining == 0 else { throw ParseError.trailingBytes }
    return Value(
      geometry: geometry, srid: prefixSRID ?? reader.srid, bounds: reader.bounds,
      pointCount: reader.points)
  }

  // MARK: - Reader

  private struct Reader {
    let bytes: [UInt8]
    var offset: Int
    var littleEndian = true
    /// SRID of the outer geometry, from the EWKB flag.
    var srid: UInt32?
    var bounds: Bounds?
    var points = 0
    var parts = 0

    init(bytes: [UInt8], offset: Int) {
      self.bytes = bytes
      self.offset = offset
    }

    var remaining: Int { bytes.count - offset }

    mutating func byte() throws -> UInt8 {
      guard remaining >= 1 else { throw ParseError.truncated }
      defer { offset += 1 }
      return bytes[offset]
    }

    mutating func uint32() throws -> UInt32 {
      guard remaining >= 4 else { throw ParseError.truncated }
      var value: UInt32 = 0
      for index in 0..<4 {
        let byte = UInt32(bytes[offset + index])
        value |= littleEndian ? byte << (8 * index) : byte << (8 * (3 - index))
      }
      offset += 4
      return value
    }

    mutating func double() throws -> Double {
      guard remaining >= 8 else { throw ParseError.truncated }
      var bits: UInt64 = 0
      for index in 0..<8 {
        let byte = UInt64(bytes[offset + index])
        bits |= littleEndian ? byte << (8 * index) : byte << (8 * (7 - index))
      }
      offset += 8
      return Double(bitPattern: bits)
    }

    /// A declared count, checked against the bytes left (each element takes at least
    /// `minimumBytes`) before any element is read.
    mutating func declaredCount(minimumBytes: Int) throws -> Int {
      let declared = Int(try uint32())
      guard declared <= remaining / minimumBytes else { throw ParseError.truncated }
      return declared
    }

    mutating func addParts(_ count: Int) throws {
      guard count <= GeometryWKB.maxParts - parts else { throw ParseError.tooManyParts }
      parts += count
    }

    mutating func geometry(depth: Int) throws -> Geometry {
      guard depth < GeometryWKB.maxDepth else { throw ParseError.tooDeep }
      // A part may use another byte order than its parent.
      let outerOrder = littleEndian
      defer { littleEndian = outerOrder }
      switch try byte() {
      case 0: littleEndian = false
      case 1: littleEndian = true
      default: throw ParseError.invalidByteOrder
      }
      let word = try uint32()
      let code = word & 0x1FFF_FFFF
      let iso = code / 1000
      guard iso <= 3, let kind = Kind(rawValue: code % 1000) else {
        throw ParseError.unknownType(word)
      }
      let flagZ = word & 0x8000_0000 != 0
      let flagM = word & 0x4000_0000 != 0
      // One form or the other, never both.
      guard iso == 0 || !(flagZ || flagM) else { throw ParseError.unknownType(word) }
      let hasZ = flagZ || iso == 1 || iso == 3
      let hasM = flagM || iso == 2 || iso == 3
      if word & 0x2000_0000 != 0 {
        let srid = try uint32()
        if depth == 0 { self.srid = srid }
      }
      let width = 2 + (hasZ ? 1 : 0) + (hasM ? 1 : 0)

      let shape: Shape
      switch kind {
      case .point:
        let coordinate = try coordinates(1, width: width, hasZ: hasZ, hasM: hasM)[0]
        let isEmpty = coordinate.x.isNaN && coordinate.y.isNaN
        // POINT EMPTY holds no point.
        if isEmpty { points -= 1 }
        shape = .point(isEmpty ? nil : coordinate)
      case .lineString:
        shape = .lineString(try sequence(width: width, hasZ: hasZ, hasM: hasM))
      case .polygon:
        shape = .polygon(try rings(width: width, hasZ: hasZ, hasM: hasM))
      case .multiPoint, .multiLineString, .multiPolygon, .geometryCollection:
        // Each part is a whole geometry: byte order and type at least.
        let count = try declaredCount(minimumBytes: 5)
        try addParts(count)
        var members: [Geometry] = []
        for _ in 0..<count {
          let member = try geometry(depth: depth + 1)
          guard kind == .geometryCollection || member.kind.rawValue == kind.rawValue - 3 else {
            throw ParseError.unexpectedPart
          }
          members.append(member)
        }
        shape = .parts(kind, members)
      }
      return Geometry(shape: shape, hasZ: hasZ, hasM: hasM)
    }

    mutating func rings(width: Int, hasZ: Bool, hasM: Bool) throws -> [[Coordinate]] {
      let count = try declaredCount(minimumBytes: 4)
      try addParts(count)
      var rings: [[Coordinate]] = []
      for _ in 0..<count {
        rings.append(try sequence(width: width, hasZ: hasZ, hasM: hasM))
      }
      return rings
    }

    mutating func sequence(width: Int, hasZ: Bool, hasM: Bool) throws -> [Coordinate] {
      try coordinates(
        try declaredCount(minimumBytes: width * 8), width: width, hasZ: hasZ, hasM: hasM)
    }

    /// `count` coordinates, already checked against the bytes left.
    mutating func coordinates(
      _ count: Int, width: Int, hasZ: Bool, hasM: Bool
    ) throws
      -> [Coordinate]
    {
      guard count <= GeometryWKB.maxPoints - points else { throw ParseError.tooManyPoints }
      points += count
      var result: [Coordinate] = []
      for _ in 0..<count {
        let x = try double()
        let y = try double()
        let z = hasZ ? try double() : nil
        let m = hasM ? try double() : nil
        include(x: x, y: y)
        result.append(Coordinate(x: x, y: y, z: z, m: m))
      }
      return result
    }

    mutating func include(x: Double, y: Double) {
      guard x.isFinite, y.isFinite else { return }
      guard var box = bounds else {
        bounds = Bounds(minX: x, minY: y, maxX: x, maxY: y)
        return
      }
      box.minX = min(box.minX, x)
      box.minY = min(box.minY, y)
      box.maxX = max(box.maxX, x)
      box.maxY = max(box.maxY, y)
      bounds = box
    }
  }

  // MARK: - WKT

  /// WKT being written: appends are dropped once it holds more than `limit` UTF-8 bytes.
  struct WKTText {
    let limit: Int
    var string = ""

    var isFull: Bool { string.utf8.count > limit }

    static func += (text: inout WKTText, part: String) {
      if !text.isFull { text.string += part }
    }
  }

  /// ISO WKT: `POINT Z (1 2 3)`, `POLYGON ((0 0, 1 0, 0 0))`, `MULTIPOINT ((1 2))`, `EMPTY`.
  static func writeWKT(_ geometry: Geometry, to text: inout WKTText) {
    text += geometry.kind.wktName
    switch (geometry.hasZ, geometry.hasM) {
    case (true, true): text += " ZM"
    case (true, false): text += " Z"
    case (false, true): text += " M"
    case (false, false): break
    }
    text += " "
    switch geometry.shape {
    case .point(let coordinate):
      guard let coordinate else {
        text += "EMPTY"
        return
      }
      text += "("
      writeCoordinate(coordinate, to: &text)
      text += ")"
    case .lineString(let coordinates):
      writeSequence(coordinates, to: &text)
    case .polygon(let rings):
      writeRings(rings, to: &text)
    case .parts(let kind, let members):
      guard !members.isEmpty else {
        text += "EMPTY"
        return
      }
      text += "("
      for (index, member) in members.enumerated() {
        guard !text.isFull else { return }
        if index > 0 { text += ", " }
        switch (kind, member.shape) {
        case (.geometryCollection, _): writeWKT(member, to: &text)
        case (_, .point(let coordinate)):
          if let coordinate {
            text += "("
            writeCoordinate(coordinate, to: &text)
            text += ")"
          } else {
            text += "EMPTY"
          }
        case (_, .lineString(let coordinates)): writeSequence(coordinates, to: &text)
        case (_, .polygon(let rings)): writeRings(rings, to: &text)
        case (_, .parts): writeWKT(member, to: &text)
        }
      }
      text += ")"
    }
  }

  private static func writeRings(_ rings: [[Coordinate]], to text: inout WKTText) {
    guard !rings.isEmpty else {
      text += "EMPTY"
      return
    }
    text += "("
    for (index, ring) in rings.enumerated() {
      guard !text.isFull else { return }
      if index > 0 { text += ", " }
      writeSequence(ring, to: &text)
    }
    text += ")"
  }

  private static func writeSequence(_ coordinates: [Coordinate], to text: inout WKTText) {
    guard !coordinates.isEmpty else {
      text += "EMPTY"
      return
    }
    text += "("
    for (index, coordinate) in coordinates.enumerated() {
      guard !text.isFull else { return }
      if index > 0 { text += ", " }
      writeCoordinate(coordinate, to: &text)
    }
    text += ")"
  }

  private static func writeCoordinate(_ coordinate: Coordinate, to text: inout WKTText) {
    text += number(coordinate.x)
    text += " "
    text += number(coordinate.y)
    if let z = coordinate.z { text += " " + number(z) }
    if let m = coordinate.m { text += " " + number(m) }
  }

  /// `1` rather than `1.0`; the shortest round-trip text otherwise (`0.1`, `1e+20`, `nan`).
  static func number(_ value: Double) -> String {
    if value.isFinite, value == value.rounded(), abs(value) < 1e15 {
      return String(Int64(value))
    }
    return String(value)
  }
}
