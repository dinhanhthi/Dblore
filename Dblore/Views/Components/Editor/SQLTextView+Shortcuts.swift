//
//  SQLTextView+Shortcuts.swift
//  Dblore
//
//  Keyboard shortcuts handling for SQL text view
//

import AppKit

// MARK: - Keyboard Shortcuts Extension

extension SQLTextView {

  /// Returns true if the event was handled as a cell shortcut
  func handleCellShortcut(with event: NSEvent) -> Bool {
    // No owning notebook (e.g. the favorite form modal): nothing to run
    guard viewModelId != nil else { return false }
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

  /// Handles up/down arrow navigation between cells (notebook mode) or line boundaries (editor mode)
  /// Returns true if the event was handled as a navigation action
  func handleArrowNavigation(with event: NSEvent) -> Bool {
    // No owning notebook (e.g. the favorite form modal): no cells to navigate
    guard viewModelId != nil else { return false }
    let isUpArrow = event.keyCode == 126
    let isDownArrow = event.keyCode == 125

    guard isUpArrow || isDownArrow else { return false }

    // Check for actual modifier keys (Cmd, Ctrl, Alt, Shift) - ignore function key flag
    let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
    let hasModifiers = !event.modifierFlags.intersection(modifiers).isEmpty

    if hasModifiers {
      return false
    }

    let text = string
    let cursorPosition = selectedRange().location

    if isUpArrow {
      // Check if cursor is at the first line (no newline before cursor)
      let textBeforeCursor = text.prefix(cursorPosition)
      if !textBeforeCursor.contains("\n") {
        // We're on the first line
        if isEditorMode {
          // Editor mode: Move cursor to beginning of line (IDE-like behavior)
          setSelectedRange(NSRange(location: 0, length: 0))
          return true
        } else {
          // Notebook mode: Navigate to previous cell
          NotificationCenter.default.post(name: .selectPreviousCell, object: nil)
          return true
        }
      }
    } else if isDownArrow {
      // Check if cursor is at the last line (no newline after cursor)
      let textAfterCursor = text.suffix(text.count - cursorPosition)
      if !textAfterCursor.contains("\n") {
        // We're on the last line
        if isEditorMode {
          // Editor mode: Move cursor to end of line (IDE-like behavior)
          setSelectedRange(NSRange(location: text.count, length: 0))
          return true
        } else {
          // Notebook mode: Navigate to next cell
          NotificationCenter.default.post(name: .selectNextCell, object: nil)
          return true
        }
      }
    }

    return false
  }

  /// Handle Cmd+/ shortcut for comment/uncomment
  /// Returns true if the event was handled
  func handleCommentShortcut(with event: NSEvent) -> Bool {
    // Check for Cmd+/ (keyCode 44 is the "/" key)
    let isSlash = event.keyCode == 44
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let hasCommand = flags.contains(.command)
    let hasNoOtherModifiers =
      !flags.contains(.shift) && !flags.contains(.control) && !flags.contains(.option)

    if isSlash && hasCommand && hasNoOtherModifiers {
      toggleComment()
      return true
    }

    return false
  }

  /// Handle Option+Z shortcut for toggle word wrap
  /// Returns true if the event was handled
  func handleWordWrapShortcut(with event: NSEvent) -> Bool {
    // Check for Option+Z (keyCode 6 is the "Z" key)
    let isZ = event.keyCode == 6
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let hasOption = flags.contains(.option)
    let hasNoOtherModifiers =
      !flags.contains(.shift) && !flags.contains(.control) && !flags.contains(.command)

    if isZ && hasOption && hasNoOtherModifiers {
      // Toggle word wrap setting
      Task { @MainActor in
        AppSettings.shared.wordWrapEnabled.toggle()
      }
      return true
    }

    return false
  }
}
