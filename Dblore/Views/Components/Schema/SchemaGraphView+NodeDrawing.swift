//
//  SchemaGraphView+NodeDrawing.swift
//  Dblore
//
//  Node drawing logic for schema graph visualization
//

import AppKit
import SwiftUI

// MARK: - Node Drawing Extension

extension SchemaGraphNSView {

  /// Check if a node should be highlighted due to edge hover/selection
  func isNodeHighlightedByEdge(_ nodeId: UUID) -> Bool {
    // Check if node is connected to highlighted edge (after hover delay)
    if let edgeId = highlightedEdgeId ?? selectedEdgeId,
      let edge = graph.edges.first(where: { $0.id == edgeId })
    {
      return edge.sourceNodeId == nodeId || edge.targetNodeId == nodeId
    }
    return false
  }

  /// Check if a node is connected to the currently selected node
  func isNodeConnectedToSelectedNode(_ nodeId: UUID) -> Bool {
    guard let selectedId = selectedNodeId, nodeId != selectedId else {
      return false
    }
    // Check if there's an edge connecting this node to the selected node
    return graph.edges.contains { edge in
      (edge.sourceNodeId == nodeId && edge.targetNodeId == selectedId)
        || (edge.sourceNodeId == selectedId && edge.targetNodeId == nodeId)
    }
  }

  /// Get column indices that should be highlighted for a node due to column connection hover or selection
  func getHighlightedColumnsForNode(_ nodeId: UUID) -> Set<Int> {
    guard showColumnConnections else { return [] }

    // Check both hover and selection states
    let activeEdgeId = hoveredColumnConnectionEdgeId ?? selectedColumnConnectionEdgeId
    guard let edgeId = activeEdgeId else { return [] }

    guard let highlightInfo = highlightedColumnsForEdge(edgeId) else {
      return []
    }

    if nodeId == highlightInfo.sourceNodeId {
      return Set(highlightInfo.sourceColumns)
    } else if nodeId == highlightInfo.targetNodeId {
      return Set(highlightInfo.targetColumns)
    }
    return []
  }

