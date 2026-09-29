//
//  SQLTextView+Comments.swift
//  Dblore
//
//  Comment toggle functionality for SQL text view
//

import AppKit

// MARK: - Comments Extension

extension SQLTextView {

  /// Toggle SQL comment (--) for selected lines
  func toggleComment() {
    guard let textStorage = textStorage else { return }

    // Set flag to prevent autocomplete from showing during comment toggle
    setProgrammaticEditFlag(true)
    defer { setProgrammaticEditFlag(false) }

    let selectedRange = selectedRange()
    let text = textStorage.string as NSString

    // Find the line range containing the selection
    let lineRange = text.lineRange(for: selectedRange)

    // Get the selected text (full lines)
    let selectedText = text.substring(with: lineRange)

    // Split into lines
    let lines = selectedText.components(separatedBy: .newlines)

    // Determine if we should comment or uncomment
    // If ALL non-empty lines start with "--", we uncomment; otherwise we comment
    let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    let shouldUncomment =
      !nonEmptyLines.isEmpty
      && nonEmptyLines.allSatisfy { line in
        line.trimmingCharacters(in: .whitespaces).hasPrefix("--")
      }

    // Process each line
    var newLines: [String] = []
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      // Skip empty lines
      if trimmed.isEmpty {
        newLines.append(line)
        continue
      }

      if shouldUncomment {
        // Remove "-- " or "--" from the start
        if let range = line.range(of: "--") {
          var uncommented = line
          // Remove "-- " (with space) if present, otherwise just "--"
          if line[range.upperBound...].hasPrefix(" ") {
            let endIndex = line.index(range.upperBound, offsetBy: 1)
            uncommented.removeSubrange(range.lowerBound..<endIndex)
          } else {
            uncommented.removeSubrange(range)
          }
          newLines.append(uncommented)
        } else {
          newLines.append(line)
        }
      } else {
        // Add "-- " at the beginning
        newLines.append("-- " + line)
      }
    }

    // Join lines back together
    let newText = newLines.joined(separator: "\n")

    // Replace the text
    if shouldChangeText(in: lineRange, replacementString: newText) {
      textStorage.replaceCharacters(in: lineRange, with: newText)
      didChangeText()

      // Restore selection (adjust for text length change)
      let lengthDelta = (newText as NSString).length - lineRange.length
      let newSelectedRange = NSRange(
        location: selectedRange.location,
        length: selectedRange.length + lengthDelta
      )
      setSelectedRange(newSelectedRange)
    }
  }
}
