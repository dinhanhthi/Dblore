//
//  FocusedValues.swift
//  SQLNotebook
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