  func drawNodes(_ context: CGContext) {
    for node in graph.nodes {
      let rect = nodeRect(for: node)
      let isSelected = selectedNodeId == node.id
      let isHovered = hoveredNodeId == node.id
      let isHighlightedByEdge = isNodeHighlightedByEdge(node.id)
      let isConnectedToSelected = isNodeConnectedToSelectedNode(node.id)

      // Draw shadow (stronger when highlighted by edge, hovered, or connected to selected)
      let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      context.saveGState()
      if isHighlightedByEdge {
        context.setShadow(
          offset: CGSize(width: 0, height: 3), blur: 8,
          color: edgeHighlightColor.withAlphaComponent(0.4).cgColor)
      } else if isHovered && !isSelected || isConnectedToSelected {
        // Emphasized shadow for hovered and connected-to-selected nodes
        // Dark mode: white glow, Light mode: stronger dark shadow
        let shadowColor =
          isDarkMode
          ? NSColor.white.withAlphaComponent(0.2)
          : NSColor.black.withAlphaComponent(0.35)
        context.setShadow(
          offset: CGSize(width: 0, height: 3), blur: isDarkMode ? 6 : 8,
          color: shadowColor.cgColor)
      } else {
        context.setShadow(
          offset: CGSize(width: 0, height: 2), blur: 4,
          color: NSColor.black.withAlphaComponent(0.15).cgColor)
      }

      // Draw node background
      let path = CGPath(
        roundedRect: rect, cornerWidth: nodeCornerRadius, cornerHeight: nodeCornerRadius,
        transform: nil)
      context.addPath(path)
      context.setFillColor(nodeBackgroundColor.cgColor)
      context.fillPath()

      context.restoreGState()

      // Draw header background
      let headerRect = CGRect(
        x: rect.minX, y: rect.minY, width: rect.width, height: nodeHeaderHeight)
      let headerPath = CGMutablePath()
      headerPath.move(to: CGPoint(x: rect.minX + nodeCornerRadius, y: rect.minY))
      headerPath.addLine(to: CGPoint(x: rect.maxX - nodeCornerRadius, y: rect.minY))
      headerPath.addArc(
        center: CGPoint(x: rect.maxX - nodeCornerRadius, y: rect.minY + nodeCornerRadius),
        radius: nodeCornerRadius, startAngle: -.pi / 2, endAngle: 0, clockwise: false)
      headerPath.addLine(to: CGPoint(x: rect.maxX, y: headerRect.maxY))
      headerPath.addLine(to: CGPoint(x: rect.minX, y: headerRect.maxY))
      headerPath.addLine(to: CGPoint(x: rect.minX, y: rect.minY + nodeCornerRadius))
      headerPath.addArc(
        center: CGPoint(x: rect.minX + nodeCornerRadius, y: rect.minY + nodeCornerRadius),
        radius: nodeCornerRadius, startAngle: .pi, endAngle: -.pi / 2, clockwise: false)
      headerPath.closeSubpath()

      context.addPath(headerPath)
      context.setFillColor(nodeHeaderColor.cgColor)
      context.fillPath()

      // Draw border (highlighted when selected, hovered, connected to highlighted edge,
      // or connected to selected node)
      context.addPath(path)
      let borderColor: NSColor
      let borderWidth: CGFloat
      if isSelected || isHighlightedByEdge {
        borderColor = nodeSelectedBorderColor
        borderWidth = 2
      } else if isConnectedToSelected || isHovered {
        // Emphasized border for connected-to-selected and hovered nodes
        // Dark mode: lighter (white-blended), Light mode: darker (black-blended)
        borderColor =
          isDarkMode
          ? (nodeBorderColor.blended(withFraction: 0.5, of: .white) ?? nodeBorderColor)
          : (nodeBorderColor.blended(withFraction: 0.4, of: .black) ?? nodeBorderColor)
        borderWidth = 1.5
      } else {
        borderColor = nodeBorderColor
        borderWidth = 1
      }
      context.setStrokeColor(borderColor.cgColor)
      context.setLineWidth(borderWidth)
      context.strokePath()

      // Draw table name (with search highlight if matching)
      let tableName = node.table.name
      let tableFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
      let tablePoint = CGPoint(x: rect.minX + 10, y: rect.minY + 8)

      // Check if table name has search match
      let tableNameMatch = searchState.matches.first {
        $0.nodeId == node.id && $0.matchType == .tableName
      }

      if let match = tableNameMatch, !searchState.query.isEmpty {
        drawHighlightedText(
          context,
          text: tableName,
          at: tablePoint,
          font: tableFont,
          textColor: textColor,
          highlightRange: match.matchRange,
          isCurrentMatch: searchState.currentMatch?.id == match.id
        )
      } else {
        let tableAttributes: [NSAttributedString.Key: Any] = [
          .font: tableFont,
          .foregroundColor: textColor,
        ]
        let tableString = NSAttributedString(string: tableName, attributes: tableAttributes)
        tableString.draw(at: tablePoint)
      }

      // Draw expand button (arrow.up.left.and.arrow.down.right icon)
      let expandButtonRect = expandButtonRect(for: node)
      drawExpandButton(
        context, in: expandButtonRect, isHovered: hoveredExpandButtonNodeId == node.id)

      // Draw column count badge (moved to left of expand button)
      let columnCount = node.table.columns.count
      let countFont = NSFont.systemFont(ofSize: 9, weight: .medium)
      let countAttributes: [NSAttributedString.Key: Any] = [
        .font: countFont,
        .foregroundColor: subtleTextColor,
      ]
      let countString = NSAttributedString(string: "\(columnCount)", attributes: countAttributes)
      let countSize = countString.size()
      let countPoint = CGPoint(x: expandButtonRect.minX - countSize.width - 6, y: rect.minY + 10)
      countString.draw(at: countPoint)

      // Draw ALL columns
      drawColumns(context, node: node, rect: rect)

      // Draw dim overlay for unconnected cards when a node is selected
      // Skip if this node is selected, connected to selected, or highlighted by edge
      if selectedNodeId != nil && !isSelected && !isConnectedToSelected && !isHighlightedByEdge {
        context.saveGState()
        let dimPath = CGPath(
          roundedRect: rect, cornerWidth: nodeCornerRadius, cornerHeight: nodeCornerRadius,
          transform: nil)
        context.addPath(dimPath)
        // Semi-transparent overlay to dim unconnected cards
        // Use different colors for dark/light mode for better appearance
        let dimColor =
          isDarkMode
          ? NSColor.black.withAlphaComponent(0.5)
          : NSColor.white.withAlphaComponent(0.6)
        context.setFillColor(dimColor.cgColor)
        context.fillPath()
        context.restoreGState()
      }
    }
  }

