//
//  SearchPanelView.swift
//  Dblore
//
//

import SwiftUI

/// Floating search panel (top-right corner, overlay style)
/// Used for searching within notebook/editor content (not schema visualizer)
struct SearchPanelView: View {
  @Bindable var viewModel: NotebookViewModel
  @FocusState private var isSearchFieldFocused: Bool
  @State private var replacement = ""

  private var searchPlaceholder: String {
    viewModel.viewMode == .editor ? "Search in editor..." : "Search in notebook..."
  }

  /// Find and Replace…: only where Replace may edit query text (never a data viewer or a
  /// read-only source tab)
  private var showsReplace: Bool {
    viewModel.searchState.isReplaceVisible && viewModel.isReplaceAvailable
  }

  /// Replace edits query text matches only
  private var hasSourceMatch: Bool {
    viewModel.searchState.matches.contains { $0.matchType == .sqlContent }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      searchRow
      if showsReplace {
        replaceRow
      }
    }
    .controlSize(.small)
    // Trailing padding is smaller because icon buttons carry their own padding
    .padding(.leading, Spacing.md)
    .padding(.trailing, Spacing.xsm)
    .padding(.vertical, Spacing.xs)
    .background(
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .fill(Color.cardBackground.opacity(0.98))
    )
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .strokeBorder(Color.accent.opacity(0.3), lineWidth: 1.5)
    )
    .shadow(color: Color.accent.opacity(0.12), radius: 4, x: 0, y: 2)
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

  private var searchRow: some View {
    HStack(spacing: Spacing.xsm) {
      // Search icon
      Image(systemName: "magnifyingglass")
        .foregroundColor(.foregroundMuted)
        .font(.system(size: 12))
        .frame(width: 14)

      // Search text field
      TextField(searchPlaceholder, text: $viewModel.searchState.query)
        .textFieldStyle(.plain)
        .font(.labelText)
        .focused($isSearchFieldFocused)
        .onChange(of: viewModel.searchState.query) { _, newValue in
          // Debounce search
          Task {
            try? await Task.sleep(for: .milliseconds(300))
            if viewModel.searchState.query == newValue {
              await viewModel.performSearch(
                query: newValue,
                caseSensitive: viewModel.searchState.isCaseSensitive
              )
            }
          }
        }
        .onSubmit {
          // Enter key navigates to next match (like Cmd+G)
          viewModel.navigateToNextMatch()
        }

      // Match counter
      if viewModel.searchState.isSearching {
        ProgressView()
          .scaleEffect(0.6)
          .frame(width: 12, height: 12)
      } else if !viewModel.searchState.query.isEmpty {
        // Show match count when there's a query (even if 0 results)
        Text(
          viewModel.searchState.matches.isEmpty ? "0 found" : viewModel.searchState.matchCountText
        )
        .font(.caption)
        .foregroundColor(.foregroundSubtle)
        .padding(.horizontal, Spacing.xs)
      }

      Divider()
        .frame(height: 14)

      // Navigation buttons
      HStack(spacing: 0) {
        Button {
          viewModel.navigateToPreviousMatch()
        } label: {
          Image(systemName: "chevron.up")
            .font(.system(size: 10))
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .disabled(viewModel.searchState.matches.isEmpty)
        .help("Previous match (⇧⌘G)")

        Button {
          viewModel.navigateToNextMatch()
        } label: {
          Image(systemName: "chevron.down")
            .font(.system(size: 10))
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .disabled(viewModel.searchState.matches.isEmpty)
        .help("Next match (⌘G)")
      }

      Divider()
        .frame(height: 14)

      HStack(spacing: 0) {
        // Case sensitivity toggle
        Button {
          viewModel.searchState.isCaseSensitive.toggle()
          Task {
            await viewModel.performSearch(
              query: viewModel.searchState.query,
              caseSensitive: viewModel.searchState.isCaseSensitive
            )
          }
        } label: {
          Image(systemName: "textformat")
            .font(.system(size: 12))
        }
        .buttonStyle(
          GhostButtonStyle(
            isActive: viewModel.searchState.isCaseSensitive,
            iconOnly: true
          )
        )
        .help("Case sensitive")

        // Close button
        Button {
          viewModel.closeSearch()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 10))
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .help("Close search (Esc)")
      }
    }
  }

  private var replaceRow: some View {
    HStack(spacing: Spacing.xsm) {
      Image(systemName: "arrow.2.squarepath")
        .foregroundColor(.foregroundMuted)
        .font(.system(size: 12))
        .frame(width: 14)

      TextField("Replace with...", text: $replacement)
        .textFieldStyle(.plain)
        .font(.labelText)
        .onSubmit {
          Task { await viewModel.replaceCurrentMatch(with: replacement) }
        }

      Divider()
        .frame(height: 14)

      Button {
        viewModel.searchState.isWholeWord.toggle()
        Task {
          await viewModel.performSearch(
            query: viewModel.searchState.query,
            caseSensitive: viewModel.searchState.isCaseSensitive
          )
        }
      } label: {
        Image(systemName: "textformat.abc")
          .font(.system(size: 12))
      }
      .buttonStyle(
        GhostButtonStyle(isActive: viewModel.searchState.isWholeWord, iconOnly: true)
      )
      .help("Whole word")

      Button("Replace") {
        Task { await viewModel.replaceCurrentMatch(with: replacement) }
      }
      .buttonStyle(GhostButtonStyle())
      .disabled(!hasSourceMatch)
      .help("Replace this match in the query text")

      Button("Replace All") {
        Task { await viewModel.replaceAllMatches(with: replacement) }
      }
      .buttonStyle(GhostButtonStyle())
      .disabled(!hasSourceMatch)
      .help("Replace every match in the query text")
    }
  }
}
