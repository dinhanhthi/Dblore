//
//  WorkspaceSettingsContent.swift
//  SQLNotebook
//

import SwiftUI

/// Settings content with tabs for Workspace/User/Default
struct WorkspaceSettingsContent: View {
  var workspaceManager: WorkspaceManager?
  @State private var selectedTab: WorkspaceSettingsTab = .workspace

  var body: some View {
    VStack(spacing: 0) {
      // Tab selector
      Picker("", selection: $selectedTab) {
        ForEach(WorkspaceSettingsTab.allCases, id: \.self) { tab in
          Text(tab.rawValue).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .padding(Spacing.md)

      Divider()

      // Settings content based on selected tab
      ScrollView {
        switch selectedTab {
        case .workspace:
          if let manager = workspaceManager {
            WorkspaceLevelSettingsView(workspaceManager: manager)
          } else {
            Text("No workspace open")
              .foregroundColor(.foregroundMuted)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .padding(Spacing.xl)
          }
        case .user:
          UserLevelSettingsView(workspaceManager: workspaceManager)
        case .defaultSettings:
          WorkspaceDefaultSettingsView()
        }
      }
    }
  }
}

// MARK: - Settings Tab Enum

enum WorkspaceSettingsTab: String, CaseIterable {
  case workspace = "Workspace"
  case user = "User"
  case defaultSettings = "Default"
}

// MARK: - Workspace Level Settings

struct WorkspaceLevelSettingsView: View {
  @Bindable var workspaceManager: WorkspaceManager

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      Text("These settings only apply to this workspace")
        .font(.caption)
        .foregroundColor(.foregroundMuted)
        .padding(.horizontal, Spacing.md)

      // Query Settings
      WorkspaceSettingsSectionView(title: "Query", icon: "terminal") {
        // Safe Mode
        WorkspaceSettingRow(
          title: "Safe Mode",
          description: "Query confirmation level",
          isOverridden: workspaceManager.workspace.settings.safeMode != nil
        ) {
          Picker("", selection: workspaceSafeModeBinding) {
            Text("Inherit from User").tag(SafeMode?.none)
            ForEach(SafeMode.allCases, id: \.self) { mode in
              Text(mode.displayName).tag(SafeMode?.some(mode))
            }
          }
          .labelsHidden()
        }

        // Max Row Limit
        WorkspaceSettingRow(
          title: "Max Row Limit",
          description: "Maximum rows to fetch (50-100)",
          isOverridden: workspaceManager.workspace.settings.maxRowLimit != nil
        ) {
          HStack {
            Slider(
              value: workspaceMaxRowLimitBinding,
              in: 50...100,
              step: 10
            )
            Text("\(Int(workspaceMaxRowLimitBinding.wrappedValue))")
              .frame(width: 30)
          }
        }
      }

      // Editor Settings
      WorkspaceSettingsSectionView(title: "Editor", icon: "doc.text") {
        WorkspaceSettingRow(
          title: "Syntax Highlighting",
          isOverridden: workspaceManager.workspace.settings.syntaxHighlightingEnabled != nil
        ) {
          Toggle("", isOn: workspaceSyntaxHighlightingBinding)
            .labelsHidden()
        }

        WorkspaceSettingRow(
          title: "Word Wrap",
          isOverridden: workspaceManager.workspace.settings.wordWrapEnabled != nil
        ) {
          Toggle("", isOn: workspaceWordWrapBinding)
            .labelsHidden()
        }

        WorkspaceSettingRow(
          title: "Show Line Numbers",
          isOverridden: workspaceManager.workspace.settings.showLineNumbers != nil
        ) {
          Toggle("", isOn: workspaceShowLineNumbersBinding)
            .labelsHidden()
        }
      }

      // Reset button
      HStack {
        Spacer()
        Button("Reset All to User Settings") {
          workspaceManager.workspace.settings = .empty
          workspaceManager.isDirty = true
        }
        .buttonStyle(.bordered)
        .disabled(!workspaceManager.workspace.settings.hasOverrides)
      }
      .padding(Spacing.md)
    }
    .padding(.vertical, Spacing.md)
  }

  // MARK: - Bindings

