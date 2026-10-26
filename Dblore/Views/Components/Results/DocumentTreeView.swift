//
//  DocumentTreeView.swift
//  Dblore
//
//  Documents view of a MongoDB result (DocumentTreeModel): one card per document. The card
//  header is the document (`_id`, type badge, a hover toolbar and a context menu with Expand or
//  Collapse All, View Details, Copy, Duplicate and Delete or Revert); its lines are the fields as
//  `key: value`, nested documents and arrays collapsible and indented, large containers paged
//  with "show more".
//  When editable, a double-click edits a scalar inline (Return commits, Esc or focus loss
//  cancels) or hands any other value to `onEditField` (the editor sheet). Staged inserts follow
//  the stored documents as "New" cards; documents staged for deletion are dimmed and struck.
//  Without action closures the view is read-only.
//  An expansion request (the data viewer's Expand All / Collapse All) opens or closes every card;
//  a view built from scratch (a new page) applies the last request.
//

import AppKit
import SwiftUI

/// Expand or collapse every card of a `DocumentTreeView`; a new id is a new request.
struct DocumentTreeExpansionRequest: Equatable {
  let id = UUID()
  let expands: Bool
}

/// The cards of a MongoDB result. The documents are rebuilt off the main actor per result.
struct DocumentTreeView: View {
  let result: CellResult
  /// Editor and data viewer fill the panel; a notebook cell gets a height from its visible rows.
  var fillsAvailableHeight = false
  /// Lines can be edited with a double-click (also needs `onEditField`)
  var isEditable = false
  /// Staged insert documents, shown after the stored documents as "New" cards
  var stagedInserts: [MongoValue] = []
  /// Page rows whose document is staged for deletion
  var deletedRows: Set<Int> = []
  /// Card View Details: the row (document position) to show in Row Details
  var onShowDetails: ((Int) -> Void)? = nil
  /// Field Show Details: the row and the top-level field a line belongs to
  var onShowFieldDetails: ((_ row: Int, _ topLevelKey: String) -> Void)? = nil
  /// A field edit: inline text for `editType`, or nil text (and type) for the editor sheet
  var onEditField:
    (
      (_ row: Int, _ keys: [String], _ editType: String?, _ text: String?, _ current: MongoValue)
        -> Void
    )? = nil
  var onDuplicate: ((Int) -> Void)? = nil
  var onDelete: ((Int) -> Void)? = nil
  var onRevert: ((Int) -> Void)? = nil
  /// Expand or collapse every card; nil = none asked
  var expansionRequest: DocumentTreeExpansionRequest? = nil

  @State private var model: DocumentTreeModel?
  /// Stamp of the result `model` was built from
  @State private var modelStamp: ResultStamp?
  /// The line edited inline; one for the whole view
  @State private var editing: DocumentTreeNodeID?
  /// Text of the inline edit, and the text it started from
  @State private var draft = ""
  @State private var original = ""
  @FocusState private var focusedLine: DocumentTreeNodeID?

  /// The timestamp stands for the rows of one run, `dataRevision` for rows replaced within that
  /// run (the inline edit refresh).
  private struct ResultStamp: Equatable {
    var timestamp: Date
    var dataRevision: Int
  }

  private var resultStamp: ResultStamp {
    ResultStamp(timestamp: result.timestamp, dataRevision: result.dataRevision)
  }

  private static let cardSpacing = Spacing.sm
  private static let listPadding = Spacing.sm

  /// The shown cards were built from an earlier result (a rebuild is running): they stay drawn,
  /// with the scroll position, but offer no edit, details or staging action, since their rows
  /// may no longer match the result's.
  private var isStale: Bool { modelStamp != resultStamp }

