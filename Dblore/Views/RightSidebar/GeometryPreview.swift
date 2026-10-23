//
//  GeometryPreview.swift
//  Dblore
//
//  Cell Value viewer for a geometry: its shape drawn to fit (y up, points as dots), its type,
//  SRID and WKT. Drawn on a plain background, never over map tiles: a tile basemap would send
//  the coordinates to a third party.
//

import SwiftUI

/// A parsed geometry, ready to draw: built off the main actor, with what is drawn capped.
nonisolated struct GeometrySketch: Sendable {
  /// Rings and lines drawn together; the later ones are left out.
  static let maxDrawnParts = 5_000
  /// Vertices drawn in rings and lines together, after thinning; longer paths keep every n-th
  /// vertex.
  static let maxDrawnVertices = 20_000
  static let maxDrawnDots = 5_000
  /// WKT characters shown; Copy WKT writes all of it.
  static let maxShownWKT = 20_000

  let typeName: String
  let srid: UInt32?
  let pointCount: Int
  let bounds: GeometryWKB.Bounds?
  let geometry: GeometryWKB.Geometry
  let shownWKT: String
  /// Polygon rings, filled even-odd.
  let rings: [[CGPoint]]
  let lines: [[CGPoint]]
  let dots: [CGPoint]
  /// Some parts or dots were left out to stay within the caps.
  let isPartial: Bool

  init(_ value: GeometryWKB.Value) {
    var parts = Parts()
    Self.collect(value.geometry, into: &parts)
    let drawn = Self.drawn(rings: parts.rings, lines: parts.lines)

    var name = value.geometry.kind.wktName
    if value.geometry.hasZ { name += " Z" }
    if value.geometry.hasM { name += value.geometry.hasZ ? "M" : " M" }
    typeName = name
    srid = value.srid
    pointCount = value.pointCount
    bounds = value.bounds
    geometry = value.geometry
    shownWKT = value.wkt(maxLength: Self.maxShownWKT)
    rings = drawn.rings
    lines = drawn.lines
    dots = parts.dots
    isPartial = parts.isPartial || drawn.isPartial
  }

  /// The whole WKT, for Copy WKT: off the main actor, it can run to tens of MB.
  @concurrent static func fullWKT(_ geometry: GeometryWKB.Geometry) async -> String {
    var text = GeometryWKB.WKTText(limit: .max)
    GeometryWKB.writeWKT(geometry, to: &text)
    return text.string
  }

  /// Rings, lines and dots in order, up to `maxDrawnParts` and `maxDrawnDots`.
  private struct Parts {
    var rings: [[CGPoint]] = []
    var lines: [[CGPoint]] = []
    var dots: [CGPoint] = []
    var isPartial = false

    var isFull: Bool { rings.count + lines.count >= GeometrySketch.maxDrawnParts }
  }

  /// Finite x/y of every part; NaN or infinite vertices are left out.
  private static func collect(_ geometry: GeometryWKB.Geometry, into parts: inout Parts) {
    func finite(_ coordinates: [GeometryWKB.Coordinate]) -> [CGPoint] {
      coordinates.compactMap { $0.x.isFinite && $0.y.isFinite ? CGPoint(x: $0.x, y: $0.y) : nil }
    }
    switch geometry.shape {
    case .point(let coordinate):
      guard let coordinate else { return }
      guard parts.dots.count < maxDrawnDots else {
        parts.isPartial = true
        return
      }
      parts.dots += finite([coordinate])
    case .lineString(let coordinates):
      guard !parts.isFull else {
        parts.isPartial = true
        return
      }
      parts.lines.append(finite(coordinates))
    case .polygon(let polygonRings):
      for ring in polygonRings {
        guard !parts.isFull else {
          parts.isPartial = true
          return
        }
        parts.rings.append(finite(ring))
      }
    case .parts(_, let members):
      for member in members {
        collect(member, into: &parts)
      }
    }
  }

  /// The rings and lines thinned to one step, so that the vertices drawn stay within
  /// `maxDrawnVertices`; the parts that no longer fit are left out. A ring keeps at least
  /// 4 vertices, or is left out: fewer cannot enclose anything.
  private static func drawn(
    rings: [[CGPoint]], lines: [[CGPoint]]
  ) -> (rings: [[CGPoint]], lines: [[CGPoint]], isPartial: Bool) {
    let vertices = (rings + lines).reduce(0) { $0 + $1.count }
    // A thinned part keeps up to two vertices over its share, from rounding up and the kept
    // last vertex: two per part are set aside so that one huge part, or a few large ones,
    // always fit. A total within the cap is drawn whole.
    let share = max(1, maxDrawnVertices - 2 * (rings.count + lines.count))
    let step = vertices <= maxDrawnVertices ? 1 : max(1, (vertices + share - 1) / share)
    var budget = maxDrawnVertices
    var isPartial = false
    func fits(_ points: [CGPoint]) -> Bool {
      guard points.count <= budget else {
        isPartial = true
        return false
      }
      budget -= points.count
      return true
    }
    var drawnRings: [[CGPoint]] = []
    for ring in rings where ring.count >= 4 {
      // Every step-th of 0, s, 2s, 3s is still a vertex while 3s <= count - 1.
      let kept = thinned(ring, step: min(step, (ring.count - 1) / 3))
      guard fits(kept) else { break }
      drawnRings.append(kept)
    }
    var drawnLines: [[CGPoint]] = []
    for line in lines where !line.isEmpty {
      let kept = thinned(line, step: step)
      guard fits(kept) else { break }
      drawnLines.append(kept)
    }
    return (drawnRings, drawnLines, isPartial)
  }

  /// Every `step`-th vertex, the last one kept so a ring still closes.
  private static func thinned(_ points: [CGPoint], step: Int) -> [CGPoint] {
    guard step > 1, points.count > 2 else { return points }
    var kept = stride(from: 0, to: points.count, by: step).map { points[$0] }
    if (points.count - 1) % step != 0, let last = points.last { kept.append(last) }
    return kept
  }
}

