// GeometryWKBTests.swift
// WKB / EWKB / MySQL internal geometry bytes -> geometry, WKT, bounds and SRID. The bytes are
// untrusted (any server, any cell), so malformed input must throw, never trap or allocate a
// declared count.

import Foundation
import Testing

@testable import Dblore

@Suite struct GeometryWKBTests {
  // MARK: - Builders

  private static func uint32(_ value: UInt32, littleEndian: Bool = true) -> [UInt8] {
    let word = littleEndian ? value.littleEndian : value.bigEndian
    return withUnsafeBytes(of: word) { Array($0) }
  }

  private static func double(_ value: Double, littleEndian: Bool = true) -> [UInt8] {
    let bits = littleEndian ? value.bitPattern.littleEndian : value.bitPattern.bigEndian
    return withUnsafeBytes(of: bits) { Array($0) }
  }

  /// Little-endian header: byte order, type word.
  private static func header(_ type: UInt32) -> [UInt8] {
    [1] + uint32(type)
  }

  private static func point(_ x: Double, _ y: Double) -> [UInt8] {
    header(1) + double(x) + double(y)
  }

  private static func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined()
  }

  // MARK: - Core

  @Test func mySQLPointWithSRIDPrefix() throws {
    let bytes = Self.uint32(4326) + Self.point(1, 2)
    let value = try GeometryWKB.parse(Data(bytes))
    #expect(value.wkt == "POINT (1 2)")
    #expect(value.srid == 4326)
    #expect(value.bounds == GeometryWKB.Bounds(minX: 1, minY: 2, maxX: 1, maxY: 2))
  }

  @Test func ewkbPolygonWithSRIDFromHex() throws {
    let ring: [(Double, Double)] = [(0, 0), (10, 0), (10, 10), (0, 10), (0, 0)]
    let bytes =
      Self.header(0x2000_0003) + Self.uint32(4326) + Self.uint32(1) + Self.uint32(5)
      + ring.flatMap { Self.double($0.0) + Self.double($0.1) }
    let value = try GeometryWKB.parse(hex: Self.hex(bytes))
    #expect(value.wkt == "POLYGON ((0 0, 10 0, 10 10, 0 10, 0 0))")
    #expect(value.srid == 4326)
    #expect(value.bounds == GeometryWKB.Bounds(minX: 0, minY: 0, maxX: 10, maxY: 10))
  }

  @Test func zPointInISOBigEndianAndEWKBFlag() throws {
    let iso =
      [0] + Self.uint32(1001, littleEndian: false)
      + [1.0, 2, 3].flatMap { Self.double($0, littleEndian: false) }
    #expect(try GeometryWKB.parse(Data(iso)).wkt == "POINT Z (1 2 3)")
    let ewkb = Self.header(0x8000_0001) + [1.0, 2, 3].flatMap { Self.double($0) }
    let value = try GeometryWKB.parse(Data(ewkb))
    #expect(value.wkt == "POINT Z (1 2 3)")
    #expect(value.srid == nil)
  }

  @Test func collectionOfMixedParts() throws {
    let line = Self.header(2) + Self.uint32(2) + [0.0, 0, 3, 4].flatMap { Self.double($0) }
    let bytes = Self.header(7) + Self.uint32(2) + Self.point(-1, 5) + line
    let value = try GeometryWKB.parse(Data(bytes))
    #expect(value.wkt == "GEOMETRYCOLLECTION (POINT (-1 5), LINESTRING (0 0, 3 4))")
    #expect(value.bounds == GeometryWKB.Bounds(minX: -1, minY: 0, maxX: 3, maxY: 5))
  }

  // MARK: - Security

  @Test(arguments: [
    // Truncated point: one coordinate byte missing.
    Self.hex(Array(Self.point(1, 2).dropLast())),
    // LineString declaring 0xFFFFFFFF points with one point of data.
    Self.hex(Self.header(2) + Self.uint32(0xFFFF_FFFF) + Self.double(1) + Self.double(2)),
    // MultiPolygon declaring 0xFFFFFFFF parts.
    Self.hex(Self.header(6) + Self.uint32(0xFFFF_FFFF)),
    // Unknown type, bad byte order, trailing bytes.
    Self.hex(Self.header(99) + Self.double(1) + Self.double(2)),
    Self.hex([7] + Self.uint32(1) + Self.double(1) + Self.double(2)),
    Self.hex(Self.point(1, 2) + [0]),
    // MultiPoint holding a LineString.
    Self.hex(Self.header(4) + Self.uint32(1) + Self.header(2) + Self.uint32(0)),
    // Odd and non-hex text, empty input.
    "0101000", "01zz", "",
  ])
  func malformedInputThrows(_ hex: String) {
    #expect(throws: GeometryWKB.ParseError.self) { try GeometryWKB.parse(hex: hex) }
  }

  @Test func nestingDeeperThanTheCapThrows() {
    var bytes = Self.point(1, 2)
    for _ in 0..<GeometryWKB.maxDepth {
      bytes = Self.header(7) + Self.uint32(1) + bytes
    }
    #expect(throws: GeometryWKB.ParseError.tooDeep) { try GeometryWKB.parse(Data(bytes)) }
  }

  @Test func pointsBeyondTheCapThrow() {
    let count = GeometryWKB.maxPoints + 1
    var bytes = Self.header(2) + Self.uint32(UInt32(count))
    bytes += [UInt8](repeating: 0, count: count * 16)
    #expect(throws: GeometryWKB.ParseError.tooManyPoints) { try GeometryWKB.parse(Data(bytes)) }
  }

  @Test func bytesBeyondTheCapThrow() {
    #expect(throws: GeometryWKB.ParseError.tooManyPoints) {
      try GeometryWKB.parse(Data(count: GeometryWKB.maxBytes + 1))
    }
  }

  @Test func nonFiniteCoordinatesStayOutOfBounds() throws {
    let empty = try GeometryWKB.parse(Data(Self.point(.nan, .nan)))
    #expect(empty.wkt == "POINT EMPTY")
    #expect(empty.bounds == nil)
    #expect(empty.pointCount == 0)
    let line =
      Self.header(2) + Self.uint32(2)
      + [Double.infinity, 1, 2, 3].flatMap { Self.double($0) }
    #expect(
      try GeometryWKB.parse(Data(line)).bounds
        == GeometryWKB.Bounds(minX: 2, minY: 3, maxX: 2, maxY: 3))
  }

  // MARK: - Sketch

  @Test func sketchOfAHugeMultiPolygonStaysWithinTheDrawCaps() {
    let ring = [(0.0, 0.0), (1, 0), (1, 1), (0, 1), (0, 0)].map {
      GeometryWKB.Coordinate(x: $0.0, y: $0.1)
    }
    let polygon = GeometryWKB.Geometry(shape: .polygon([ring]), hasZ: false, hasM: false)
    let multi = GeometryWKB.Geometry(
      shape: .parts(.multiPolygon, Array(repeating: polygon, count: 200_000)), hasZ: false,
      hasM: false)
    let sketch = GeometrySketch(
      GeometryWKB.Value(
        geometry: multi, srid: nil, bounds: GeometryWKB.Bounds(minX: 0, minY: 0, maxX: 1, maxY: 1),
        pointCount: 1_000_000))
    #expect(!sketch.rings.isEmpty)
    #expect(sketch.rings.count + sketch.lines.count <= GeometrySketch.maxDrawnParts)
    #expect(
      (sketch.rings + sketch.lines).reduce(0) { $0 + $1.count } <= GeometrySketch.maxDrawnVertices)
    #expect(sketch.rings.allSatisfy { $0.count >= 4 })
    #expect(sketch.isPartial)
    #expect(sketch.shownWKT.count <= GeometrySketch.maxShownWKT + 1)
  }

  private static func sketch(_ geometry: GeometryWKB.Geometry, extent: Double) -> GeometrySketch {
    GeometrySketch(
      GeometryWKB.Value(
        geometry: geometry, srid: nil,
        bounds: GeometryWKB.Bounds(minX: 0, minY: 0, maxX: extent, maxY: extent),
        pointCount: 0))
  }

  private static func drawnVertices(_ sketch: GeometrySketch) -> Int {
    (sketch.rings + sketch.lines).reduce(0) { $0 + $1.count }
  }

  @Test func sketchOfOneHugeLineStringThinsItWithinTheVertexCap() {
    let line = (0..<1_000_000).map { GeometryWKB.Coordinate(x: Double($0), y: Double($0 % 7)) }
    let sketch = Self.sketch(
      GeometryWKB.Geometry(shape: .lineString(line), hasZ: false, hasM: false), extent: 1_000_000)
    #expect(sketch.lines.count == 1)
    #expect(Self.drawnVertices(sketch) <= GeometrySketch.maxDrawnVertices)
    #expect(!sketch.isPartial)
  }

  @Test func sketchWithinTheVertexCapIsDrawnWhole() {
    let lines = (0..<5_000).map { index in
      GeometryWKB.Geometry(
        shape: .lineString(
          (0..<3).map { GeometryWKB.Coordinate(x: Double(index), y: Double($0)) }),
        hasZ: false, hasM: false)
    }
    let sketch = Self.sketch(
      GeometryWKB.Geometry(shape: .parts(.multiLineString, lines), hasZ: false, hasM: false),
      extent: 5_000)
    #expect(sketch.lines.count == 5_000)
    #expect(sketch.lines.allSatisfy { $0.count == 3 })
    #expect(!sketch.isPartial)
  }

  @Test func sketchOfThreeLargeRingsDrawsAllOfThemWithinTheVertexCap() {
    func ring(_ size: Double) -> [GeometryWKB.Coordinate] {
      (0..<100_000).map {
        let angle = Double($0) / 99_999 * 2 * .pi
        return GeometryWKB.Coordinate(x: size * cos(angle), y: size * sin(angle))
      }
    }
    let polygon = GeometryWKB.Geometry(
      shape: .polygon([ring(3), ring(2), ring(1)]), hasZ: false, hasM: false)
    let sketch = Self.sketch(
      GeometryWKB.Geometry(shape: .parts(.multiPolygon, [polygon]), hasZ: false, hasM: false),
      extent: 3)
    #expect(sketch.rings.count == 3)
    #expect(Self.drawnVertices(sketch) <= GeometrySketch.maxDrawnVertices)
    #expect(!sketch.isPartial)
  }
}