  var body: some View {
    Group {
      if let model {
        cardList(model.cards)
      } else {
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil)
          .frame(height: fillsAvailableHeight ? nil : Self.height(cards: []))
      }
    }
    .task(id: resultStamp) { await build() }
    .onChange(of: stagedInserts) { _, inserts in model?.setStagedInserts(inserts) }
    .onChange(of: expansionRequest) { _, request in
      if let request { apply(request) }
    }
    // Focus leaving the edited line cancels it; a move to another edited line does not
    .onChange(of: focusedLine) { old, new in
      if let editing, old == editing, new != editing { self.editing = nil }
    }
    // The workspace key monitor takes Esc from a focused text view and posts this instead
    .onReceive(NotificationCenter.default.publisher(for: .unfocusEditor)) { _ in
      if let editing, focusedLine == editing { self.editing = nil }
    }
  }

  private func build() async {
    editing = nil
    let stamp = resultStamp
    let columns = result.columns
    let rows = result.rows
    // Expansion and paging carry over by position (e.g. the reload after an edit)
    let previous = model
    let inserts = stagedInserts
    let built = await Task.detached(priority: .userInitiated) {
      var built = DocumentTreeModel(columns: columns, rows: rows, carrying: previous)
      if !inserts.isEmpty { built.setStagedInserts(inserts) }
      return built
    }.value
    guard !Task.isCancelled else { return }
    model = built
    modelStamp = stamp
    if inserts != stagedInserts { model?.setStagedInserts(stagedInserts) }
    // Nothing carried over (a new page): the cards follow the last Expand / Collapse All
    if previous == nil, let expansionRequest { apply(expansionRequest) }
  }

  private func apply(_ request: DocumentTreeExpansionRequest) {
    editing = nil
    if request.expands {
      model?.expandAllDocuments()
    } else {
      model?.collapseAllDocuments()
    }
  }

  /// Fixed notebook height: the visible lines plus the gaps between their cards, at most as many
  /// lines as a grid shows.
  private static func height(cards: [DocumentTreeCard]) -> CGFloat {
    let lines = cards.reduce(0) { $0 + $1.nodes.count }
    let content =
      ResultGridView.rowsHeight(rowCount: max(1, lines))
      + CGFloat(max(0, cards.count - 1)) * cardSpacing
    let cap = ResultGridView.rowsHeight(rowCount: ResultGridView.maxVisibleRows)
    return min(content, cap) + listPadding * 2
  }

  private func cardList(_ cards: [DocumentTreeCard]) -> some View {
    ScrollView(.vertical) {
      LazyVStack(alignment: .leading, spacing: Self.cardSpacing) {
        ForEach(cards) { card in
          cardView(card)
        }
      }
      .padding(Self.listPadding)
    }
    .frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil)
    .frame(height: fillsAvailableHeight ? nil : Self.height(cards: cards))
    // One step under the cards, so each document reads as its own surface
    .background(Color.appBackground)
  }

  // MARK: - Card

  /// A raised card on the list background, with a stronger border and a header band while open,
  /// so neighbouring documents stay apart
  private func cardView(_ card: DocumentTreeCard) -> some View {
    let shape = RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
    let isDeleted = deletedRows.contains(card.document)
    return VStack(alignment: .leading, spacing: 0) {
      if let header = card.nodes.first {
        DocumentCardHeader(
          node: header,
          isStaged: card.isStaged,
          isDeleted: isDeleted,
          actions: cardActions(card, header: header, includesCopy: true),
          onToggle: { model?.toggleExpansion(header.id) },
          onDoubleClick: doubleClickAction(header, card: card)
        )
        .background(header.isExpanded ? Color.cardHeaderBackground : .clear, in: Rectangle())
        if header.isExpanded, card.nodes.count > 1 {
          Rectangle().fill(Color.border).frame(height: 1)
        }
      }
      ForEach(card.nodes.dropFirst()) { node in
        line(node, card: card)
      }
    }
    .background(Color.cellBackground, in: shape)
    .clipShape(shape)
    .overlay(HairlineBorder(shape: shape, color: .borderStrong))
    .opacity(isDeleted ? 0.5 : 1)
  }

  private func line(_ node: DocumentTreeNode, card: DocumentTreeCard) -> some View {
    let showsFieldDetails =
      !isStale && !card.isStaged && onShowFieldDetails != nil && node.kind == .value
      && !node.keys.isEmpty
    return DocumentTreeRow(
      node: node,
      draft: $draft,
      isEditing: editing == node.id,
      focus: $focusedLine,
      cardActions: cardActions(card, header: nil, includesCopy: false),
      onToggle: { model?.toggleExpansion(node.id) },
      onShowMore: { model?.showMore(node.id) },
      onCopy: { copy($0, node: node) },
      onShowDetails: showsFieldDetails
        ? { onShowFieldDetails?(card.document, node.keys[0]) } : nil,
      onDoubleClick: doubleClickAction(node, card: card),
      onCommit: commitEdit,
      onCancel: { editing = nil }
    )
  }

  /// Toolbar and context menu entries of a card. Copy Document is left out of a line's menu,
  /// which has it already. Stale cards only copy.
  private func cardActions(
    _ card: DocumentTreeCard, header: DocumentTreeNode?, includesCopy: Bool
  ) -> [DocumentCardAction] {
    let row = card.document
    var actions: [DocumentCardAction] = []
    // View only: opens or closes every nested document and array of the card
    if card.nodes.first?.isExpandable == true {
      if model?.isFullyExpanded(document: row) == true {
        actions.append(
          DocumentCardAction(title: "Collapse All", systemImage: "rectangle.compress.vertical") {
            model?.collapseAll(document: row)
          })
      } else {
        actions.append(
          DocumentCardAction(title: "Expand All", systemImage: "rectangle.expand.vertical") {
            model?.expandAll(document: row)
          })
      }
    }
    if !isStale, !card.isStaged, let onShowDetails {
      actions.append(
        DocumentCardAction(
          title: "View Details", systemImage: "arrow.up.left.and.arrow.down.right"
        ) { onShowDetails(row) })
    }
    if includesCopy, let header {
      actions.append(
        DocumentCardAction(
          title: "Copy Document as Extended JSON", systemImage: "doc.on.clipboard"
        ) { copy(.document, node: header) })
      actions.append(
        DocumentCardAction(
          title: "Copy Document as mongosh", systemImage: "chevron.left.forwardslash.chevron.right"
        ) { copy(.mongoshDocument, node: header) })
    }
    guard !isStale else { return actions }
    if let onDuplicate {
      actions.append(
        DocumentCardAction(title: "Duplicate", systemImage: "doc.on.doc") { onDuplicate(row) })
    }
    if deletedRows.contains(row) {
      if let onRevert {
        actions.append(
          DocumentCardAction(title: "Revert", systemImage: "arrow.uturn.backward") {
            onRevert(row)
          })
      }
    } else if let onDelete {
      actions.append(
        DocumentCardAction(title: "Delete", systemImage: "trash") { onDelete(row) })
    }
    return actions
  }

  // MARK: - Edit

  /// What a double-click on `node` does; nil when it does nothing. A staged card opens its
  /// editor sheet from any line; a stored line edits a scalar inline, or opens the sheet for any
  /// other value.
  private func doubleClickAction(
    _ node: DocumentTreeNode, card: DocumentTreeCard
  ) -> (() -> Void)? {
    guard isEditable, !isStale, let onEditField, node.kind == .value,
      !deletedRows.contains(card.document)
    else { return nil }
    let row = card.document
    if card.isStaged {
      let header = DocumentTreeNodeID(document: row, indexes: [])
      return {
        onEditField(row, [], nil, nil, model?.currentValue(header) ?? .document([]))
      }
    }
    guard let first = node.keys.first, first != "_id" else { return nil }
    return { startEdit(node, row: row) }
  }

  private func startEdit(_ node: DocumentTreeNode, row: Int) {
    guard let model, let current = model.currentValue(node.id) else { return }
    guard node.editType != nil, let text = model.editText(node.id) else {
      onEditField?(row, node.keys, nil, nil, current)
      return
    }
    draft = text
    original = text
    // The field focuses itself once it is shown (`onAppear`)
    editing = node.id
  }

  /// Return in the inline field: the edit ends first, then a changed text goes to `onEditField`.
  private func commitEdit() {
    guard let id = editing else { return }
    editing = nil
    guard !isStale, draft != original, let model, let current = model.currentValue(id),
      let node = model.cards.first(where: { $0.document == id.document })?.nodes.first(where: {
        $0.id == id
      })
    else { return }
    onEditField?(id.document, node.keys, node.editType, draft, current)
  }

  private func copy(_ action: DocumentTreeRow.CopyAction, node: DocumentTreeNode) {
    guard let model else { return }
    let text: String? =
      switch action {
      case .value: model.copyValueText(node.id)
      case .path: model.copyPathText(node.id)
      case .document: model.copyDocumentText(node.id)
      case .mongoshDocument: model.copyDocumentText(node.id, format: .mongosh)
      }
    guard let text else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

/// A card toolbar button and context menu item.
private struct DocumentCardAction: Identifiable {
  let title: String
  let systemImage: String
  let perform: () -> Void

  var id: String { title }
}

// MARK: - Shared look

private enum DocumentLine {
  static let indentWidth: CGFloat = 16
  static let disclosureWidth: CGFloat = 12

  static var font: Font {
    .system(size: AppSettings.shared.resultFontSize, design: .monospaced)
  }

  static func disclosure(_ node: DocumentTreeNode) -> some View {
    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
      .font(.system(size: 9, weight: .semibold))
      .foregroundColor(.foregroundMuted)
      .frame(width: disclosureWidth)
      .opacity(node.isExpandable ? 1 : 0)
      .accessibilityHidden(!node.isExpandable)
  }

  /// Same neutral capsule as the history row badges
  static func badge(_ text: String) -> some View {
    Text(text)
      .font(.caption2)
      .foregroundColor(.foregroundMuted)
      .lineLimit(1)
      .padding(.horizontal, Spacing.xs)
      .background(Capsule().fill(Color.inputBackground))
      .overlay(Capsule().strokeBorder(Color.border, lineWidth: 1))
      .fixedSize()
  }

  static func previewColor(_ node: DocumentTreeNode) -> Color {
    switch node.typeName {
    case "int", "long", "double", "decimal": .gridNumber
    case "string", "objectId": .gridString
    case "date", "timestamp": .gridDate
    case "bool": .gridBoolean
    case "object", "array": .foregroundMuted
    default: .gridForeground
    }
  }
}

extension View {
  /// A single click and a double-click (when given), told apart by the event's click count, so a
  /// click acts at once instead of waiting out the double-click interval. The second click of a
  /// double-click runs `onClick` again, undoing the first one's toggle (a double-clicked card or
  /// container keeps its state), then `onDoubleClick`.
  fileprivate func documentClicks(
    onDoubleClick: (() -> Void)?, onClick: @escaping () -> Void
  ) -> some View {
    onTapGesture {
      // `clickCount` exists on mouse events only
      let event = NSApp.currentEvent
      let isMouse = event?.type == .leftMouseUp || event?.type == .leftMouseDown
      switch isMouse ? event?.clickCount ?? 1 : 1 {
      case 1:
        onClick()
      case 2:
        onClick()
        onDoubleClick?()
      default:
        break
      }
    }
  }
}

// MARK: - Header

/// The first line of a card: the document's `_id`, its type and the card actions.
private struct DocumentCardHeader: View {
  let node: DocumentTreeNode
  let isStaged: Bool
  let isDeleted: Bool
  let actions: [DocumentCardAction]
  let onToggle: () -> Void
  let onDoubleClick: (() -> Void)?
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: Spacing.xs) {
      DocumentLine.disclosure(node)
      Text(node.key)
        .font(DocumentLine.font.weight(.medium))
        .foregroundColor(.gridForeground)
        .strikethrough(isDeleted)
        .lineLimit(1)
        .truncationMode(.tail)
        .layoutPriority(1)
      Text(node.preview)
        .font(DocumentLine.font)
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
      if isStaged { newMarker }
      Spacer(minLength: Spacing.sm)
      // The badge stays rightmost; the hover toolbar takes room from the `_id` text, which
      // truncates
      if isHovered { toolbar }
      DocumentLine.badge(node.typeName)
    }
    .padding(.horizontal, Spacing.sm)
    .frame(height: ResultGridView.rowHeight)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(isHovered ? Color.hoverFill : Color.clear, in: Rectangle())
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    // A click collapses or expands the card
    .documentClicks(onDoubleClick: onDoubleClick, onClick: onToggle)
    .contextMenu {
      ForEach(actions) { action in
        Button(action.title, action: action.perform)
      }
    }
  }

  /// Same tint as a staged insert row in the grid
  private var newMarker: some View {
    Text("New")
      .font(.caption2)
      .foregroundColor(.success)
      .lineLimit(1)
      .padding(.horizontal, Spacing.xs)
      .background(Capsule().fill(Color.success.opacity(0.14)))
      .fixedSize()
  }

  /// Icon buttons shown while the header is hovered, left of the type badge
  private var toolbar: some View {
    HStack(spacing: Spacing.xxs) {
      ForEach(actions) { action in
        Button(action: action.perform) {
          Image(systemName: action.systemImage)
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true, vPadding: Spacing.xxs))
        .controlSize(.small)
        .help(action.title)
        .accessibilityLabel(action.title)
      }
    }
    .fixedSize()
  }
}

