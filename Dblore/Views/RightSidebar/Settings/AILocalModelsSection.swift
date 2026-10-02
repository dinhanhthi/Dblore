//
//  AILocalModelsSection.swift
//  Dblore
//
//  On-device (MLX) models: download, delete and pick the model to use
//

import SwiftUI

struct AILocalModelsSection: View {
  private let settings = AISettings.shared
  private let manager = LocalModelManager.shared

  @State private var pendingDelete: LocalModel?

  private var recommendedID: String? {
    LocalModelCatalog.recommended(forRAM: ProcessInfo.processInfo.physicalMemory)?.id
  }

  private var selectedID: String { settings.config(for: .localMLX).model }

  private var isActive: Bool { settings.configuration.activeProvider == .localMLX }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text("Local models")
        .font(.bodyText)
        .fontWeight(.medium)
        .foregroundColor(.foreground)

      ForEach(LocalModelCatalog.all) { model in
        row(for: model)
      }

      VStack(alignment: .leading, spacing: Spacing.xs) {
        helpText("Runs fully on this Mac (Apple Silicon). Nothing leaves your computer.")
        helpText(
          "Model downloads come from Hugging Face over HTTPS (the only network use) and are stored in the app's sandbox container."
        )
      }
    }
    .confirmationDialog(
      "Delete model?",
      isPresented: Binding(
        get: { pendingDelete != nil },
        set: { if !$0 { pendingDelete = nil } }
      ),
      titleVisibility: .visible,
      presenting: pendingDelete
    ) { model in
      Button("Delete \(model.displayName)", role: .destructive) {
        manager.delete(model)
      }
      Button("Cancel", role: .cancel) {}
    } message: { model in
      Text(
        "This removes the downloaded files (\(Self.sizeText(model))). You can download it again later."
      )
    }
  }

  // MARK: - Rows

  private func row(for model: LocalModel) -> some View {
    let installed = manager.isInstalled(model)
    let state = manager.state[model.id] ?? .idle
    let isSelected = selectedID == model.id

    return VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(spacing: Spacing.sm) {
        Text(model.displayName)
          .font(.bodyText)
          .foregroundColor(.foreground)
        if model.id == recommendedID {
          Text("Recommended for this Mac")
            .font(.small)
            .foregroundColor(.success)
        }
        Spacer(minLength: 0)
        if isSelected && installed && isActive {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "checkmark.circle.fill")
            Text("In use")
          }
          .font(.small)
          .foregroundColor(.success)
        }
      }

      Text("\(Self.sizeText(model)) · needs \(Self.ramText(model)) RAM · \(model.note)")
        .font(.bodyText)
        .foregroundColor(.foregroundSubtle)

      controls(for: model, installed: installed, state: state, isSelected: isSelected)

      if case .failed(let message) = state {
        Text(message)
          .font(.bodyText)
          .foregroundColor(.destructive)
          .textSelection(.enabled)
      }
    }
  }

  @ViewBuilder
  private func controls(
    for model: LocalModel, installed: Bool, state: LocalModelDownloadState, isSelected: Bool
  ) -> some View {
    if case .downloading(let fraction) = state {
      HStack(spacing: Spacing.md) {
        ProgressView(value: fraction)
        Text("\(Int((fraction * 100).rounded()))%")
          .font(.small)
          .foregroundColor(.foregroundMuted)
        Button("Cancel") { manager.cancel() }
          .buttonStyle(SecondaryButtonStyle())
          .linkPointer()
      }
    } else if state == .finalizing || state == .deleting {
      HStack(spacing: Spacing.sm) {
        ProgressView().controlSize(.small)
        Text(state == .deleting ? "Deleting…" : "Finalizing…")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
    } else if installed {
      HStack(spacing: Spacing.md) {
        Button("Use") { use(model) }
          .buttonStyle(PrimaryButtonStyle())
          .disabled(isSelected && isActive)
          .linkPointer()
        Button("Delete") { pendingDelete = model }
          .buttonStyle(SecondaryButtonStyle())
          .disabled(manager.isBusy)
          .linkPointer()
      }
    } else {
      Button("Download") { manager.download(model) }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(manager.isBusy)
        .linkPointer()
    }
  }

  private func helpText(_ text: String) -> some View {
    Text(verbatim: text)
      .font(.bodyText)
      .foregroundColor(.foregroundSubtle)
  }

  // MARK: - Actions

  /// Picks the model and makes the on-device provider the active one
  private func use(_ model: LocalModel) {
    var config = settings.config(for: .localMLX)
    config.model = model.id
    settings.configuration.configs[.localMLX] = config
    settings.configuration.activeProvider = .localMLX
  }

  // MARK: - Formatting

  private static func sizeText(_ model: LocalModel) -> String {
    ByteCountFormatter.string(fromByteCount: model.approxSizeBytes, countStyle: .file)
  }

  private static func ramText(_ model: LocalModel) -> String {
    ByteCountFormatter.string(fromByteCount: model.minRAMBytes, countStyle: .memory)
  }
}
