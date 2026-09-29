//
//  EditorSettingsSection.swift
//  SQLNotebook
//
//  Editor settings: Syntax highlighting, Autocomplete, Line numbers, Word wrap, Simple mode
//

import SwiftUI

struct EditorSettingsSection: View {
  @Bindable var appSettings: AppSettings
  let viewMode: ViewMode

  var body: some View {
    SettingsSection(title: "Editor", icon: "text.cursor") {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        SettingsToggle(
          title: "Enable Syntax Highlighting",
          description:
            "Colorize SQL keywords, functions, strings, and comments. Disable to improve performance with large files.",
          isOn: $appSettings.syntaxHighlightingEnabled
        )

        SettingsToggle(
          title: "Enable Autocomplete",
          description:
            "When enabled, SQL keywords, table names, and column names will be suggested as you type. Works in both Notebook and Editor modes.",
          isOn: $appSettings.isAutoCompleteEnabled
        )

        // Show Line Numbers toggle (Editor mode only)
        if viewMode == .editor {
          SettingsToggle(
            title: "Show Line Numbers",
            description:
              "Display line numbers in the gutter. Helps with navigation and debugging queries.",
            isOn: $appSettings.showLineNumbers
          )
        }

        // Word Wrap toggle (both modes)
        SettingsToggle(
          title: "Word Wrap",
          description:
            "Wrap long lines to fit the editor width. Use Option+Z to toggle quickly.",
          isOn: $appSettings.wordWrapEnabled
        )

        // Default layout for new .sql files (Editor mode only)
        if viewMode == .editor {
          SettingsToggle(
            title: "Side-by-Side Layout",
            description:
              "Open new .sql files with the editor on the left and results on the right instead of stacked. Toggle per file with the layout button in the header.",
            isOn: $appSettings.editorSideBySideDefault
          )
        }

        // Simple Mode toggle (Editor mode only)
        if viewMode == .editor {
          SettingsToggle(
            title: "Simple Mode",
            description:
              "When enabled, Run executes the selection or the current line. Otherwise, Run executes the selection or the entire file.",
            isOn: $appSettings.editorSimpleMode
          )
        }
      }
    }
  }
}