// MARK: - Line

/// One field or item line: disclosure, `key:`, value preview (or the inline edit field), type
/// badge; or a "show more" link.
private struct DocumentTreeRow: View {
  enum CopyAction {
    case value, path, document, mongoshDocument
  }

  let node: DocumentTreeNode
  @Binding var draft: String
  let isEditing: Bool
  var focus: FocusState<DocumentTreeNodeID?>.Binding
  /// Card entries for the context menu, after the line's own
  let cardActions: [DocumentCardAction]
  let onToggle: () -> Void
  let onShowMore: () -> Void
  let onCopy: (CopyAction) -> Void
  /// Cell Info of the line's top-level field; nil hides the button and menu item
  let onShowDetails: (() -> Void)?
  let onDoubleClick: (() -> Void)?
  let onCommit: () -> Void
  let onCancel: () -> Void
  @State private var isHovered = false

  var body: some View {
    if isEditing {
      editingLine
    } else {
      HStack(spacing: Spacing.xs) {
        indent
        switch node.kind {
        case .value: valueContent
        case .showMore(let remaining): showMoreButton(remaining: remaining)
        }
      }
      .padding(.horizontal, Spacing.sm)
      .frame(height: ResultGridView.rowHeight)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(isHovered && node.kind == .value ? Color.hoverFill : Color.clear, in: Rectangle())
      .contentShape(Rectangle())
      .onHover { isHovered = $0 }
      // A click on a document or array line expands or collapses it
      .documentClicks(onDoubleClick: onDoubleClick) { if node.isExpandable { onToggle() } }
      .contextMenu { if node.kind == .value { menu } }
    }
  }

