//
//  CommandPaletteView.swift
//  Dblore
//
//  Search field and sectioned results, hosted by modalOverlay.
//

import AppKit
import SwiftUI

struct CommandPaletteView: View {
  @Bindable var model: CommandPaletteModel
  @Binding var isPresented: Bool
  var onPerform: (CommandPaletteItem) -> Bool
  var onFieldFocusChange: (Bool) -> Void

  @FocusState private var fieldFocused: Bool
  @State private var selectedID: String?
  /// Where focus was when the palette opened. Restored on Escape or a backdrop click.
  @State private var previousResponder = WeakResponder()
  @State private var didPerform = false

  var body: some View {
    VStack(spacing: 0) {
      searchField
      Divider()
      results
    }
    .frame(width: 520, height: 420)
    .background(Color.cardBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.xxl))
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.xxl)
        .stroke(Color.border.opacity(0.5), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 8)
    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
    .onAppear {
      if let responder = NSApp.keyWindow?.firstResponder as? NSView,
        !((responder as? NSTextView)?.isFieldEditor ?? false)
      {
        previousResponder.view = responder
      }
      selectedID = flatItems.first?.id
      // The overlay is installed on this turn. Focus the field on the next one.
      DispatchQueue.main.async {
        fieldFocused = true
      }
    }
    .onChange(of: fieldFocused) { _, focused in
      onFieldFocusChange(focused)
    }
    .onDisappear {
      guard !didPerform, let view = previousResponder.view else { return }
      // Escape releases the field editor on its own turn. Restore after it.
      DispatchQueue.main.async {
        guard let window = view.window, window.isKeyWindow else { return }
        window.makeFirstResponder(view)
      }
    }
    .onChange(of: model.ranked) { _, ranked in
      selectedID = ranked.first?.id ?? model.history.first?.id
    }
    .onChange(of: model.history) { _, _ in
      guard let selectedID, flatItems.contains(where: { $0.id == selectedID }) else {
        selectedID = flatItems.first?.id
        return
      }
    }
  }

  private var searchField: some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11))
        .foregroundColor(.foregroundSubtle)

      TextField("Search", text: $model.query)
        .textFieldStyle(.plain)
        .font(.small)
        .autocorrectionDisabled()
        .focused($fieldFocused)
        .onKeyPress(keys: [.upArrow, .downArrow, .return]) { press in
          handleKey(press)
        }

      if !model.query.isEmpty {
        Button {
          model.query = ""
          fieldFocused = true
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 11))
            .foregroundColor(.foregroundSubtle)
        }
        .buttonStyle(.plain)
        .help("Clear")
      }
    }
    .padding(.horizontal, Spacing.sm)
    .frame(maxWidth: .infinity)
    .frame(height: SidebarFilterMetrics.controlHeight)
    .background(Capsule().fill(Color.inputBackground))
    .overlay(Capsule().strokeBorder(Color.border, lineWidth: 1))
    .padding(Spacing.sm)
  }

  private var results: some View {
    ScrollViewReader { proxy in
      ScrollView {
        if model.showsNoMatches {
          Text("No matches")
            .font(.caption)
            .foregroundColor(.foregroundMuted)
            .frame(maxWidth: .infinity, minHeight: 120)
        } else {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(sections) { section in
              Text(section.title)
                .font(.caption)
                .foregroundColor(.foregroundMuted)
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.xxs)

              ForEach(section.items) { item in
                CommandPaletteRow(item: item, isSelected: item.id == activeID) {
                  activate(item)
                }
                .id(item.id)
              }
            }
          }
          .padding(.bottom, Spacing.sm)
        }
      }
      .scrollContentBackground(.hidden)
      .onChange(of: selectedID) { _, id in
        guard let id else { return }
        proxy.scrollTo(id)
      }
    }
  }

  /// Sections follow score order. The same kind can appear twice when a better
  /// row of another kind sits between them. Keyboard order is that same list.
  private var sections: [CommandPaletteSection] {
    var sections: [CommandPaletteSection] = []
    for item in model.ranked {
      let kind = CommandPaletteSection.Kind.of(item)
      if let last = sections.last, last.kind == kind {
        sections[sections.count - 1] = CommandPaletteSection(
          id: last.id, kind: kind, items: last.items + [item])
      } else {
        sections.append(
          CommandPaletteSection(id: "\(kind.rawValue)-\(sections.count)", kind: kind, items: [item])
        )
      }
    }
    if !model.history.isEmpty {
      sections.append(CommandPaletteSection(id: "history", kind: .history, items: model.history))
    }
    return sections
  }

  private var flatItems: [CommandPaletteItem] {
    model.ranked + model.history
  }

  /// The highlighted row. `selectedID` is reset in `onChange`, one render after the rows change,
  /// so an id that left the list falls back to the first row in the same pass.
  private var activeID: String? {
    let items = flatItems
    if let selectedID, items.contains(where: { $0.id == selectedID }) { return selectedID }
    return items.first?.id
  }

  /// Up, Down, and Return only. Cmd+K stays with the View menu.
  private func handleKey(_ press: KeyPress) -> KeyPress.Result {
    // Return commits an IME syllable. Do not run the highlighted row.
    if (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true {
      return .ignored
    }
    guard press.modifiers.intersection([.command, .shift, .option, .control]).isEmpty else {
      return .ignored
    }
    switch press.key {
    case .upArrow:
      moveSelection(by: -1)
    case .downArrow:
      moveSelection(by: 1)
    case .return:
      guard press.phase == .down else { return .handled }
      activateSelection()
    default:
      return .ignored
    }
    return .handled
  }

  private func moveSelection(by delta: Int) {
    let items = flatItems
    guard !items.isEmpty else { return }
    guard let activeID, let index = items.firstIndex(where: { $0.id == activeID }) else {
      self.selectedID = items[0].id
      return
    }
    let next = min(max(index + delta, 0), items.count - 1)
    self.selectedID = items[next].id
  }

  private func activateSelection() {
    guard let activeID, let item = flatItems.first(where: { $0.id == activeID }) else {
      return
    }
    activate(item)
  }

  /// Return and click both refuse a row left over from an older query.
  private func activate(_ item: CommandPaletteItem) {
    guard model.canPerform(item), onPerform(item) else { return }
    didPerform = true
    isPresented = false
  }
}

