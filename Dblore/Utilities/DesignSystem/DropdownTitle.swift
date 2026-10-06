//
//  DropdownTitle.swift
//  Dblore
//
//  One-line titles for menus, pickers, and dropdowns. Stored values stay unchanged.
//

import Foundation

nonisolated enum DropdownTitle {
  /// One line for menu, picker, and dropdown titles. Line breaks become a space.
  /// The stored value is left unchanged.
  static func singleLine(_ text: String) -> String {
    guard text.contains(where: \.isNewline) else { return text }
    // `\r\n` is one break. Any other newline scalar (including U+2028) is too.
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    return normalized.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .joined(separator: " ")
  }
}
