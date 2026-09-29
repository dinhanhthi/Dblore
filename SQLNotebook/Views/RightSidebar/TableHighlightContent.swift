//
//  TableHighlightContent.swift
//  SQLNotebook
//
//  Highlight form of the data viewer in the right sidebar: color and style on top, then condition rows.
//  Apply/Clear are in the sidebar footer. Saved highlights live in `SavedHighlightsPopover`.
//

import SwiftUI

struct TableHighlightContent: View {
  @Bindable var viewModel: NotebookViewModel

  private var relation: String {
    "\(viewModel.dataViewer?.schema ?? "").\(viewModel.dataViewer?.name ?? "")"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm) {
        Menu {
          ForEach(HighlightColor.allCases, id: \.self) { color in
            Button(action: { viewModel.highlightDraft.color = color }) {
              Label(color.displayName, systemImage: "circle.fill")
                .foregroundStyle(color.color)
            }
          }
        } label: {
          HStack(spacing: Spacing.xs) {
            Circle().fill(viewModel.highlightDraft.color.color).frame(width: 10, height: 10)
            Text(viewModel.highlightDraft.color.displayName).font(.small)
          }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Highlight color")

        Spacer()

        Picker("", selection: $viewModel.highlightDraft.style) {
          Text("Cell").tag(HighlightStyle.cell)
          Text("Row").tag(HighlightStyle.row)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Highlight the matching cell or the whole row")
        .onChange(of: viewModel.highlightDraft.style) { _, style in
          // Live switch of an applied highlight; other draft edits still wait for Apply
          if viewModel.dataViewer?.highlight.isEmpty == false {
            viewModel.dataViewer?.highlight.style = style
          }
        }
      }

      Divider()

      ScrollView {
        FilterConditionsEditor(
          conditions: $viewModel.highlightDraft.filter.conditions,
          columns: viewModel.filterColumns,
          onSubmit: viewModel.applyHighlight
        )
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
    .onAppear { viewModel.prepareHighlightDraft() }
    .onChange(of: relation) { viewModel.prepareHighlightDraft() }
  }
}

// MARK: - Saved highlights

/// Popover of the header Save button: name the current form and save it, load or delete saved ones
struct SavedHighlightsPopover: View {
  @Bindable var viewModel: NotebookViewModel

  @State private var saveName = ""

  private var trimmedSaveName: String {
    saveName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Saved highlights")
        .font(.small)
        .foregroundColor(.foregroundMuted)

      HStack(spacing: Spacing.xs) {
        TextField("Name", text: $saveName)
          .textFieldStyle(.plain)
          .inputCapsuleStyle()
          .onSubmit(save)
        Button("Save", action: save)
          .buttonStyle(SecondaryButtonStyle())
          .disabled(trimmedSaveName.isEmpty)
      }

      if !viewModel.savedHighlights.isEmpty {
        Divider()
        ForEach(viewModel.savedHighlights) { saved in
          HStack(spacing: Spacing.xs) {
            Text(saved.name)
              .font(.small)
              .foregroundColor(.foreground)
              .lineLimit(1)
            Spacer()
            Button("Load") { viewModel.loadSavedHighlight(saved) }
              .buttonStyle(GhostButtonStyle())
            Button(action: { viewModel.deleteSavedHighlight(saved) }) {
              Image(systemName: "trash")
            }
            .buttonStyle(GhostButtonStyle(iconOnly: true))
            .help("Delete saved highlight")
          }
        }
      }
    }
    .padding(Spacing.md)
    .frame(width: 280)
  }

  private func save() {
    if viewModel.saveCurrentHighlight(named: saveName) { saveName = "" }
  }
}