  func drawColumns(_ context: CGContext, node: SchemaNode, rect: CGRect) {
    let columns = node.table.columns
    let columnFont = NSFont.systemFont(ofSize: 9, weight: .regular)
    let pkFont = NSFont.systemFont(ofSize: 9, weight: .medium)
    let typeFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
    let iconFont = NSFont.systemFont(ofSize: 8, weight: .medium)

    // Get highlighted columns for column connection hover
    let highlightedColumns = getHighlightedColumnsForNode(node.id)

    for (index, column) in columns.enumerated() {
      let y = rect.minY + nodeHeaderHeight + 4 + CGFloat(index) * nodeColumnHeight

      // Check if this column should be highlighted due to column connection hover
      let isColumnHighlighted = highlightedColumns.contains(index)

      // Draw column attribute icons (SF Symbols)
      var iconX = rect.minX + 6
      let iconSpacing: CGFloat = 10

      // Primary key icon (yellow key)
      if column.isPrimaryKey {
        drawSFSymbol("key.fill", at: CGPoint(x: iconX, y: y), color: .systemYellow, font: iconFont)
        iconX += iconSpacing
      }

      // Identity icon (number symbol)
      if column.isIdentity {
        drawSFSymbol("number", at: CGPoint(x: iconX, y: y), color: .systemBlue, font: iconFont)
        iconX += iconSpacing
      }

      // Unique icon (touchid symbol)
      if column.isUnique {
        drawSFSymbol("touchid", at: CGPoint(x: iconX, y: y), color: .systemPurple, font: iconFont)
        iconX += iconSpacing
      }

      // Nullable / Non-nullable icon (diamond)
      if column.isNullable {
        drawSFSymbol("diamond", at: CGPoint(x: iconX, y: y), color: subtleTextColor, font: iconFont)
      } else {
        drawSFSymbol(
          "diamond.fill", at: CGPoint(x: iconX, y: y), color: .systemGray, font: iconFont)
      }
      iconX += iconSpacing

      // Calculate available width for column name
      let typeAttributes: [NSAttributedString.Key: Any] = [
        .font: typeFont,
        .foregroundColor: subtleTextColor.withAlphaComponent(0.7),
      ]
      let typeString = NSAttributedString(string: column.type, attributes: typeAttributes)
      let typeSize = typeString.size()
      let typeX = rect.maxX - typeSize.width - 8
      let nameStartX = iconX + 2
      let maxNameWidth = typeX - nameStartX - columnTypeGap

      // Draw column name (with search highlight if matching, or green highlight for FK connection)
      let hasSpecialAttributes = column.isPrimaryKey || column.isIdentity || column.isUnique
      let nameFont = hasSpecialAttributes ? pkFont : columnFont
      // Use green color if highlighted by column connection hover
      let nameColor: NSColor =
        isColumnHighlighted
        ? .systemGreen : (hasSpecialAttributes ? textColor : columnTextColor)
      let namePoint = CGPoint(x: nameStartX, y: y)

      // Check if column name has search match
      let columnMatch = searchState.matches.first {
        $0.nodeId == node.id && $0.matchType == .columnName(columnIndex: index)
      }

      if let match = columnMatch, !searchState.query.isEmpty {
        // Truncate name if needed for search highlight
        let truncatedName = truncateText(
          column.name, font: nameFont, maxWidth: maxNameWidth)
        drawHighlightedText(
          context,
          text: truncatedName,
          at: namePoint,
          font: nameFont,
          textColor: nameColor,
          highlightRange: adjustRangeForTruncation(
            match.matchRange, originalText: column.name, truncatedText: truncatedName),
          isCurrentMatch: searchState.currentMatch?.id == match.id
        )
      } else {
        // Draw with potential green highlight for FK connection, truncated if needed
        let truncatedName = truncateText(column.name, font: nameFont, maxWidth: maxNameWidth)
        let nameAttributes: [NSAttributedString.Key: Any] = [
          .font: isColumnHighlighted ? NSFont.systemFont(ofSize: 9, weight: .semibold) : nameFont,
          .foregroundColor: nameColor,
        ]
        let nameString = NSAttributedString(string: truncatedName, attributes: nameAttributes)
        nameString.draw(at: namePoint)
      }

      // Draw type on the right
      typeString.draw(at: CGPoint(x: typeX, y: y + 1))
    }
  }

