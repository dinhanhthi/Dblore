//
//  SchemaSearchPanelView.swift
//  SQLNotebook
//
//  Search panel for schema visualizer - searches tables and columns
//

import SwiftUI

/// Floating search panel for schema visualizer (top-right corner, overlay style)
struct SchemaSearchPanelView: View {
  @Bindable var workspaceManager: WorkspaceManager
  @FocusState private var isSearchFieldFocused: Bool

  var body: some View {
    HStack(spacing: Spacing.sm) {
      // Search icon
      Image(systemName: "magnifyingglass")
        .foregroundColor(.foregroundMuted)
        .font(.system(size: 14))

      // Search text field
      TextField("Search tables and columns...", text: $workspaceManager.schemaSearchState.query)
        .textFieldStyle(.plain)
        .font(.bodyText)
        .focused($isSearchFieldFocused)
        .onChange(of: workspaceManager.schemaSearchState.query) { _, newValue in
          // Debounce search
          Task {
            try? await Task.sleep(for: .milliseconds(300))
            if workspaceManager.schemaSearchState.query == newValue {
              await workspaceManager.performSchemaSearch(
                query: newValue,
                caseSensitive: workspaceManager.schemaSearchState.isCaseSensitive
              )
            }
          }
        }
        .onSubmit {
          // Enter key navigates to next match
          workspaceManager.navigateToNextSchemaMatch()
        }

      // Match counter
      if workspaceManager.schemaSearchState.isSearching {
        ProgressView()
          .scaleEffect(0.6)
          .frame(width: 12, height: 12)
      } else if !workspaceManager.schemaSearchState.query.isEmpty {
        Text(
          workspaceManager.schemaSearchState.matches.isEmpty
            ? "0 found" : workspaceManager.schemaSearchState.matchCountText
        )
        .font(.caption)
        .foregroundColor(.foregroundSubtle)
        .padding(.horizontal, Spacing.xs)
      }

      Divider()
        .frame(height: 20)

      // Navigation buttons
      Button {
        workspaceManager.navigateToPreviousSchemaMatch()
      } label: {
        Image(systemName: "chevron.up")
          .font(.system(size: 12))
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .disabled(workspaceManager.schemaSearchState.matches.isEmpty)

      Button {
        workspaceManager.navigateToNextSchemaMatch()
      } label: {
        Image(systemName: "chevron.down")
          .font(.system(size: 12))
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .disabled(workspaceManager.schemaSearchState.matches.isEmpty)

      Divider()
        .frame(height: 20)

      // Case sensitivity toggle
      Button {
        workspaceManager.schemaSearchState.isCaseSensitive.toggle()
        Task {
          await workspaceManager.performSchemaSearch(
            query: workspaceManager.schemaSearchState.query,
            caseSensitive: workspaceManager.schemaSearchState.isCaseSensitive
          )
        }
      } label: {
        Image(systemName: "textformat")
          .font(.system(size: 14))
      }
      .buttonStyle(
        GhostButtonStyle(
          isActive: workspaceManager.schemaSearchState.isCaseSensitive,
          iconOnly: true
        )
      )
      .help("Case sensitive")

      // Close button
      Button {
        workspaceManager.closeSchemaSearch()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 12))
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
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
    .onChange(of: workspaceManager.isSchemaSearchPanelVisible) { _, isVisible in
      // Re-focus when panel becomes visible
      if isVisible {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          isSearchFieldFocused = true
        }
      }
    }
    .onChange(of: workspaceManager.schemaSearchFocusTrigger) { _, _ in
      // Re-focus when trigger changes (Cmd+F pressed while panel already visible)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        isSearchFieldFocused = true
      }
    }
    .onKeyPress(.escape) {
      // Close search panel when ESC is pressed
      workspaceManager.closeSchemaSearch()
      return .handled
    }
  }
}
