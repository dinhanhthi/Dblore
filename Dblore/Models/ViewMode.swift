//
//  ViewMode.swift
//  Dblore
//

import Foundation

/// Application mode - defines the entire UI and behavior
enum AppMode: String, Codable, CaseIterable, Sendable {
  /// Notebook mode: Multiple cells with inline results (.dblore files)
  case notebook

  /// Editor mode: Single SQL editor with result panel below (.sql files)
  case editor

  /// Markdown mode: Plain text note with a WYSIWYG preview (.md files)
  case markdown

  var displayName: String {
    switch self {
    case .notebook:
      return "Notebook"
    case .editor:
      return "Editor"
    case .markdown:
      return "Markdown"
    }
  }

  var icon: String {
    switch self {
    case .notebook:
      return "doc.text"
    case .editor:
      return "rectangle.split.2x1"
    case .markdown:
      return "doc.richtext"
    }
  }

  var fileExtension: String {
    switch self {
    case .notebook:
      return "dblore"
    case .editor:
      return "sql"
    case .markdown:
      return "md"
    }
  }

  var description: String {
    switch self {
    case .notebook:
      return "Cells with inline results"
    case .editor:
      return "Single editor with result panel"
    case .markdown:
      return "Markdown note"
    }
  }
}

// Keep ViewMode as a typealias for backward compatibility during refactor
typealias ViewMode = AppMode