  /// Truncate text to fit within maxWidth, adding "..." if needed
  func truncateText(_ text: String, font: NSFont, maxWidth: CGFloat) -> String {
    let attributes: [NSAttributedString.Key: Any] = [.font: font]
    let fullWidth = (text as NSString).size(withAttributes: attributes).width

    if fullWidth <= maxWidth {
      return text
    }

    let ellipsis = "..."
    let ellipsisWidth = (ellipsis as NSString).size(withAttributes: attributes).width
    let availableWidth = maxWidth - ellipsisWidth

    if availableWidth <= 0 {
      return ellipsis
    }

    // Binary search for the right truncation point
    var low = 0
    var high = text.count

    while low < high {
      let mid = (low + high + 1) / 2
      let truncated = String(text.prefix(mid))
      let width = (truncated as NSString).size(withAttributes: attributes).width

      if width <= availableWidth {
        low = mid
      } else {
        high = mid - 1
      }
    }

    if low == 0 {
      return ellipsis
    }

    return String(text.prefix(low)) + ellipsis
  }

  /// Adjust highlight range for truncated text
  func adjustRangeForTruncation(
    _ range: Range<String.Index>, originalText: String, truncatedText: String
  ) -> Range<String.Index> {
    // If text wasn't truncated, return original range
    if !truncatedText.hasSuffix("...") {
      return range
    }

    let truncatedWithoutEllipsis = String(truncatedText.dropLast(3))
    let truncatedEndIndex = truncatedWithoutEllipsis.endIndex

    // Adjust range to fit within truncated text
    let adjustedLower = min(range.lowerBound, truncatedEndIndex)
    let adjustedUpper = min(range.upperBound, truncatedEndIndex)

    // Ensure we have a valid range
    if adjustedLower >= adjustedUpper {
      // Range is completely outside truncated text, return empty range at end
      return truncatedWithoutEllipsis.endIndex..<truncatedWithoutEllipsis.endIndex
    }

    return adjustedLower..<adjustedUpper
  }

  /// Draw an SF Symbol at the specified location, vertically centered with the text line
  func drawSFSymbol(
    _ name: String, at point: CGPoint, color: NSColor, font: NSFont, textHeight: CGFloat = 11
  ) {
    if let symbolImage = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
      let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .medium)
      let configuredImage = symbolImage.withSymbolConfiguration(config)

      // Draw the symbol
      let imageSize = CGSize(width: 8, height: 8)
      // Center the icon vertically with the text line
      let centeredY = point.y + (textHeight - imageSize.height) / 2
      let imageRect = CGRect(
        x: point.x, y: centeredY, width: imageSize.width, height: imageSize.height)

      // Apply color tint
      let tintedImage = configuredImage?.copy() as? NSImage
      tintedImage?.lockFocus()
      color.set()
      NSRect(origin: .zero, size: tintedImage?.size ?? .zero).fill(using: .sourceAtop)
      tintedImage?.unlockFocus()