  /// Top-level fields line up under the card's disclosure; deeper lines indent per level.
  private var indent: some View {
    Color.clear
      .frame(width: CGFloat(max(0, node.depth - 1)) * DocumentLine.indentWidth)
  }

  @ViewBuilder
  private var menu: some View {
    Button("Copy Value") { onCopy(.value) }
    if !node.path.isEmpty {
      Button("Copy Path") { onCopy(.path) }
    }
    Button("Copy Document as Extended JSON") { onCopy(.document) }
    Button("Copy Document as mongosh") { onCopy(.mongoshDocument) }
    if let onShowDetails {
      Button("Show Details", action: onShowDetails)
    }
    if !cardActions.isEmpty {
      Divider()
      ForEach(cardActions) { action in
        Button(action.title, action: action.perform)
      }
    }
  }

  @ViewBuilder
  private var valueContent: some View {
    DocumentLine.disclosure(node)
    keyLabel
    Text(node.preview)
      .font(DocumentLine.font)
      .foregroundColor(DocumentLine.previewColor(node))
      .lineLimit(1)
      .truncationMode(.tail)
    Spacer(minLength: Spacing.sm)
    if let onShowDetails { detailsButton(onShowDetails) }
    DocumentLine.badge(node.typeName)
  }

  private var keyLabel: some View {
    HStack(spacing: 0) {
      Text(node.key)
        .foregroundColor(.gridForeground)
      Text(":")
        .foregroundColor(.foregroundMuted)
    }
    .font(DocumentLine.font)
    .lineLimit(1)
    .layoutPriority(1)
  }

