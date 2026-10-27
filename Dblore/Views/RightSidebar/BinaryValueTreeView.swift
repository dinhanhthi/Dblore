// BinaryValueTreeView.swift
// Read-only view of a binary cell decoded by its Display As format (`CellInfoContent`): a
// MessagePack or Protobuf value as expandable lines (key or field number, value, kind), a
// scalar root (hex, UUID) as wrapped text. Only the lines of expanded nodes are built, and they
// render lazily, so a 10,000-node value opens with its first level only.

import SwiftUI

struct BinaryValueTreeView: View {
  let root: BinaryValueNode

  /// Index paths of the expanded containers; the root starts expanded
  @State private var expanded: Set<[Int]> = [[]]

  var body: some View {
    Group {
      if Self.isContainer(root) {
        ScrollView(.vertical, showsIndicators: true) {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Self.lines(of: root, expanded: expanded)) { line in
              BinaryValueTreeRow(line: line, isExpanded: expanded.contains(line.id)) {
                toggle(line.id)
              }
            }
          }
          .padding(.vertical, Spacing.xs)
        }
      } else {
        ScrollView(.vertical, showsIndicators: true) {
          Text(root.text ?? "")
            .font(.mono)
            .foregroundColor(.foreground)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(Spacing.sm)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.tableHeaderBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    // Another cell's value starts collapsed again
    .onChange(of: root) { expanded = [[]] }
  }

  private func toggle(_ path: [Int]) {
    if expanded.contains(path) {
      expanded.remove(path)
    } else {
      expanded.insert(path)
    }
  }

  /// One shown line: a node under every expanded ancestor
  struct Line: Identifiable {
    /// Index path from the root (the root is `[]`)
    let id: [Int]
    let node: BinaryValueNode
    /// Map key, field number or array index; nil for the root
    let label: String?
  }

  /// Lines of `root` in display order: the root, then the children of every expanded container
  static func lines(of root: BinaryValueNode, expanded: Set<[Int]>) -> [Line] {
    var lines: [Line] = []
    func visit(_ node: BinaryValueNode, path: [Int], label: String?) {
      lines.append(Line(id: path, node: node, label: label))
      guard expanded.contains(path) else { return }
      for (index, child) in node.children.enumerated() {
        let childLabel = child.label ?? (node.kind == .array ? String(index) : nil)
        visit(child, path: path + [index], label: childLabel)
      }
    }
    visit(root, path: [], label: nil)
    return lines
  }

  static func isContainer(_ node: BinaryValueNode) -> Bool {
    switch node.kind {
    case .array, .map, .message: true
    default: false
    }
  }
}

/// One line: indent, disclosure, `label:`, value (or a container's size), kind badge. A click on
/// a container expands or collapses it.
private struct BinaryValueTreeRow: View {
  let line: BinaryValueTreeView.Line
  let isExpanded: Bool
  let onToggle: () -> Void
  @State private var isHovered = false

  private static let indentWidth: CGFloat = 16
  private static let disclosureWidth: CGFloat = 12

  private var isContainer: Bool { BinaryValueTreeView.isContainer(line.node) }
  private var isExpandable: Bool { isContainer && !line.node.children.isEmpty }

  var body: some View {
    HStack(spacing: Spacing.xs) {
      Color.clear.frame(width: CGFloat(line.id.count) * Self.indentWidth)
      Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
        .font(.system(size: 9, weight: .semibold))
        .foregroundColor(.foregroundMuted)
        .frame(width: Self.disclosureWidth)
        .opacity(isExpandable ? 1 : 0)
        .accessibilityHidden(!isExpandable)
      if let label = line.label {
        HStack(spacing: 0) {
          Text(label).foregroundColor(.gridForeground)
          Text(":").foregroundColor(.foregroundMuted)
        }
        .lineLimit(1)
        .layoutPriority(1)
      }
      Text(preview)
        .foregroundColor(color)
        .lineLimit(1)
        .truncationMode(.tail)
        .help(line.node.text ?? "")
      Spacer(minLength: Spacing.sm)
      badge
    }
    .font(.monoMedium)
    .padding(.horizontal, Spacing.sm)
    .frame(height: 22)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(isHovered && isExpandable ? Color.hoverFill : Color.clear, in: Rectangle())
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .onTapGesture { if isExpandable { onToggle() } }
    .accessibilityAddTraits(isExpandable ? .isButton : [])
  }

  /// Scalar text, or how many items a container holds
  private var preview: String {
    let node = line.node
    let count = node.children.count
    switch node.kind {
    case .array: return count == 1 ? "[1 item]" : "[\(count) items]"
    case .map: return count == 1 ? "{1 entry}" : "{\(count) entries}"
    case .message: return count == 1 ? "{1 field}" : "{\(count) fields}"
    default: return node.text ?? ""
    }
  }

  private var color: Color {
    switch line.node.kind {
    case .integer, .float, .varint, .fixed32, .fixed64: .gridNumber
    case .string: .gridString
    case .timestamp: .gridDate
    case .bool: .gridBoolean
    case .null, .array, .map, .message: .foregroundMuted
    case .binary, .ext: .gridForeground
    }
  }

  /// Same neutral capsule as the document tree's type badges
  private var badge: some View {
    Text(line.node.kind.rawValue)
      .font(.caption2)
      .foregroundColor(.foregroundMuted)
      .lineLimit(1)
      .padding(.horizontal, Spacing.xs)
      .background(Capsule().fill(Color.inputBackground))
      .overlay(Capsule().strokeBorder(Color.border, lineWidth: 1))
      .fixedSize()
  }
}