      tintedImage?.draw(in: imageRect)
    }
  }

  /// Draw text with highlighted search match (zoom-independent highlight)
  func drawHighlightedText(
    _ context: CGContext,
    text: String,
    at point: CGPoint,
    font: NSFont,
    textColor: NSColor,
    highlightRange: Range<String.Index>,
    isCurrentMatch: Bool
  ) {
    // Create attributed string for the full text
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineBreakMode = .byClipping

    let baseAttributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: textColor,
      .paragraphStyle: paragraphStyle,
    ]

    // Calculate positions for highlight
    let beforeHighlight = String(text[..<highlightRange.lowerBound])
    let highlightedPart = String(text[highlightRange])
    let afterHighlight = String(text[highlightRange.upperBound...])

    // Measure text widths
    let beforeWidth =
      (beforeHighlight as NSString).size(withAttributes: baseAttributes).width
    let highlightWidth =
      (highlightedPart as NSString).size(withAttributes: baseAttributes).width
    let textHeight = (text as NSString).size(withAttributes: baseAttributes).height

    // Draw highlight background (using fixed pixel values, not scaled)
    // Save state to apply inverse scale for highlight rect
    context.saveGState()

    // Calculate highlight rect in canvas coordinates
    let highlightPadding: CGFloat = 1
    let highlightRect = CGRect(
      x: point.x + beforeWidth - highlightPadding,
      y: point.y - 1,
      width: highlightWidth + highlightPadding * 2,
      height: textHeight + 2
    )

    // Draw highlight with rounded corners
    // Current match: orange-yellow, Other matches: white (dark) / gray (light)
    let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let highlightColor: NSColor
    if isCurrentMatch {
      // #FFD500 orange-yellow
      highlightColor = NSColor(red: 1.0, green: 0.835, blue: 0.0, alpha: 1.0)
    } else {
      highlightColor =
        isDarkMode
        ? NSColor.white.withAlphaComponent(0.8)
        : NSColor.gray.withAlphaComponent(0.6)
    }

    context.setFillColor(highlightColor.cgColor)
    let highlightPath = CGPath(
      roundedRect: highlightRect, cornerWidth: 2, cornerHeight: 2, transform: nil)
    context.addPath(highlightPath)
    context.fillPath()

    // Draw border for current match
    if isCurrentMatch {
      context.setStrokeColor(NSColor.systemOrange.cgColor)
      context.setLineWidth(1)
      context.addPath(highlightPath)
      context.strokePath()
    }

    context.restoreGState()

    // Draw the text on top
    // Before highlight part
    if !beforeHighlight.isEmpty {
      let beforeString = NSAttributedString(string: beforeHighlight, attributes: baseAttributes)
      beforeString.draw(at: point)
    }

    // Highlighted part - use dark text color for better contrast on bright highlight background
    let highlightedTextColor = NSColor.black
    let highlightedAttributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: highlightedTextColor,
      .paragraphStyle: paragraphStyle,
    ]
    let highlightedString = NSAttributedString(
      string: highlightedPart, attributes: highlightedAttributes)
    highlightedString.draw(at: CGPoint(x: point.x + beforeWidth, y: point.y))

    // After highlight part
    if !afterHighlight.isEmpty {
      let afterString = NSAttributedString(string: afterHighlight, attributes: baseAttributes)
      afterString.draw(at: CGPoint(x: point.x + beforeWidth + highlightWidth, y: point.y))
    }
  }

  /// Draw expand button with hover effect
  func drawExpandButton(_ context: CGContext, in rect: CGRect, isHovered: Bool) {
    // Draw background on hover
    if isHovered {
      context.setFillColor(NSColor.white.withAlphaComponent(0.2).cgColor)
      let bgPath = CGPath(
        roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
      context.addPath(bgPath)
      context.fillPath()
    }

    // Draw the expand icon (arrow.up.left.and.arrow.down.right)
    let iconFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    drawSFSymbol(
      "arrow.up.left.and.arrow.down.right",
      at: CGPoint(x: rect.minX + 4, y: rect.minY + 4),
      color: isHovered ? textColor : subtleTextColor,
      font: iconFont
    )
  }
}
