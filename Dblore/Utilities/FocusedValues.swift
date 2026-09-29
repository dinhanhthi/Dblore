//
//  FocusedValues.swift
//  Dblore
//

import SwiftUI

// MARK: - Cell Value Editing Focus Key

struct CellValueEditingKey: FocusedValueKey {
  typealias Value = Bool
}

extension FocusedValues {
  var isCellValueEditing: CellValueEditingKey.Value? {
    get { self[CellValueEditingKey.self] }
    set { self[CellValueEditingKey.self] = newValue }
  }
}

// MARK: - Notebook ViewModel Focus Key
// Note: Currently unused - mode switching uses NotificationCenter instead
// Kept for potential future use with menu item state management

struct NotebookViewModelKey: FocusedValueKey {
  typealias Value = NotebookViewModel
}

extension FocusedValues {
  var notebookViewModel: NotebookViewModelKey.Value? {
    get { self[NotebookViewModelKey.self] }
    set { self[NotebookViewModelKey.self] = newValue }
  }
}
