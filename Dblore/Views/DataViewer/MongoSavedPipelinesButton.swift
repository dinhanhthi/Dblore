//
//  MongoSavedPipelinesButton.swift
//  Dblore
//
//  Bookmark button of the MongoDB Aggregations section opening the saved pipelines: name the
//  builder's stages and options and save them, or open or delete a saved pipeline. Pipelines are
//  kept per connection and collection; a Text mode pipeline is turned back into stages before it
//  is saved, and stays in Text with its error shown when it does not parse.
//

import SwiftUI

struct MongoSavedPipelinesButton: View {
  let builder: AggregationBuilderModel
  let store: SavedFilterStore
  /// The connection and collection the pipelines are saved for; nil disables the button
  let key: String?

  @State private var isPresented = false
  @State private var pipelines: [SavedMongoPipeline] = []
  @State private var saveName = ""
  @State private var error: String?

  var body: some View {
    Button {
      refresh()
      error = nil
      isPresented.toggle()
    } label: {
      Image(systemName: "bookmark")
    }
    .buttonStyle(SecondaryButtonStyle(iconOnly: true))
    .disabled(key == nil)
    .help("Saved pipelines")
    .accessibilityLabel("Saved pipelines")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      popover
    }
  }

  /// Name the stages and options and save them; open or delete saved ones
  private var popover: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Saved pipelines")
        .font(.small)
        .foregroundColor(.foregroundMuted)

      HStack(spacing: Spacing.xs) {
        TextField("Name", text: $saveName)
          .textFieldStyle(.plain)
          .inputCapsuleStyle(onPopover: true)
          .onSubmit(save)
          .accessibilityLabel("Pipeline name")
        Button("Save", action: save)
          .buttonStyle(SecondaryButtonStyle())
          .disabled(trimmedSaveName.isEmpty)
          .help("Save the stages and options; a pipeline of the same name is replaced")
          .accessibilityLabel("Save")
      }

      if let error {
        Text(error)
          .font(.small)
          .foregroundColor(.destructive)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }

      if !pipelines.isEmpty {
        Divider()
        ForEach(pipelines) { saved in
          HStack(spacing: Spacing.xs) {
            Text(saved.name)
              .font(.small)
              .foregroundColor(.foreground)
              .lineLimit(1)
              .help(summary(of: saved))
            Spacer()
            Button("Open") { open(saved) }
              .buttonStyle(GhostButtonStyle())
              .help("Replace the stages and options with this pipeline without running it")
              .accessibilityLabel("Open \(saved.name)")
            Button(action: { delete(saved) }) {
              Image(systemName: "trash")
            }
            .buttonStyle(GhostButtonStyle(iconOnly: true))
            .help("Delete saved pipeline")
            .accessibilityLabel("Delete \(saved.name)")
          }
        }
      }
    }
    .popoverContentPadding()
    .frame(width: 280)
  }

  private var trimmedSaveName: String {
    saveName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The stage operators in order, for the name's tooltip
  private func summary(of saved: SavedMongoPipeline) -> String {
    guard !saved.stages.isEmpty else { return "No stages" }
    return saved.stages.map(\.operator).joined(separator: " → ")
  }

  private func refresh() {
    pipelines = key.map { store.listMongoPipelines(for: $0) } ?? []
  }

  /// Saves the stages; an edited text becomes stages first, and one that does not parse stays
  /// in Text with its error shown and nothing saved
  private func save() {
    let name = trimmedSaveName
    guard !name.isEmpty, let key else { return }
    if builder.editMode == .text {
      guard builder.showStages() else {
        error = builder.textError ?? "Fix the pipeline text to save it"
        return
      }
    }
    store.saveMongoPipeline(
      stages: builder.savedStages(), options: builder.options, named: name, for: key)
    saveName = ""
    error = nil
    refresh()
  }

  /// Replaces the stages and options; nothing runs until Preview or Run
  private func open(_ saved: SavedMongoPipeline) {
    builder.restore(saved)
    error = nil
    isPresented = false
  }

  private func delete(_ saved: SavedMongoPipeline) {
    guard let key else { return }
    store.deleteMongoPipeline(id: saved.id, for: key)
    refresh()
  }
}
