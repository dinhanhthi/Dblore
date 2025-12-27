//
//  SettingsContent.swift
//  SQLNotebook
//

import SwiftUI

struct SettingsContent: View {
  @Bindable var viewModel: NotebookViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      // Result Table Settings
      settingsSection(title: "Result Table") {
        VStack(alignment: .leading, spacing: Spacing.md) {
          // Max Height
          VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
              Text("Max Height")
                .font(.subheading)
                .foregroundColor(.foreground)
              
              Spacer()
              
              Text("\(Int(viewModel.notebook.settings.maxResultHeight)) pt")
                .font(.monoSmall)
                .foregroundColor(.foregroundMuted)
            }
            
            Slider(
              value: Binding(
                get: { viewModel.notebook.settings.maxResultHeight },
                set: { newValue in
                  viewModel.notebook.settings.maxResultHeight = newValue
                  viewModel.onDocumentChanged?()
                }
              ),
              in: 200...1000,
              step: 50
            )
            
            Text("Adjust the maximum height of result tables. Values between 200-1000 points.")
              .font(.caption)
              .foregroundColor(.foregroundSubtle)
          }
        }
      }
      
      Divider()
      
      // Save Settings
      settingsSection(title: "Save Options") {
        VStack(alignment: .leading, spacing: Spacing.md) {
          Toggle(
            "Include Results When Saving",
            isOn: Binding(
              get: { viewModel.notebook.settings.includeResultsOnSave },
              set: { newValue in
                viewModel.notebook.settings.includeResultsOnSave = newValue
                viewModel.onDocumentChanged?()
              }
            )
          )
          .font(.bodyText)
          .foregroundColor(.foreground)
          
          Text("When enabled, query results are saved with the notebook. Disable to reduce file size.")
            .font(.caption)
            .foregroundColor(.foregroundSubtle)
        }
      }
      
      Divider()
      
      // Keyboard Shortcuts (placeholder for future expansion)
      settingsSection(title: "Keyboard Shortcuts") {
        VStack(alignment: .leading, spacing: Spacing.md) {
          Text("Custom keyboard shortcuts will be available in a future update.")
            .font(.caption)
            .foregroundColor(.foregroundSubtle)
          
          // Placeholder for future keyboard shortcut customization UI
          VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach([
              ("Run Cell", "Ctrl+Enter"),
              ("Run All", "Cmd+Shift+Enter"),
              ("Add Cell", "Cmd+B"),
              ("Delete Cell", "Cmd+Delete"),
            ], id: \.0) { shortcut in
              HStack {
                Text(shortcut.0)
                  .font(.bodyText)
                  .foregroundColor(.foregroundMuted)
                
                Spacer()
                
                Text(shortcut.1)
                  .font(.monoSmall)
                  .foregroundColor(.foregroundSubtle)
                  .padding(.horizontal, Spacing.sm)
                  .padding(.vertical, Spacing.xs)
                  .background(Color.inputBackground)
                  .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
              }
            }
          }
        }
      }
    }
    .padding(Spacing.md)
  }
  
  @ViewBuilder
  private func settingsSection<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text(title)
        .font(.heading)
        .foregroundColor(.foreground)
      
      content()
    }
  }
}

#Preview {
  SettingsContent(viewModel: NotebookViewModel())
    .frame(width: 400)
    .background(Color.cardBackground)
    .preferredColorScheme(.dark)
}

