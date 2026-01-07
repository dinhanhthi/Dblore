//
//  SearchPanelView.swift
//  SQLNotebook
//
//  Created by Claude Code on 2026-01-07.
//

import SwiftUI

/// Floating search panel (top-right corner, overlay style)
struct SearchPanelView: View {
  @Bindable var viewModel: NotebookViewModel
  @FocusState private var isSearchFieldFocused: Bool

  var body: some View {
    HStack(spacing: Spacing.sm) {
      // Search icon
      Image(systemName: "magnifyingglass")
        .foregroundColor(.foregroundMuted)
        .font(.system(size: 14))

      // Search text field
      TextField("Search in notebook...", text: $viewModel.searchState.query)
        .textFieldStyle(.plain)
        .font(.bodyText)
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
      if !viewModel.searchState.matches.isEmpty || viewModel.searchState.isSearching {
        if viewModel.searchState.isSearching {
          ProgressView()
            .scaleEffect(0.6)
            .frame(width: 12, height: 12)
        } else {
          Text(viewModel.searchState.matchCountText)
            .font(.caption)
            .foregroundColor(.foregroundSubtle)
            .padding(.horizontal, Spacing.xs)
        }
      }

      Divider()
        .frame(height: 20)

      // Navigation buttons
      Button {
        viewModel.navigateToPreviousMatch()
      } label: {
        Image(systemName: "chevron.up")
          .font(.system(size: 12))
      }
      .buttonStyle(ToolbarButtonStyle(iconOnly: true))
      .disabled(viewModel.searchState.matches.isEmpty)

      Button {
        viewModel.navigateToNextMatch()
      } label: {
        Image(systemName: "chevron.down")
          .font(.system(size: 12))
      }
      .buttonStyle(ToolbarButtonStyle(iconOnly: true))
      .disabled(viewModel.searchState.matches.isEmpty)

      Divider()
        .frame(height: 20)

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
          .font(.system(size: 14))
      }
      .buttonStyle(
        ToolbarButtonStyle(
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
        .strokeBorder(Color.border, lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
    .frame(width: 450)
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
  }
}
