//
//  SearchPanelView.swift
//  SQLNotebook
//
//

import SwiftUI

/// Floating search panel (top-right corner, overlay style)
struct SearchPanelView: View {
  @Bindable var viewModel: NotebookViewModel
  @FocusState private var isSearchFieldFocused: Bool

  // MARK: - Computed Properties for Schema/Normal Search

  private var isSchemaSearch: Bool {
    viewModel.isSchemaVisualizerActive
  }

  private var searchPlaceholder: String {
    if isSchemaSearch {
      return "Search in schema..."
    }
    return viewModel.viewMode == .editor ? "Search in editor..." : "Search in notebook..."
  }

  private var currentQuery: Binding<String> {
    if isSchemaSearch {
      return $viewModel.schemaSearchState.query
    }
    return $viewModel.searchState.query
  }

  private var isCaseSensitive: Bool {
    if isSchemaSearch {
      return viewModel.schemaSearchState.isCaseSensitive
    }
    return viewModel.searchState.isCaseSensitive
  }

  private var isSearching: Bool {
    if isSchemaSearch {
      return viewModel.schemaSearchState.isSearching
    }
    return viewModel.searchState.isSearching
  }

  private var queryIsEmpty: Bool {
    if isSchemaSearch {
      return viewModel.schemaSearchState.query.isEmpty
    }
    return viewModel.searchState.query.isEmpty
  }

  private var matchesIsEmpty: Bool {
    if isSchemaSearch {
      return viewModel.schemaSearchState.matches.isEmpty
    }
    return viewModel.searchState.matches.isEmpty
  }

  private var matchCountText: String {
    if isSchemaSearch {
      return viewModel.schemaSearchState.matchCountText
    }
    return viewModel.searchState.matchCountText
  }

  var body: some View {
    HStack(spacing: Spacing.sm) {
      // Search icon
      Image(systemName: "magnifyingglass")
        .foregroundColor(.foregroundMuted)
        .font(.system(size: 14))

      // Search text field
      TextField(searchPlaceholder, text: currentQuery)
        .textFieldStyle(.plain)
        .font(.bodyText)
        .focused($isSearchFieldFocused)
        .onChange(of: currentQuery.wrappedValue) { _, newValue in
          // Debounce search
          Task {
            try? await Task.sleep(for: .milliseconds(300))
            if currentQuery.wrappedValue == newValue {
              await performSearch(query: newValue)
            }
          }
        }
        .onSubmit {
          // Enter key navigates to next match (like Cmd+G)
          navigateToNextMatch()
        }

      // Match counter
      if isSearching {
        ProgressView()
          .scaleEffect(0.6)
          .frame(width: 12, height: 12)
      } else if !queryIsEmpty {
        // Show match count when there's a query (even if 0 results)
        Text(matchesIsEmpty ? "0 found" : matchCountText)
          .font(.caption)
          .foregroundColor(.foregroundSubtle)
          .padding(.horizontal, Spacing.xs)
      }

      Divider()
        .frame(height: 20)

      // Navigation buttons
      Button {
        navigateToPreviousMatch()
      } label: {
        Image(systemName: "chevron.up")
          .font(.system(size: 12))
      }
      .buttonStyle(ToolbarButtonStyle(iconOnly: true))
      .disabled(matchesIsEmpty)

      Button {
        navigateToNextMatch()
      } label: {
        Image(systemName: "chevron.down")
          .font(.system(size: 12))
      }
      .buttonStyle(ToolbarButtonStyle(iconOnly: true))
      .disabled(matchesIsEmpty)

      Divider()
        .frame(height: 20)

      // Case sensitivity toggle
      Button {
        toggleCaseSensitive()
      } label: {
        Image(systemName: "textformat")
          .font(.system(size: 14))
      }
      .buttonStyle(
        ToolbarButtonStyle(
          isActive: isCaseSensitive,
          iconOnly: true
        )
      )
      .help("Case sensitive")

      // Close button
      Button {
        viewModel.closeSearch()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 12))
      }
      .buttonStyle(ToolbarButtonStyle(iconOnly: true))
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .fill(Color.cardBackground.opacity(0.98))
    )
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .strokeBorder(Color.accent.opacity(0.3), lineWidth: 1.5)
    )
    .shadow(color: Color.accent.opacity(0.3), radius: 8, x: 0, y: 4)
    .frame(maxWidth: .infinity)
    .onAppear {
      // Auto-focus search field when panel appears
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        isSearchFieldFocused = true
      }
    }
    .onChange(of: viewModel.isSearchPanelVisible) { _, isVisible in
      // Re-focus when panel becomes visible
      if isVisible {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          isSearchFieldFocused = true
        }
      }
    }
    .onChange(of: viewModel.searchFocusTrigger) { _, _ in
      // Re-focus when trigger changes (Cmd+F pressed while panel already visible)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        isSearchFieldFocused = true
      }
    }
    .onKeyPress(.escape) {
      // Close search panel when ESC is pressed (works when search field is focused)
      viewModel.closeSearch()
      return .handled
    }
  }

  // MARK: - Helper Methods

  private func performSearch(query: String) async {
    if isSchemaSearch {
      await viewModel.performSchemaSearch(
        query: query,
        caseSensitive: viewModel.schemaSearchState.isCaseSensitive
      )
    } else {
      await viewModel.performSearch(
        query: query,
        caseSensitive: viewModel.searchState.isCaseSensitive
      )
    }
  }

  private func navigateToNextMatch() {
    if isSchemaSearch {
      viewModel.navigateToNextSchemaMatch()
    } else {
      viewModel.navigateToNextMatch()
    }
  }

  private func navigateToPreviousMatch() {
    if isSchemaSearch {
      viewModel.navigateToPreviousSchemaMatch()
    } else {
      viewModel.navigateToPreviousMatch()
    }
  }

  private func toggleCaseSensitive() {
    if isSchemaSearch {
      viewModel.schemaSearchState.isCaseSensitive.toggle()
      Task {
        await viewModel.performSchemaSearch(
          query: viewModel.schemaSearchState.query,
          caseSensitive: viewModel.schemaSearchState.isCaseSensitive
        )
      }
    } else {
      viewModel.searchState.isCaseSensitive.toggle()
      Task {
        await viewModel.performSearch(
          query: viewModel.searchState.query,
          caseSensitive: viewModel.searchState.isCaseSensitive
        )
      }
    }
  }
}
