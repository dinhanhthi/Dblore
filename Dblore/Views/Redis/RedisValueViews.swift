//
//  RedisValueViews.swift
//  Dblore
//
//  A Redis key tab's value, under its header: a string's first 256 KiB as Text, Hex or (when
//  complete valid JSON) JSON, in a read-only text view; a hash, list, set, sorted set or stream
//  as rows (field / value, index / element, member, member / score, entry id / fields) in a
//  lazy list with "Load more". Until the first page arrives a placeholder of the same shape,
//  its spinner fading in after 150 ms. Everything shown was escaped and cut off the main thread
//  (`RedisKeyViewerModel`); server text is plain text only, never Markdown or links.
//  With `actions` (a connection that is not read-only) the string gets Edit, the rows their edit
//  and remove icons, and the footer an Add button; which ones depends on the type (a list element
//  is never removed, a stream entry never edited).
//

import AppKit
import SwiftUI

/// What the value view offers to change; nil on a read-only connection (nothing is offered)
struct RedisValueActions {
  /// Edit the whole string; nil when it cannot be edited here (`editStringNote` says why)
  var editString: (() -> Void)?
  var editStringNote: String?
  /// Add a field, element, member or entry
  var add: () -> Void
  /// Edit a hash field's value, a list element, a sorted-set member's score
  var edit: (RedisKeyViewerModel.ValueRow) -> Void
  /// Remove a hash field, set or sorted-set member, or stream entry (asked first)
  var remove: (RedisKeyViewerModel.ValueRow) -> Void
}

struct RedisValueView: View {
  let values: RedisKeyViewerModel.Values
  /// Changes with each load: resets the string's tab and restarts the placeholder's spinner
  let loadID: UUID
  let onLoadMore: () -> Void
  var actions: RedisValueActions?

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color.appBackground)
      .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
      .overlay(HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.md)))
  }

  @ViewBuilder
  private var content: some View {
    switch values {
    case .loading:
      RedisValuePlaceholder(loadID: loadID)
    case .string(let value):
      RedisStringValueView(value: value, actions: actions).id(loadID)
    case .rows(let list) where list.rows.isEmpty && list.isLoadingMore:
      RedisValuePlaceholder(loadID: loadID)
    case .rows(let list):
      RedisRowListView(list: list, onLoadMore: onLoadMore, actions: actions)
    case .unsupported:
      RedisValueNote(
        icon: "questionmark.square.dashed", color: .foregroundMuted,
        title: "No view for this type", text: "Use a command tab to read this key.")
    case .failed(let message):
      RedisValueNote(
        icon: "exclamationmark.triangle", color: .destructive, title: "Could not read the value",
        text: message)
    }
  }
}

// MARK: - String

private struct RedisStringValueView: View {
  let value: RedisKeyViewerModel.StringValue
  let actions: RedisValueActions?

  @State private var mode: Mode = .text

  enum Mode: Hashable {
    case text, hex, json

    var title: String {
      switch self {
      case .text: "Text"
      case .hex: "Hex"
      case .json: "JSON"
      }
    }
  }

  private var modes: [Mode] { value.json == nil ? [.text, .hex] : [.text, .hex, .json] }

  private var shownText: String {
    switch mode {
    case .text: value.text
    case .hex: value.hex
    case .json: value.json ?? value.text
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: Spacing.sm) {
        CapsuleTabPicker(selection: $mode, tabs: modes, height: 28) { tab in
          CapsuleTabLabel(text: tab.title, isSelected: mode == tab)
        }
        .fitsContent()
        .accessibilityLabel("Value view")
        .help("Text: the value as text. Hex: its bytes. JSON: the value indented.")
        Spacer(minLength: Spacing.sm)
        if let note {
          Text(verbatim: note)
            .font(.small)
            .foregroundColor(.foregroundMuted)
            .lineLimit(1)
        }
        if let actions {
          Button("Edit") { actions.editString?() }
            .buttonStyle(SecondaryButtonStyle(vPadding: Spacing.xs))
            .disabled(actions.editString == nil)
            .help(actions.editStringNote ?? "Edit the value (SET … KEEPTTL XX keeps the TTL)")
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
      Rectangle().fill(Color.border).frame(height: 1)
      RedisPlainTextView(text: shownText, version: mode.title)
    }
  }

  /// Says the value was cut, and how long it is when known
  private var note: String? {
    guard !value.isComplete else { return nil }
    let preview = "\(RedisKeyCommands.valuePreviewBytes / 1_024) KiB"
    if let length = value.length, length > value.bytes.count {
      return "Showing the first \(preview) of \(RedisKeyViewerModel.lengthText(length))"
    }
    return "Showing the first \(preview); the value may be longer"
  }
}

/// Read-only, selectable monospaced plain text, with no rich text, link or data detection.
/// `version` changes with the text, so an update compares it instead of the (large) text.
private struct RedisPlainTextView: NSViewRepresentable {
  let text: String
  let version: String