  private var workspaceSafeModeBinding: Binding<SafeMode?> {
    Binding(
      get: { workspaceManager.workspace.settings.safeMode },
      set: {
        workspaceManager.workspace.settings.safeMode = $0
        workspaceManager.isDirty = true
      }
    )
  }

  private var workspaceMaxRowLimitBinding: Binding<Double> {
    Binding(
      get: { Double(workspaceManager.workspace.settings.maxRowLimit ?? 50) },
      set: {
        workspaceManager.workspace.settings.maxRowLimit = Int($0)
        workspaceManager.isDirty = true
      }
    )
  }

  private var workspaceSyntaxHighlightingBinding: Binding<Bool> {
    Binding(
      get: { workspaceManager.workspace.settings.syntaxHighlightingEnabled ?? true },
      set: {
        workspaceManager.workspace.settings.syntaxHighlightingEnabled = $0
        workspaceManager.isDirty = true
      }
    )
  }

  private var workspaceWordWrapBinding: Binding<Bool> {
    Binding(
      get: { workspaceManager.workspace.settings.wordWrapEnabled ?? true },
      set: {
        workspaceManager.workspace.settings.wordWrapEnabled = $0
        workspaceManager.isDirty = true
      }
    )
  }

  private var workspaceShowLineNumbersBinding: Binding<Bool> {
    Binding(
      get: { workspaceManager.workspace.settings.showLineNumbers ?? true },
      set: {
        workspaceManager.workspace.settings.showLineNumbers = $0
        workspaceManager.isDirty = true
      }
    )
  }
}

// MARK: - User Level Settings

struct UserLevelSettingsView: View {
  let workspaceManager: WorkspaceManager?
  @Bindable private var appSettings = AppSettings.shared

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      Text("These settings apply to all workspaces unless overridden")
        .font(.caption)
        .foregroundColor(.foregroundMuted)
        .padding(.horizontal, Spacing.md)

      // Query Settings
      WorkspaceSettingsSectionView(title: "Query", icon: "terminal") {
        UserSettingRow(
          title: "Safe Mode",
          description: appSettings.safeMode.shortDescription,
          isOverriddenInWorkspace: workspaceManager?.settingsResolver.isOverriddenInWorkspace(
            .safeMode) ?? false
        ) {
          Picker("", selection: $appSettings.safeMode) {
            ForEach(SafeMode.allCases, id: \.self) { mode in
              Text(mode.displayName).tag(mode)
            }
          }
          .labelsHidden()
        }

        UserSettingRow(
          title: "Max Row Limit (Notebook)",
          description: "Maximum rows to fetch in notebook mode",
          isOverriddenInWorkspace: workspaceManager?.settingsResolver.isOverriddenInWorkspace(
            .maxRowLimit) ?? false
        ) {
          HStack {
            Slider(
              value: Binding(
                get: { Double(appSettings.maxRowLimit) },
                set: { appSettings.maxRowLimit = Int($0) }
              ), in: 50...100, step: 10)
            Text("\(appSettings.maxRowLimit)")
              .frame(width: 30)
          }
        }
      }

      // Editor Settings
      WorkspaceSettingsSectionView(title: "Editor", icon: "doc.text") {
        UserSettingRow(
          title: "Syntax Highlighting",
          isOverriddenInWorkspace: workspaceManager?.settingsResolver.isOverriddenInWorkspace(
            .syntaxHighlightingEnabled) ?? false
        ) {
          Toggle("", isOn: $appSettings.syntaxHighlightingEnabled)
            .labelsHidden()
        }

        UserSettingRow(
          title: "Word Wrap",
          isOverriddenInWorkspace: workspaceManager?.settingsResolver.isOverriddenInWorkspace(
            .wordWrapEnabled) ?? false
        ) {
          Toggle("", isOn: $appSettings.wordWrapEnabled)
            .labelsHidden()
        }

        UserSettingRow(
          title: "Show Line Numbers",
          isOverriddenInWorkspace: workspaceManager?.settingsResolver.isOverriddenInWorkspace(
            .showLineNumbers) ?? false
        ) {
          Toggle("", isOn: $appSettings.showLineNumbers)
            .labelsHidden()
        }
      }

