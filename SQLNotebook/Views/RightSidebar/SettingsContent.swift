//
//  SettingsContent.swift
//  SQLNotebook
//
//  Main settings view that composes all settings sections
//

import SwiftUI
import UniformTypeIdentifiers

struct SettingsContent: View {
  @Bindable var viewModel: NotebookViewModel
  @Bindable var appSettings = AppSettings.shared
  @State private var showRemoveResultsConfirmation = false
  @State private var isExportingLogs = false
  @State private var showDisableReadOnlyConfirmation = false

  var body: some View {
    ScrollViewReader { proxy in
      VStack(alignment: .leading, spacing: Spacing.lg) {
        // Appearance Settings
        AppearanceSettingsSection(appSettings: appSettings)

        Divider()

        // Editor Settings
        EditorSettingsSection(appSettings: appSettings, viewMode: viewModel.viewMode)

        Divider()

        // Result Table Settings
        ResultTableSettingsSection(appSettings: appSettings, viewMode: viewModel.viewMode)

        // Save Options (Notebook Mode Only)
        if viewModel.viewMode == .notebook {
          Divider()
          SaveOptionsSection(appSettings: appSettings)
        }

        Divider()

        // Security Settings
        SecuritySettingsSection(
          appSettings: appSettings,
          viewModel: viewModel,
          showDisableReadOnlyConfirmation: $showDisableReadOnlyConfirmation
        )

        // File Optimization (Notebook Mode Only)
        if viewModel.viewMode == .notebook {
          Divider()
          FileOptimizationSection(
            viewModel: viewModel,
            showRemoveResultsConfirmation: $showRemoveResultsConfirmation
          )
        }

        Divider()

        // Developer Settings
        DeveloperSettingsSection(isExportingLogs: $isExportingLogs)

        Divider()

        // Keyboard Shortcuts
        KeyboardShortcutsSection(viewMode: viewModel.viewMode)
      }
      .padding(Spacing.md)
      .onReceive(NotificationCenter.default.publisher(for: .scrollToSafeModeSettings)) { _ in
        withAnimation(.easeInOut(duration: 0.4)) {
          // Use custom anchor with slight offset from top (0.15 = 15% from top)
          proxy.scrollTo("safeModeSection", anchor: UnitPoint(x: 0.5, y: 0.15))
        }
      }
    }
    .fileExporter(
      isPresented: $isExportingLogs,
      document: LogDocument(),
      contentType: .plainText,
      defaultFilename: "sqlnotebook-logs-\(formattedDate).txt"
    ) { _ in
      // Export completed, no action needed
    }
  }

  private var formattedDate: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmm"
    return formatter.string(from: Date())
  }
}

#Preview("Settings") {
  let viewModel = NotebookViewModel()
  viewModel.rightSidebarContent = .settings

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}