  final class Coordinator {
    var version: String?
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    scrollView.drawsBackground = false
    scrollView.autohidesScrollers = true
    guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.importsGraphics = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.isAutomaticDataDetectionEnabled = false
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.drawsBackground = false
    textView.font = ResultGridCoordinator.font
    textView.textColor = NSColor(Color.foreground)
    textView.textContainerInset = NSSize(width: Spacing.sm, height: Spacing.sm)
    textView.string = text
    context.coordinator.version = version
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard context.coordinator.version != version,
      let textView = scrollView.documentView as? NSTextView
    else { return }
    textView.string = text
    textView.scrollToBeginningOfDocument(nil)
    context.coordinator.version = version
  }
}

// MARK: - Rows

private struct RedisRowListView: View {
  let list: RedisKeyViewerModel.RowList
  let onLoadMore: () -> Void
  let actions: RedisValueActions?

  private typealias Model = RedisKeyViewerModel

  /// The first column's title and width, and the second's title (nil: one column)
  private var columns: (name: String, width: CGFloat, value: String?) {
    switch list.kind {
    case .hash: ("Field", 260, "Value")
    case .list: ("Index", 80, "Element")
    case .sortedSet: ("Member", 260, "Score")
    case .stream: ("Entry ID", 200, "Fields")
    default: ("Member", 260, nil)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      columnHeader
      Rectangle().fill(Color.border).frame(height: 1)
      if list.rows.isEmpty {
        Text(list.isCapped ? "This value is too large to show here." : "No items.")
          .font(.small)
          .foregroundColor(.foregroundMuted)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(0..<list.rows.count, id: \.self) { index in
          RedisValueRowView(
            row: list.rows[index], nameWidth: columns.value == nil ? nil : columns.width,
            isIndex: list.kind == .list, valueLines: list.kind == .stream ? 6 : 1,
            onEdit: editAction(list.rows[index]), onRemove: removeAction(list.rows[index])
          )
          .listRowInsets(EdgeInsets(top: 0, leading: Spacing.md, bottom: 0, trailing: Spacing.md))
          .listRowSeparator(.hidden)
          .listRowBackground(index.isMultiple(of: 2) ? Color.clear : Color.tableRowAlternate)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 22)
      }
      Rectangle().fill(Color.border).frame(height: 1)
      footer
    }
  }

  /// A hash field's value, a list element and a sorted-set score are edited; a stream entry
  /// never (a new id would replace it), a set member is only added or removed
  private func editAction(_ row: Model.ValueRow) -> (() -> Void)? {
    guard let actions, [Model.KeyType.hash, .list, .sortedSet].contains(list.kind) else {
      return nil
    }
    return { actions.edit(row) }
  }

  /// A list element is never removed (by index, another client's push would remove another)
  private func removeAction(_ row: Model.ValueRow) -> (() -> Void)? {
    guard let actions, list.kind != .list else { return nil }
    return { actions.remove(row) }
  }

  private var addTitle: String {
    switch list.kind {
    case .hash: "Add Field"
    case .list: "Add Element"
    case .stream: "Add Entry"
    default: "Add Member"
    }
  }

