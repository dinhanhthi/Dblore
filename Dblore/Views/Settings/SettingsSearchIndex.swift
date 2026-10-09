//
//  SettingsSearchIndex.swift
//  Dblore
//
//  Searchable text for every settings tab, ranked with the sidebar fuzzy matcher.
//

import Foundation

/// One searchable setting. `card` is the title of the `SettingsGroupCard` it sits in.
struct SettingsSearchEntry: Hashable {
  let card: String
  let title: String
  var detail: String = ""
}

/// A tab kept by the settings search.
struct SettingsSearchMatch: Equatable {
  let tab: SettingsModal.SettingsTab
  /// Settings that matched, best first. Empty when the tab name alone matched.
  let entries: [SettingsSearchEntry]
}

extension SettingsModal.SettingsTab {
  /// Tabs in sidebar order. A tab stays when its name matches every keyword (no settings listed)
  /// or when some setting does. An empty query keeps every tab.
  static func search(_ query: String) -> [SettingsSearchMatch] {
    let keywords = SidebarEntityFilter.keywords(in: query)
    guard !keywords.isEmpty else {
      return allCases.map { SettingsSearchMatch(tab: $0, entries: []) }
    }
    return allCases.compactMap { tab in
      if SidebarEntityFilter.matchesAll(tab.rawValue, keywords: keywords) {
        return SettingsSearchMatch(tab: tab, entries: [])
      }
      let ranked = tab.searchEntries.enumerated()
        .compactMap { index, entry in
          score(entry, in: tab, keywords: keywords).map { (index: index, score: $0, entry: entry) }
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
      guard !ranked.isEmpty else { return nil }
      return SettingsSearchMatch(tab: tab, entries: ranked.map(\.entry))
    }
  }

  /// Each keyword takes its best hit in the title (counted double), card, detail, or tab name.
  /// Nil when some keyword hits none of them.
  private static func score(
    _ entry: SettingsSearchEntry, in tab: Self, keywords: [String]
  ) -> Int? {
    var total = 0
    for keyword in keywords {
      let hits = [
        SidebarEntityFilter.score(keyword, in: entry.title).map { $0 * 2 },
        SidebarEntityFilter.score(keyword, in: entry.card),
        SidebarEntityFilter.score(keyword, in: entry.detail),
        SidebarEntityFilter.score(keyword, in: tab.rawValue),
      ]
      guard let best = hits.compactMap({ $0 }).max() else { return nil }
      total += best
    }
    return total
  }

  /// Text shown on this tab's page. Keep in step with the section views.
  var searchEntries: [SettingsSearchEntry] {
    switch self {
    case .general:
      return [
        .init(card: "Startup", title: "When Dblore starts", detail: "Launch behavior"),
        .init(
          card: "Windows", title: "Open new windows as tabs",
          detail:
            "New workspace windows open as tabs of the current window. Window > Merge All Windows works either way; macOS may also use tabs in full screen or when System Settings prefers tabs."
        ),
        .init(
          card: "New tab", title: "Default file for new tab (Cmd+T)",
          detail: NewTabType.allCases.map(\.title).joined(separator: ", ")),
        .init(
          card: "Notifications", title: "Notify when a long query finishes",
          detail:
            "Post a macOS notification with the tab name, duration and row count. Never the SQL or data."
        ),
        .init(
          card: "Notifications", title: "Longer than (seconds)", detail: "Notification threshold"),
        .init(
          card: "Notifications", title: "Only when Dblore is in the background",
          detail: "Skip the notification while Dblore is the active app."),
        .init(
          card: "Automatic updates", title: "Automatically Check for Updates",
          detail:
            "Check for new versions of Dblore in the background and offer to install them. You can always check now from the Dblore menu."
        ),
      ]
    case .appearance:
      return [
        .init(
          card: "Theme", title: "Theme",
          detail: "Choose between Light, Dark, or System theme. System follows macOS appearance."),
        .init(
          card: "Accent color", title: "Accent color",
          detail: "Choose the main color for buttons, links, and syntax highlighting."),
      ]
    case .editor:
      return [
        .init(
          card: "Text", title: "Font Size",
          detail: "Size of the text in the SQL editor, including notebook cells."),
        .init(
          card: "Editing", title: "Enable Syntax Highlighting",
          detail:
            "Colorize SQL keywords, functions, strings, and comments. Disable to improve performance with large files."
        ),
        .init(
          card: "Editing", title: "Enable Autocomplete",
          detail:
            "When enabled, SQL keywords, table names, and column names will be suggested as you type."
        ),
        .init(
          card: "Editing", title: "Show Line Numbers",
          detail:
            "Display line numbers in the gutter. Helps with navigation and debugging queries. (Editor only)"
        ),
        .init(
          card: "Editing", title: "Word Wrap",
          detail: "Wrap long lines to fit the editor width. Use Option+Z to toggle quickly."),
        .init(
          card: "Editing", title: "Side-by-Side Layout",
          detail:
            "Open new .sql files with the editor on the left and results on the right instead of stacked. Toggle per file with the layout button in the header. (Editor only)"
        ),
        .init(
          card: "Editing", title: "Simple Mode",
          detail:
            "When enabled, Run executes the selection or the current line. Otherwise, Run executes the selection or the entire file. (Editor only)"
        ),
      ]
    case .ai:
      return [
        .init(
          card: "Panel", title: "AI Assistant panel",
          detail: "Where the AI Assistant opens from the toolbar button and ⌘L: "
            + AIPanelMode.allCases.map(\.title).joined(separator: ", ")),
        .init(
          card: "Provider", title: "Provider",
          detail: "Set as active: "
            + AIProviderKind.allCases.map(\.displayName).joined(separator: ", ")),
        .init(card: "Connection", title: "Base URL"),
        .init(card: "Connection", title: "API key"),
        .init(card: "Account", title: "Sign in with ChatGPT"),
        .init(card: "Models", title: "Model", detail: "Refresh, Test connection"),
        .init(
          card: "Local models", title: "Local models",
          detail:
            "Runs fully on this Mac (Apple Silicon). Nothing leaves your computer. Model downloads come from Hugging Face."
        ),
        .init(
          card: "Privacy", title: "Privacy",
          detail:
            "Only schema (table/column names, types, keys) is sent — never row data. AI never runs queries."
        ),
      ]
    case .results:
      return [
        .init(
          card: "Text", title: "Font Size",
          detail: "Size of the text in result tables. Column headers stay the same."),
        .init(
          card: "Table", title: "Hide Column Types",
          detail:
            "When enabled, column types (e.g., VARCHAR, INTEGER) will be hidden from table headers, showing only column names."
        ),
        .init(
          card: "Table", title: "Hide Run with Query Section",
          detail:
            "When enabled, the 'Run with query' section (with query text and download button) will be hidden from result tables."
        ),
        .init(
          card: "Table", title: "Max Height",
          detail: "Adjust the maximum height of result tables. (Notebook only)"),
        .init(
          card: "Table", title: "Result row cap",
          detail:
            "Rows shown per statement; queries are not rewritten — reading stops after this many rows."
        ),
        .init(
          card: "Table", title: "Statement timeout (seconds)",
          detail: "Applied by the server when a connection opens."),
        .init(card: "Table", title: "Lock timeout (seconds)"),
        .init(card: "Table", title: "Idle in transaction timeout (seconds)"),
      ]
    case .save:
      return [
        .init(
          card: "Notebook", title: "Include Results When Saving",
          detail:
            "When enabled, query results are saved with the notebook. Disable to reduce file size. (Notebook only)"
        )
      ]
    case .data:
      let categories = DataSettingsGroup.allCases.flatMap { group in
        group.categories.map {
          SettingsSearchEntry(card: group.title, title: $0.title, detail: $0.description)
        }
      }
      return [
        .init(card: "On this Mac", title: "Export All"),
        .init(card: "On this Mac", title: "Import"),
        .init(card: "On this Mac", title: "Clear All", detail: "Clear all local data"),
        .init(
          card: "History", title: "Record query history",
          detail:
            "Saves statements you run so they show up in the History tab. Keep for, Max entries"
        ),
      ] + categories + [
        .init(
          card: "Saved credentials", title: "Saved credentials",
          detail:
            "Account names only. Credential contents stay in the Keychain until you delete them."
        )
      ]
    case .security:
      return [
        .init(card: "Protection", title: "Protection level", detail: "What queries are allowed"),
        .init(card: "Protection", title: "Commit style", detail: "How writes are handled"),
        .init(
          card: "Safe Mode", title: "Default commit style", detail: "Used for new connections."),
        .init(
          card: "Safe Mode", title: "Safe Mode password",
          detail: "Set a password to enable protection (then Touch ID if you like)."),
        .init(card: "Safe Mode", title: "Use Touch ID"),
      ]
    case .plugins:
      return [
        .init(
          card: "DuckDB", title: "DuckDB",
          detail:
            "Query .duckdb files and Parquet/CSV with DuckDB. Downloaded on demand (~117 MB).")
      ]
    case .developer:
      return [
        .init(
          card: "Connection form", title: "Show experimental engines",
          detail:
            "Include database engines that are not ready for general use in the connection form."
        ),
        .init(
          card: "Logs", title: "Export Logs",
          detail:
            "Export diagnostic logs to share with developers for troubleshooting. Logs include app activity and error messages."
        ),
      ]
    case .shortcuts:
      let groups =
        SettingsModalKeyboardShortcutsSection.appGroups
        + SettingsModalKeyboardShortcutsSection.editorGroups
      return groups.flatMap { group in
        group.rows.map {
          SettingsSearchEntry(card: group.title, title: $0.action, detail: $0.shortcut)
        }
      }
    }
  }
}