/// Weak so a closed tab's editor is not kept alive by the palette.
private final class WeakResponder {
  weak var view: NSView?
}

private struct CommandPaletteSection: Identifiable {
  let id: String
  let kind: Kind
  let items: [CommandPaletteItem]

  var title: String { kind.rawValue }

  enum Kind: String, CaseIterable {
    case tables = "Tables"
    case views = "Views"
    case functions = "Functions"
    case tabs = "Tabs"
    case favorite = "Favorite"
    case actions = "Actions"
    case history = "History"

    static func of(_ item: CommandPaletteItem) -> Kind {
      switch item {
      case .table: .tables
      case .view: .views
      case .function: .functions
      case .tab: .tabs
      case .favorite: .favorite
      case .action: .actions
      case .history: .history
      }
    }
  }
}

private struct CommandPaletteRow: View {
  let item: CommandPaletteItem
  let isSelected: Bool
  let onActivate: () -> Void

  @State private var isHovering = false

  var body: some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: iconName)
        .font(.system(size: 12))
        .foregroundColor(.accent)
        .frame(width: 16)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(titleText)
          .font(titleFont)
          .foregroundColor(.foreground)
          .lineLimit(1)

        if let detailText {
          Text(detailText)
            .font(.monoSmall)
            .foregroundColor(.foregroundSubtle)
            .lineLimit(1)
        }
      }

      Spacer(minLength: Spacing.sm)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.xs)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .background(
      isSelected
        ? Color.accent.opacity(0.15)
        : (isHovering ? Color.cellBackgroundHover.opacity(0.5) : Color.clear)
    )
    .onHover { isHovering = $0 }
    .onTapGesture(perform: onActivate)
  }

  private var iconName: String {
    switch item {
    case .table: "tablecells"
    case .view: "eye"
    case .function: "function"
    case .tab: "doc.text"
    case .favorite: "star"
    case .action: "command"
    case .history: "clock"
    }
  }

  private var titleFont: Font {
    switch item {
    case .history: .monoSmall
    case .tab, .action: .labelText
    default: .monoMedium
    }
  }

  private var titleText: String {
    collapsed(item.title)
  }

  private var detailText: String? {
    let raw: String?
    switch item {
    case .table(let schema, _), .view(let schema, _):
      raw = schema
    case .function(let schema, _, let arguments):
      if schema.isEmpty {
        raw = arguments.isEmpty ? nil : "(\(arguments))"
      } else if arguments.isEmpty {
        raw = schema
      } else {
        raw = "\(schema) (\(arguments))"
      }
    case .favorite(_, _, let sql):
      raw = sql
    case .tab, .action, .history:
      raw = nil
    }
    guard let raw else { return nil }
    let text = collapsed(raw)
    return text.isEmpty ? nil : text
  }

  private func collapsed(_ text: String) -> String {
    text.replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

extension View {
  /// Presents the command palette driven by `workspaceManager.commandPalette`.
  func commandPaletteModal(workspaceManager: WorkspaceManager) -> some View {
    let isPresented = Binding(
      get: { workspaceManager.commandPalette != nil },
      set: { presented in
        guard !presented else { return }
        workspaceManager.commandPalette = nil
        workspaceManager.commandPaletteFieldFocused = false
      }
    )
    return modalOverlay(isPresented: isPresented) {
      if let model = workspaceManager.commandPalette {
        CommandPaletteView(
          model: model,
          isPresented: isPresented,
          onPerform: { workspaceManager.perform($0) },
          onFieldFocusChange: { workspaceManager.commandPaletteFieldFocused = $0 }
        )
      }
    }
  }
}
