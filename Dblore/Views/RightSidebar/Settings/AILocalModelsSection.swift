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
      ForEach(LocalModelCatalog.all) { model in
        row(for: model)
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

    return AIModelCard(isCurrent: isSelected) {
      HStack(alignment: .top, spacing: Spacing.sm) {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          Text(model.displayName)
            .font(.bodyText)
            .foregroundColor(.foreground)
          if model.id == recommendedID {
            Text("Recommended for this Mac")
              .font(.small)
              .foregroundColor(.success)
          }
          if isSelected && installed && isActive {
            AIInUseBadge()
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
        .frame(maxWidth: .infinity, alignment: .leading)
        AITierBadge(text: tierLabel(model))
      }
    }
  }

  private func tierLabel(_ model: LocalModel) -> String {
    switch model.tier {
    case .tiny: "Fast"
    case .balanced: "Balanced"
    case .best: "Best"
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
          .buttonStyle(FilledSecondaryButtonStyle())
          .controlSize(.small)
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
          .controlSize(.small)
          .disabled(isSelected && isActive)
          .linkPointer()
        Button("Delete") { pendingDelete = model }
          .buttonStyle(FilledSecondaryButtonStyle())
          .controlSize(.small)
          .disabled(manager.isBusy)
          .linkPointer()
      }
    } else {
      Button("Download") { manager.download(model) }
        .buttonStyle(PrimaryButtonStyle())
        .controlSize(.small)
        .disabled(manager.isBusy)
        .linkPointer()
    }
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
