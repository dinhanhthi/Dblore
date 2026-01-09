//
//  ViewMode.swift
//  SQLNotebook
//

import Foundation

/// Application mode - defines the entire UI and behavior
enum AppMode: String, Codable, CaseIterable, Sendable {
  /// Notebook mode: Multiple cells with inline results (.sqlnb files)
  case notebook

  /// Editor mode: Single SQL editor with result panel below (.sql files)
  case editor

  var displayName: String {
    switch self {
    case .notebook:
      return "Notebook"
    case .editor:
      return "Editor"
    }
  }

  var icon: String {
    switch self {
    case .notebook:
      return "doc.text"
    case .editor:
      return "rectangle.split.2x1"
    }
  }

  var fileExtension: String {
    switch self {
    case .notebook:
      return "sqlnb"
    case .editor:
      return "sql"
    }
  }

  var description: String {
    switch self {
    case .notebook:
      return "Cells with inline results"
    case .editor:
      return "Single editor with result panel"
    }
  }
}

// Keep ViewMode as a typealias for backward compatibility during refactor
typealias ViewMode = AppMode
