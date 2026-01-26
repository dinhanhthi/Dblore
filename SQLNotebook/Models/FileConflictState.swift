//
//  FileConflictState.swift
//  SQLNotebook
//
//  State model for external file conflict detection
//

import Foundation

// MARK: - File Conflict State

/// State for external file change conflict dialog
struct FileConflictState: Equatable, Sendable {
  var showDialog: Bool = false
  var conflictType: ConflictType = .modified
  var externalModificationDate: Date?

  enum ConflictType: Equatable, Sendable {
    case modified  // File was modified by another application
    case deleted  // File was deleted externally
  }

  /// Show conflict dialog with specified type
  mutating func show(type: ConflictType, modificationDate: Date? = nil) {
    conflictType = type
    externalModificationDate = modificationDate
    showDialog = true
  }

  /// Dismiss the conflict dialog
  mutating func dismiss() {
    showDialog = false
  }

  /// Alert title based on conflict type
  var alertTitle: String {
    switch conflictType {
    case .modified:
      return "File Changed Externally"
    case .deleted:
      return "File Deleted"
    }
  }

  /// Alert message based on conflict type and whether there are unsaved changes
  func alertMessage(hasUnsavedChanges: Bool) -> String {
    switch conflictType {
    case .modified:
      if hasUnsavedChanges {
        return
          "This file was modified by another application. You have unsaved changes. What would you like to do?"
      } else {
        return "This file was modified by another application. The document will be reloaded."
      }
    case .deleted:
      if hasUnsavedChanges {
        return
          "This file has been deleted. You have unsaved changes. Save the document to restore it, or close without saving."
      } else {
        return "This file has been deleted. The document will be closed."
      }
    }
  }
}