/// Maps geometry coordinates into a canvas: uniform scale, centered, y up, `inset` all round.
/// A zero-width or zero-height extent (one point, a straight line) scales on the other axis
/// or sits in the middle. nil when the extent or the mapping overflows (finite but huge
/// coordinates): nothing is drawn then.
private struct GeometryFit {
  let minX: Double
  let maxY: Double
  let scale: Double
  let originX: Double
  let originY: Double

  init?(bounds: GeometryWKB.Bounds, size: CGSize, inset: CGFloat) {
    let width = bounds.maxX - bounds.minX
    let height = bounds.maxY - bounds.minY
    guard width.isFinite, height.isFinite else { return nil }
    let usableWidth = max(Double(size.width - inset * 2), 1)
    let usableHeight = max(Double(size.height - inset * 2), 1)
    let scale: Double
    switch (width > 0, height > 0) {
    case (true, true): scale = min(usableWidth / width, usableHeight / height)
    case (true, false): scale = usableWidth / width
    case (false, true): scale = usableHeight / height
    case (false, false): scale = 1
    }
    guard scale.isFinite, scale > 0 else { return nil }
    self.scale = scale
    minX = bounds.minX
    maxY = bounds.maxY
    originX = Double(inset) + (usableWidth - width * scale) / 2
    originY = Double(inset) + (usableHeight - height * scale) / 2
    guard originX.isFinite, originY.isFinite else { return nil }
  }

  func point(_ point: CGPoint) -> CGPoint {
    CGPoint(
      x: originX + (Double(point.x) - minX) * scale,
      y: originY + (maxY - Double(point.y)) * scale)
  }
}

struct GeometryPreview: View {
  let sketch: GeometrySketch

  @State private var isCopied = false

  private static let dotRadius: CGFloat = 3

  var body: some View {
    ScrollView(.vertical, showsIndicators: true) {
      VStack(alignment: .leading, spacing: Spacing.md) {
        shape
          .frame(height: 200)
          .frame(maxWidth: .infinity)
          .background(Color.tableHeaderBackground)
          .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))

        HStack(alignment: .top, spacing: Spacing.lg) {
          detail("Geometry", sketch.typeName)
          detail("Points", sketch.pointCount.formatted())
          detail("SRID", sketch.srid.map { String($0) } ?? "None")
        }

        HStack {
          Text("WKT")
            .font(.caption)
            .foregroundColor(.foregroundSubtle)

          Spacer()

          FloatingPanelButton(
            icon: isCopied ? "checkmark" : "doc.on.doc",
            helpText: "Copy WKT",
            useSymbolEffect: true,
            action: copyWKT
          )
        }

        Text(sketch.shownWKT)
          .font(.mono)
          .foregroundColor(.foreground)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(Spacing.sm)
          .background(Color.tableHeaderBackground)
          .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
  }

  private var shape: some View {
    Canvas { context, size in
      guard let bounds = sketch.bounds,
        let fit = GeometryFit(bounds: bounds, size: size, inset: Spacing.lg)
      else { return }

      var outline = Path()
      for ring in sketch.rings where !ring.isEmpty {
        outline.addLines(ring.map(fit.point))
        outline.closeSubpath()
      }
      // Only the rings are filled; the lines join them in the stroke.
      context.fill(outline, with: .color(.selectionFill), style: FillStyle(eoFill: true))

      for line in sketch.lines where !line.isEmpty {
        outline.addLines(line.map(fit.point))
      }
      context.stroke(
        outline, with: .color(.accent),
        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

      let radius = Self.dotRadius
      for dot in sketch.dots {
        let center = fit.point(dot)
        context.fill(
          Path(
            ellipseIn: CGRect(
              x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
          with: .color(.accent))
      }
    }
    .overlay {
      if sketch.bounds == nil {
        Text("Empty geometry")
          .font(.caption)
          .foregroundColor(.foregroundSubtle)
      }
    }
    .overlay(alignment: .bottomLeading) {
      if sketch.isPartial {
        Text("Partial preview")
          .font(.caption)
          .foregroundColor(.foregroundSubtle)
          .padding(Spacing.sm)
      }
    }
  }

  private func detail(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(label)
        .font(.caption)
        .foregroundColor(.foregroundSubtle)

      Text(value)
        .font(.mono)
        .foregroundColor(.foreground)
        .textSelection(.enabled)
    }
  }

  private func copyWKT() {
    let geometry = sketch.geometry
    Task {
      let wkt = await GeometrySketch.fullWKT(geometry)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(wkt, forType: .string)
      isCopied = true
      try? await Task.sleep(for: .seconds(0.5))
      isCopied = false
    }
  }
}
