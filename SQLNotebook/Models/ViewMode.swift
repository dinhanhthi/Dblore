//
//  ViewMode.swift
//  SQLNotebook
//

import Foundation

/// View mode for the application
enum ViewMode: String, Codable, CaseIterable, Sendable {
  /// Notebook mode: Multiple cells with inline results
  case notebook

  /// Editor mode: Single SQL editor with result panel below
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
}