  private var columnHeader: some View {
    HStack(spacing: Spacing.sm) {
      if let value = columns.value {
        Text(columns.name).frame(width: columns.width, alignment: .leading)
        Text(value).frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Text(columns.name).frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .font(.small.weight(.semibold))
    .foregroundColor(.foregroundMuted)
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.xs)
    .background(Color.tableHeaderBackground)
  }

  private var footer: some View {
    HStack(spacing: Spacing.sm) {
      Text(verbatim: list.rows.count == 1 ? "1 row" : "\(list.rows.count.formatted()) rows")
        .font(.small)
        .foregroundColor(.foregroundMuted)
      if list.isCapped {
        Text("This tab's limit. Use a command tab to read the rest.")
          .font(.small)
          .foregroundColor(.warning)
          .lineLimit(1)
      }
      if let error = list.moreError {
        Text(verbatim: error)
          .font(.small)
          .foregroundColor(.destructive)
          .lineLimit(1)
          .textSelection(.enabled)
          .help(error)
      }
      Spacer(minLength: Spacing.sm)
      if list.isLoadingMore {
        DelayedSpinner()
      }
      if list.next != nil {
        Button("Load more", action: onLoadMore)
          .buttonStyle(SecondaryButtonStyle(vPadding: Spacing.xs))
          .disabled(list.isLoadingMore)
          .help("Read the next \(Model.pageSize) rows")
      }
      if let actions {
        Button(action: actions.add) {
          Label(addTitle, systemImage: "plus")
        }
        .buttonStyle(SecondaryButtonStyle(vPadding: Spacing.xs))
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.xs)
    .frame(minHeight: 32)
  }
}

private struct RedisValueRowView: View {
  let row: RedisKeyViewerModel.ValueRow
  /// nil: the name is the only column
  let nameWidth: CGFloat?
  let isIndex: Bool
  let valueLines: Int
  var onEdit: (() -> Void)?
  var onRemove: (() -> Void)?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
      cells
      if let onEdit {
        Button(action: onEdit) {
          Image(systemName: "pencil")
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .controlSize(.small)
        .help(isIndex ? "Edit this element" : "Edit")
        .accessibilityLabel("Edit")
      }
      if let onRemove {
        Button(action: onRemove) {
          Image(systemName: "trash")
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .controlSize(.small)
        .help("Remove")
        .accessibilityLabel("Remove")
      }
    }
    .padding(.vertical, 3)
  }

  @ViewBuilder
  private var cells: some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
      if let value = row.value, let nameWidth {
        name.frame(width: nameWidth, alignment: .leading)
        Text(verbatim: value)
          .font(.monoMedium)
          .foregroundColor(.gridForeground)
          .lineLimit(valueLines)
          .truncationMode(.tail)
          .textSelection(.enabled)
          .help(value)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        name.frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var name: some View {
    Text(verbatim: row.name)
      .font(.monoMedium)
      .foregroundColor(isIndex ? .foregroundMuted : .gridForeground)
      .lineLimit(1)
      .truncationMode(.tail)
      .textSelection(.enabled)
      .help(row.name)
  }
}

// MARK: - Placeholder and notes

/// The rows' shape with bars, and a spinner after 150 ms
private struct RedisValuePlaceholder: View {
  let loadID: UUID

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        bar(width: 72)
        Spacer(minLength: 0)
        // Restarts its delay with each load (a new key in the same tab)
        DelayedSpinner().id(loadID)
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.xs)
      .frame(minHeight: 28)
      .background(Color.tableHeaderBackground)
      Rectangle().fill(Color.border).frame(height: 1)
      ForEach(0..<8, id: \.self) { index in
        HStack(spacing: Spacing.sm) {
          bar(width: 160)
          bar(width: index.isMultiple(of: 2) ? 240 : 180)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.md)
        .frame(height: 22)
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading the value")
  }

  private func bar(width: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: CornerRadius.sm)
      .fill(Color.foregroundMuted.opacity(0.15))
      .frame(width: width, height: 11)
  }
}

private struct RedisValueNote: View {
  let icon: String
  let color: Color
  let title: String
  let text: String

  var body: some View {
    HStack(alignment: .center, spacing: Spacing.sm) {
      Image(systemName: icon)
        .foregroundColor(color)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(title)
          .font(.small.weight(.semibold))
          .foregroundColor(.foreground)
        Text(verbatim: text)
          .font(.small)
          .foregroundColor(.foregroundMuted)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(Spacing.md)
  }
}
