//
//  SQLTextView.swift
//  SQLNotebook
//

import AppKit
import SwiftUI

// MARK: - SQL Text View (handles keyboard shortcuts)

class SQLTextView: NSTextView {
  var onFocus: (() -> Void)?
  var onBlur: ((String) -> Void)?  // Callback with current text when losing focus

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result {
      onFocus?()
      // Notify that this editor is now focused
      NotificationCenter.default.post(name: .editorFocused, object: self)
    }
    return result
  }

  override func resignFirstResponder() -> Bool {
    // Capture the string before calling super to avoid accessing potentially deallocated state
    let currentText = self.string
    let result = super.resignFirstResponder()
    if result {
      // Update binding when losing focus
      onBlur?(currentText)
      // Notify that this editor is no longer focused
      NotificationCenter.default.post(name: .editorUnfocused, object: self)
    }
    return result
  }

  override func keyDown(with event: NSEvent) {
    if handleCellShortcut(with: event) {
      return  // Handled, don't pass to super
    }
    if handleArrowNavigation(with: event) {
      return  // Handled, don't pass to super
    }
    super.keyDown(with: event)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if handleCellShortcut(with: event) {
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  /// Returns true if the event was handled as a cell shortcut
  private func handleCellShortcut(with event: NSEvent) -> Bool {
    let isEnter = event.keyCode == 36
    guard isEnter else { return false }

    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let hasControl = flags.contains(.control)
    let hasShift = flags.contains(.shift)
    let hasOption = flags.contains(.option)
    let hasCommand = flags.contains(.command)

    // Cmd+Shift+Enter -> Run All Cells
    if hasCommand && hasShift && !hasControl && !hasOption {
      NotificationCenter.default.post(name: .runAllCells, object: nil)
      return true
    }

    // Ctrl+Enter -> Run current cell (stay on current cell)
    if hasControl && !hasShift && !hasOption && !hasCommand {
      NotificationCenter.default.post(name: .runCell, object: nil)
      return true
    }

    // Shift+Enter -> Run cell and move to next (create new if last)
    if hasShift && !hasControl && !hasOption && !hasCommand {
      NotificationCenter.default.post(name: .runCellAndSelectNext, object: nil)
      return true
    }

    // Alt/Option+Enter -> Run cell and insert new cell below
    if hasOption && !hasControl && !hasShift && !hasCommand {
      NotificationCenter.default.post(name: .runCellAndInsertBelow, object: nil)
      return true
    }

    return false
  }

  /// Handles up/down arrow navigation between cells
  /// Returns true if the event was handled as a navigation action
  private func handleArrowNavigation(with event: NSEvent) -> Bool {
    let isUpArrow = event.keyCode == 126
    let isDownArrow = event.keyCode == 125

    guard isUpArrow || isDownArrow else { return false }

    // Check for actual modifier keys (Cmd, Ctrl, Alt, Shift) - ignore function key flag
    let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
    let hasModifiers = !event.modifierFlags.intersection(modifiers).isEmpty

    if hasModifiers {
      return false
    }

    let text = self.string
    let cursorPosition = self.selectedRange().location

    if isUpArrow {
      // Navigate to previous cell only if cursor is at the first line
      // Check if there's a newline before the cursor position
      let textBeforeCursor = text.prefix(cursorPosition)
      if !textBeforeCursor.contains("\n") {
        // No newline before cursor, we're on the first line
        NotificationCenter.default.post(name: .selectPreviousCell, object: nil)
        return true
      }
    } else if isDownArrow {
      // Navigate to next cell only if cursor is at the last line
      // Check if there's a newline after the cursor position
      let textAfterCursor = text.suffix(text.count - cursorPosition)
      if !textAfterCursor.contains("\n") {
        // No newline after cursor, we're on the last line
        NotificationCenter.default.post(name: .selectNextCell, object: nil)
        return true
      }
    }

    return false
  }
}
