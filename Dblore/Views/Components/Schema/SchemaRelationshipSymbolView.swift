//
//  SchemaRelationshipSymbolView.swift
//  Dblore
//
//  Shared ER notation symbol view for schema relationship legends
//

import SwiftUI

/// Relationship cardinality types for ER diagrams
enum SchemaRelationshipType {
  case one
  case many
  case zeroOrOne
  case zeroOrMany
}

/// Draws standard ER notation symbols for relationships
struct SchemaRelationshipSymbolView: View {
  let type: SchemaRelationshipType

  var body: some View {
    Canvas { context, size in
      let lineColor = Color.foregroundMuted
      let midY = size.height / 2

      // Draw the line
      var linePath = Path()
      linePath.move(to: CGPoint(x: 0, y: midY))
      linePath.addLine(to: CGPoint(x: size.width, y: midY))
      context.stroke(linePath, with: .color(lineColor), lineWidth: 1)

      // Draw the symbol at the end
      switch type {
      case .one:
        // Single vertical line (|)
        drawOneLine(context: context, at: size.width - 4, midY: midY, color: lineColor)

      case .many:
        // Crow's foot (three lines spreading out)
        drawCrowsFoot(context: context, at: size.width, midY: midY, color: lineColor)

      case .zeroOrOne:
        // Circle + vertical line (O|)
        drawCircle(context: context, at: size.width - 10, midY: midY, color: lineColor)
        drawOneLine(context: context, at: size.width - 4, midY: midY, color: lineColor)

      case .zeroOrMany:
        // Circle + crow's foot (O<)
        drawCircle(context: context, at: size.width - 14, midY: midY, color: lineColor)
        drawCrowsFoot(context: context, at: size.width, midY: midY, color: lineColor)
      }
    }
  }

  private func drawOneLine(
    context: GraphicsContext, at x: CGFloat, midY: CGFloat, color: Color
  ) {
    var path = Path()
    path.move(to: CGPoint(x: x, y: midY - 4))
    path.addLine(to: CGPoint(x: x, y: midY + 4))
    context.stroke(path, with: .color(color), lineWidth: 1)
  }

  private func drawCircle(
    context: GraphicsContext, at x: CGFloat, midY: CGFloat, color: Color
  ) {
    let circleRect = CGRect(x: x - 3, y: midY - 3, width: 6, height: 6)
    context.stroke(Path(ellipseIn: circleRect), with: .color(color), lineWidth: 1)
  }

  private func drawCrowsFoot(
    context: GraphicsContext, at endX: CGFloat, midY: CGFloat, color: Color
  ) {
    let footLength: CGFloat = 6
    let spread: CGFloat = 4

    var path = Path()
    // Center line
    path.move(to: CGPoint(x: endX, y: midY))
    path.addLine(to: CGPoint(x: endX - footLength, y: midY))

    // Upper line
    path.move(to: CGPoint(x: endX, y: midY))
    path.addLine(to: CGPoint(x: endX - footLength, y: midY - spread))

    // Lower line
    path.move(to: CGPoint(x: endX, y: midY))
    path.addLine(to: CGPoint(x: endX - footLength, y: midY + spread))

    context.stroke(path, with: .color(color), lineWidth: 1)
  }
}
