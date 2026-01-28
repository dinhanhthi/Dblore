//
//  FileOptimizationSection.swift
//  SQLNotebook
//
//  File optimization settings: file size display and cleanup
//

import SwiftUI

struct FileOptimizationSection: View {
  @Bindable var viewModel: NotebookViewModel
  @Binding var showRemoveResultsConfirmation: Bool

  var body: some View {
    SettingsSection(title: "File Optimization", icon: "gauge.with.dots.needle.bottom.50percent") {
      VStack(alignment: .leading, spacing: Spacing.md) {
        // Current file size display
        HStack {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Current File Size")
              .font(.subheading)
              .foregroundColor(.foreground)

            Text(viewModel.formattedFileSize)
              .font(.mono)
              .foregroundColor(
                viewModel.isFileSizeLarge
                  ? .destructive
                  : (viewModel.isFileSizeWarning ? .warning : .accent)
              )
          }

          Spacer()

          if viewModel.isFileSizeLarge {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundColor(.destructive)
          } else if viewModel.isFileSizeWarning {
            Image(systemName: "exclamationmark.circle.fill")
              .foregroundColor(.warning)
          }
        }
        .padding(Spacing.md)
        .background(Color.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))

        if viewModel.isFileSizeLarge || viewModel.isFileSizeWarning {
          Text(
            viewModel.isFileSizeLarge
              ? "File size exceeds \(FileOptimizationService.formatFileSize(FileOptimizationService.largeSizeThreshold)) limit. Consider removing old results or creating a new notebook."
              : "File size is approaching the recommended limit (\(FileOptimizationService.formatFileSize(FileOptimizationService.warningSizeThreshold)))."
          )
          .font(.small)
          .foregroundColor(viewModel.isFileSizeLarge ? .destructive : .warning)
        }

        // Manual cleanup button
        Button(action: {
          showRemoveResultsConfirmation = true
        }) {
          HStack {
            Image(systemName: "trash")
            Text("Remove All Results Now")
          }
          .font(.bodyText)
          .foregroundColor(.destructive)
          .frame(maxWidth: .infinity)
          .padding(.vertical, Spacing.sm)
          .background(Color.destructive.opacity(0.3))
          .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
        }
        .buttonStyle(.plain)
        .confirmationDialog(
          "Remove All Results?",
          isPresented: $showRemoveResultsConfirmation,
          titleVisibility: .visible
        ) {
          Button("Remove All Results", role: .destructive) {
            viewModel.clearAllOutputs()
          }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text(
            "This will permanently remove all query results from the notebook. You'll need to re-run queries to see results again. This action cannot be undone."
          )
        }

        Text(
          "Removing results will significantly reduce file size but you'll need to re-run queries."
        )
        .font(.small)
        .foregroundColor(.foregroundSubtle)
      }
    }
  }
}
