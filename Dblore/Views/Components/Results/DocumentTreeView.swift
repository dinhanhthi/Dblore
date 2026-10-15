//
//  DocumentTreeView.swift
//  Dblore
//
//  Documents view of a MongoDB result: one expandable row per document, nested fields indented,
//  type badges, "show more" paging, and copy actions (DocumentTreeModel).
//

import AppKit
import SwiftUI

/// The tree of a MongoDB result. The documents are rebuilt off the main actor per result.
struct DocumentTreeView: View {
  let result: CellResult
  /// Editor and data viewer fill the panel; a notebook cell gets a height from its visible rows.
  var fillsAvailableHeight = false

  @State private var model: DocumentTreeModel?
  /// Timestamp of the result `model` was built from
  @State private var modelStamp: Date?

  var body: some View {
    Group {
      if let model, modelStamp == result.timestamp {
        tree(model.visibleNodes)
      } else {
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil)
          .frame(height: fillsAvailableHeight ? nil : Self.height(rowCount: 1))
      }
    }
    .task(id: result.timestamp) { await build() }
  }

  private func build() async {
    let stamp = result.timestamp
    let columns = result.columns
    let rows = result.rows
    let built = await Task.detached(priority: .userInitiated) {
      DocumentTreeModel(columns: columns, rows: rows)
    }.value
    guard !Task.isCancelled else { return }
    model = built
    modelStamp = stamp
  }

  /// Fixed notebook height: the visible rows, at most as many as a grid shows.
  private static func height(rowCount: Int) -> CGFloat {
    ResultGridView.rowsHeight(rowCount: max(1, min(rowCount, ResultGridView.maxVisibleRows)))
      + Spacing.xs * 2
  }

  private func tree(_ nodes: [DocumentTreeNode]) -> some View {
    ScrollView(.vertical) {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(nodes) { node in
          DocumentTreeRow(
            node: node,
            onToggle: { model?.toggleExpansion(node.id) },
            onShowMore: { model?.showMore(node.id) },
            onCopy: { copy($0, node: node) }
          )
        }
      }
      .padding(.vertical, Spacing.xs)
    }
    .frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil)
    .frame(height: fillsAvailableHeight ? nil : Self.height(rowCount: nodes.count))
    .background(Color.cellBackground)
  }

  private func copy(_ action: DocumentTreeRow.CopyAction, node: DocumentTreeNode) {
    guard let model else { return }
    let text: String? =
      switch action {
      case .value: model.copyValueText(node.id)
      case .path: model.copyPathText(node.id)
      case .document: model.copyDocumentText(node.id)
      }
    guard let text else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

/// One tree row: disclosure, key, value preview and type badge; or a "show more" link.
private struct DocumentTreeRow: View {
  enum CopyAction {
    case value, path, document
  }

  let node: DocumentTreeNode
  let onToggle: () -> Void
  let onShowMore: () -> Void
  let onCopy: (CopyAction) -> Void
  @State private var isHovered = false

  private static let indentWidth: CGFloat = 16
  private static let disclosureWidth: CGFloat = 12

  private var font: Font {
    .system(size: AppSettings.shared.resultFontSize, design: .monospaced)
  }

  var body: some View {
    HStack(spacing: Spacing.xs) {
      Color.clear
        .frame(width: CGFloat(node.depth) * Self.indentWidth)
      switch node.kind {
      case .value: valueContent
      case .showMore(let remaining): showMoreButton(remaining: remaining)
      }
    }
    .padding(.horizontal, Spacing.sm)
    .frame(height: ResultGridView.rowHeight)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(isHovered && node.kind == .value ? Color.hoverFill : Color.clear)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    // A click on a document or array row expands or collapses it
    .onTapGesture { if node.isExpandable { onToggle() } }
    .contextMenu {
      if node.kind == .value {
        Button("Copy Value") { onCopy(.value) }
        if !node.path.isEmpty {
          Button("Copy Path") { onCopy(.path) }
        }
        Button("Copy Document as Extended JSON") { onCopy(.document) }
      }
    }
  }

  @ViewBuilder
  private var valueContent: some View {
    disclosure
    Text(node.key)
      .font(font)
      .foregroundColor(.gridForeground)
      .lineLimit(1)
      .layoutPriority(1)
    Text(node.preview)
      .font(font)
      .foregroundColor(previewColor)
      .lineLimit(1)
      .truncationMode(.tail)
    Spacer(minLength: Spacing.sm)
    badge
  }

  private var disclosure: some View {
    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
      .font(.system(size: 9, weight: .semibold))
      .foregroundColor(.foregroundMuted)
      .frame(width: Self.disclosureWidth)
      .opacity(node.isExpandable ? 1 : 0)
      .accessibilityHidden(!node.isExpandable)
  }

  /// Same neutral capsule as the history row badges
  private var badge: some View {
    Text(node.typeName)
      .font(.caption2)
      .foregroundColor(.foregroundMuted)
      .lineLimit(1)
      .padding(.horizontal, Spacing.xs)
      .background(Capsule().fill(Color.inputBackground))
      .overlay(Capsule().strokeBorder(Color.border, lineWidth: 1))
      .fixedSize()
  }

  private var previewColor: Color {
    switch node.typeName {
    case "int", "long", "double", "decimal": .gridNumber
    case "string", "objectId": .gridString
    case "date", "timestamp": .gridDate
    case "bool": .gridBoolean
    case "object", "array": .foregroundMuted
    default: .gridForeground
    }
  }

  private func showMoreButton(remaining: Int) -> some View {
    Button(action: onShowMore) {
      Text(
        "Show \(min(remaining, DocumentTreeModel.pageSize)) more (\(remaining) not shown)"
      )
      .font(.small)
      .foregroundColor(.accent)
    }
    .buttonStyle(.plain)
    .linkPointer()
    .padding(.leading, Self.disclosureWidth + Spacing.xs)
  }
}
