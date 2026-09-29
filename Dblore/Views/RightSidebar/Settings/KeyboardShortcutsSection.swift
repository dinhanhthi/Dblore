//
//  KeyboardShortcutsSection.swift
//  Dblore
//
//  Keyboard shortcuts list for Notebook and Editor modes
//

import SwiftUI

struct KeyboardShortcutsSection: View {
  let viewMode: ViewMode

  var body: some View {
    SettingsSection(title: "Keyboard Shortcuts", icon: "command") {
      VStack(alignment: .leading, spacing: Spacing.md) {
        Text("Custom keyboard shortcuts will be available in a future update.")
          .font(.small)
          .foregroundColor(.foregroundSubtle)

        if viewMode == .notebook {
          notebookKeyboardShortcutsList
        } else {
          editorKeyboardShortcutsList
        }
      }
    }
  }

  private var notebookKeyboardShortcutsList: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      ShortcutRow(action: "New Notebook", shortcut: "Cmd+Shift+N")
      ShortcutRow(action: "New SQL File", shortcut: "Cmd+Shift+J")
      ShortcutRow(action: "Save As", shortcut: "Cmd+Shift+S")
      ShortcutRow(action: "Add New Cell", shortcut: "Cmd+Option+N")
      ShortcutRow(action: "Run Cell", shortcut: "Ctrl+Enter")
      ShortcutRow(action: "Run Cell and Select Next", shortcut: "Shift+Enter")
      ShortcutRow(action: "Run Cell and Insert Below", shortcut: "Option+Enter")
      ShortcutRow(action: "Run All Cells", shortcut: "Cmd+Shift+Enter")
      ShortcutRow(action: "Toggle Comment", shortcut: "Cmd+/")
      ShortcutRow(action: "Toggle Word Wrap", shortcut: "Option+Z")
      ShortcutRow(action: "Delete Cell", shortcut: "Cmd+Delete")
      ShortcutRow(action: "Duplicate Cell", shortcut: "Cmd+D")
      ShortcutRow(action: "Toggle Left Sidebar", shortcut: "Cmd+B")
      ShortcutRow(action: "Toggle Right Sidebar", shortcut: "Cmd+,")
    }
  }

  private var editorKeyboardShortcutsList: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      ShortcutRow(action: "New Notebook", shortcut: "Cmd+Shift+N")
      ShortcutRow(action: "New SQL File", shortcut: "Cmd+Shift+J")
      ShortcutRow(action: "Save As", shortcut: "Cmd+Shift+S")
      ShortcutRow(action: "Run Query", shortcut: "Cmd+R / Cmd+Enter")
      ShortcutRow(action: "Toggle Comment", shortcut: "Cmd+/")
      ShortcutRow(action: "Toggle Word Wrap", shortcut: "Option+Z")
      ShortcutRow(action: "Find", shortcut: "Cmd+F")
      ShortcutRow(action: "Find Next", shortcut: "Cmd+G")
      ShortcutRow(action: "Find Previous", shortcut: "Cmd+Shift+G")
      ShortcutRow(action: "Toggle Left Sidebar", shortcut: "Cmd+B")
      ShortcutRow(action: "Toggle Right Sidebar", shortcut: "Cmd+,")
    }
  }
}