      // Appearance Settings (not overridable in workspace)
      WorkspaceSettingsSectionView(title: "Appearance", icon: "paintbrush") {
        HStack {
          Text("Theme")
          Spacer()
          Picker("", selection: $appSettings.themePreference) {
            ForEach(ThemePreference.allCases, id: \.self) { theme in
              Text(theme.rawValue).tag(theme)
            }
          }
          .labelsHidden()
          .frame(width: 120)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.cellBackground)

        HStack {
          Text("Accent Color")
          Spacer()
          Picker("", selection: $appSettings.accentColor) {
            ForEach(AccentColor.allCases, id: \.self) { color in
              Text(color.rawValue).tag(color)
            }
          }
          .labelsHidden()
          .frame(width: 120)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.cellBackground)
      }

      // Reset button
      HStack {
        Spacer()
        Button("Reset All to Defaults") {
          appSettings.resetToDefaults()
        }
        .buttonStyle(.bordered)
      }
      .padding(Spacing.md)
    }
    .padding(.vertical, Spacing.md)
  }
}

// MARK: - Default Settings View

struct WorkspaceDefaultSettingsView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      Text("These are the built-in default values")
        .font(.caption)
        .foregroundColor(.foregroundMuted)
        .padding(.horizontal, Spacing.md)

      WorkspaceSettingsSectionView(title: "Query", icon: "terminal") {
        DefaultSettingRow(title: "Safe Mode", value: "Alert (Read)")
        DefaultSettingRow(title: "Max Row Limit", value: "50")
      }

      WorkspaceSettingsSectionView(title: "Editor", icon: "doc.text") {
        DefaultSettingRow(title: "Syntax Highlighting", value: "On")
        DefaultSettingRow(title: "Word Wrap", value: "On")
        DefaultSettingRow(title: "Show Line Numbers", value: "On")
      }

      WorkspaceSettingsSectionView(title: "Appearance", icon: "paintbrush") {
        DefaultSettingRow(title: "Theme", value: "Dark")
        DefaultSettingRow(title: "Accent Color", value: "Purple")
      }
    }
    .padding(.vertical, Spacing.md)
  }
}

// MARK: - Helper Views

struct WorkspaceSettingsSectionView<Content: View>: View {
  let title: String
  let icon: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: icon)
          .font(.system(size: 12))
          .foregroundColor(.accent)
        Text(title)
          .font(.headline)
          .foregroundColor(.foreground)
      }
      .padding(.horizontal, Spacing.md)

      VStack(spacing: 1) {
        content()
      }
      .background(Color.cardBackground)
      .cornerRadius(CornerRadius.md)
      .padding(.horizontal, Spacing.md)
    }
  }
}

struct WorkspaceSettingRow<Content: View>: View {
  let title: String
  var description: String?
  let isOverridden: Bool
  @ViewBuilder let content: () -> Content

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: Spacing.xs) {
          Text(title)
            .foregroundColor(.foreground)

          if isOverridden {
            Text("Modified")
              .font(.caption2)
              .foregroundColor(.accent)
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .background(Color.accent.opacity(0.1))
              .cornerRadius(3)
          }
        }

        if let desc = description {
          Text(desc)
            .font(.caption)
            .foregroundColor(.foregroundMuted)
        }
      }

      Spacer()

      content()
        .frame(width: 140)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(Color.cellBackground)
  }
}

struct UserSettingRow<Content: View>: View {
  let title: String
  var description: String?
  let isOverriddenInWorkspace: Bool
  @ViewBuilder let content: () -> Content

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .foregroundColor(.foreground)

        if let desc = description {
          Text(desc)
            .font(.caption)
            .foregroundColor(.foregroundMuted)
        }

        if isOverriddenInWorkspace {
          Text("Overridden in workspace settings")
            .font(.caption2)
            .foregroundColor(.orange)
            .italic()
        }
      }

      Spacer()

      content()
        .frame(width: 140)
        .opacity(isOverriddenInWorkspace ? 0.5 : 1.0)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(Color.cellBackground)
  }
}

struct DefaultSettingRow: View {
  let title: String
  let value: String

  var body: some View {
    HStack {
      Text(title)
        .foregroundColor(.foreground)

      Spacer()

      Text(value)
        .foregroundColor(.foregroundMuted)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(Color.cellBackground)
  }
}
