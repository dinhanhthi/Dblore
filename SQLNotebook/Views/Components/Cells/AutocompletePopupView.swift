//
//  AutocompletePopupView.swift
//  SQLNotebook
//
//  Autocomplete popup that shows SQL suggestions (keywords, tables, columns)
//

import SwiftUI

// MARK: - Autocomplete Popup View

struct AutocompletePopupView: View {
  let suggestions: [AutocompleteSuggestion]
  let selectedIndex: Int
  let onSelect: (AutocompleteSuggestion) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
        AutocompleteSuggestionRow(
          suggestion: suggestion,
          isSelected: index == selectedIndex,
          onSelect: { onSelect(suggestion) }
        )
      }
    }
    .frame(maxWidth: 400)
    .background(Color.cellBackground)
    .cornerRadius(CornerRadius.sm)
    .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 2)
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.sm)
        .stroke(Color.foregroundSubtle.opacity(0.2), lineWidth: 1)
    )
  }
}

// MARK: - Suggestion Row

struct AutocompleteSuggestionRow: View {
  let suggestion: AutocompleteSuggestion
  let isSelected: Bool
  let onSelect: () -> Void

  @State private var isHovering = false

  var body: some View {
    HStack(spacing: Spacing.sm) {
      // Icon based on suggestion type
      Image(systemName: iconName)
        .font(.system(size: 12))
        .foregroundColor(iconColor)
        .frame(width: 16)

      // Suggestion text
      Text(suggestion.text)
        .font(.system(size: 13, design: .monospaced))
        .foregroundColor(.foreground)

      Spacer()

      // Description
      if let description = suggestion.description {
        Text(description)
          .font(.system(size: 11))
          .foregroundColor(.foregroundSubtle)
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .background(backgroundColor)
    .contentShape(Rectangle())
    .onTapGesture {
      onSelect()
    }
    .onHover { hovering in
      isHovering = hovering
    }
  }

  private var backgroundColor: Color {
    if isSelected {
      return Color.accent.opacity(0.15)
    } else if isHovering {
      return Color.accent.opacity(0.08)
    } else {
      return Color.clear
    }
  }

  private var iconName: String {
    switch suggestion.type {
    case .keyword:
      return "textformat"
    case .table:
      return "tablecells"
    case .column:
      return "list.bullet"
    }
  }

  private var iconColor: Color {
    switch suggestion.type {
    case .keyword:
      return .blue
    case .table:
      return .green
    case .column:
      return .orange
    }
  }
}

// MARK: - Previews

#Preview("Empty") {
  CellView(
    viewModel: NotebookViewModel(),
    cell: .constant(NotebookCell(cellType: .sql, content: "")),
    isSelected: true,
    onRun: {}
  )
  .padding()
  .frame(width: 700, height: 500, alignment: .top)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Autocomplete Popup") {
  AutocompletePopupView(
    suggestions: [
      AutocompleteSuggestion(text: "SELECT", type: .keyword, description: "SQL Keyword"),
      AutocompleteSuggestion(text: "users", type: .table, description: "Table (public)"),
      AutocompleteSuggestion(
        text: "id", type: .column(tableName: "users"), description: "INTEGER (public.users)"),
      AutocompleteSuggestion(
        text: "name", type: .column(tableName: "users"), description: "VARCHAR (public.users)"),
      AutocompleteSuggestion(
        text: "email", type: .column(tableName: "users"), description: "VARCHAR (public.users)"),
    ],
    selectedIndex: 1,
    onSelect: { _ in }
  )
  .padding()
  .frame(width: 500)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}