  /// Subtle hover button, like the grid's cell details button
  private func detailsButton(_ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: "arrow.up.left.and.arrow.down.right")
    }
    .buttonStyle(GhostButtonStyle(iconOnly: true, vPadding: Spacing.xxs))
    .controlSize(.mini)
    .help("Show details")
    .accessibilityLabel("Show details")
    .opacity(isHovered ? 1 : 0)
    .allowsHitTesting(isHovered)
  }

  /// The line with the inline text field in place of the value. Return commits (Option-Return
  /// adds a line), Esc cancels; the view cancels on focus loss.
  private var editingLine: some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
      indent
      DocumentLine.disclosure(node)
      keyLabel
      TextField("", text: $draft, axis: .vertical)
        .textFieldStyle(.plain)
        .font(DocumentLine.font)
        .foregroundColor(.foreground)
        .lineLimit(1...6)
        .focused(focus, equals: node.id)
        .onSubmit(onCommit)
        // A vertical text field's text view takes Esc before `onExitCommand` sees it
        .onKeyPress(.escape) {
          onCancel()
          return .handled
        }
        .onAppear { focus.wrappedValue = node.id }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs)
        .background(
          Color.inputBackground,
          in: RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
        )
        .overlay(
          HairlineBorder(
            shape: RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous),
            color: .borderFocus)
        )
        .accessibilityLabel("Value of \(node.key)")
      DocumentLine.badge(node.typeName)
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xxs)
    .frame(minHeight: ResultGridView.rowHeight)
    .frame(maxWidth: .infinity, alignment: .leading)
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
    .padding(.leading, DocumentLine.disclosureWidth + Spacing.xs)
  }
}
