// CellUndoRouting.swift
// Cmd+Z reaches notebook and data-viewer undo only when no text view owns the key.

import Foundation

/// Whether the workspace key monitor should undo or redo a cell or staged change.
/// A text view, including a field editor, keeps its own undo manager. A SQL editor
/// tab does not; a data viewer tab (editor mode with a viewer) does.
nonisolated enum CellUndoRouting: Sendable {
  static func routesCellUndo(
    firstResponderIsText: Bool, viewMode: ViewMode, hasDataViewer: Bool
  ) -> Bool {
    guard !firstResponderIsText else { return false }
    switch viewMode {
    case .notebook:
      return true
    case .editor:
      return hasDataViewer
    }
  }
}
