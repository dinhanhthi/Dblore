// LineBookmarksTests.swift
// SQL editor line bookmarks: next / previous wrap around, marks follow edits, and saved marks
// find their line again after the text changed outside the app.

import Foundation
import Testing

@testable import Dblore

@Suite("Line bookmarks")
struct LineBookmarksTests {
  @Test("Next and previous wrap around the first and last marks")
  func nextPreviousWrap() {
    let marks = LineBookmarks(lines: [3, 7, 12])
    #expect(marks.next(after: 3) == 7)
    #expect(marks.next(after: 12) == 3)
    #expect(marks.next(after: 20) == 3)
    #expect(marks.previous(before: 7) == 3)
    #expect(marks.previous(before: 3) == 12)
    #expect(marks.previous(before: 1) == 12)
    #expect(LineBookmarks().next(after: 1) == nil)
  }

  @Test("Edits move the marks below them, and a deleted line loses its mark")
  func shiftOnEdit() {
    let text = "a\nb\nc\nd\ne" as NSString
    var marks = LineBookmarks(lines: [2, 4])

    // Two lines typed at the start of line 1 push both marks down
    marks.applyEdit(replacing: NSRange(location: 0, length: 0), in: text, with: "x\ny\n")
    #expect(marks.lines == [4, 6])

    // Back on the original text: a line break typed at the end of a marked line keeps it
    marks = LineBookmarks(lines: [2, 4])
    marks.applyEdit(replacing: NSRange(location: 3, length: 0), in: text, with: "\n")
    #expect(marks.lines == [2, 5])

    // Line 3 ("c\n") deleted: line 4 moves up, line 2 stays
    marks = LineBookmarks(lines: [2, 4])
    marks.applyEdit(replacing: NSRange(location: 4, length: 2), in: text, with: "")
    #expect(marks.lines == [2, 3])

    // The marked line 2 ("b\n") deleted: its mark goes, line 4 moves up
    marks = LineBookmarks(lines: [2, 4])
    marks.applyEdit(replacing: NSRange(location: 2, length: 2), in: text, with: "")
    #expect(marks.lines == [3])
  }

  @Test("A replacement keeping the line count keeps every mark on its line")
  func sameLineCountReplacementKeepsMarks() {
    // Toggle comment on line 2: its whole line, break included, is rewritten
    let text = "a\nb\nc" as NSString
    var marks = LineBookmarks(lines: [2, 3])
    marks.applyEdit(replacing: NSRange(location: 2, length: 2), in: text, with: "-- b\n")
    #expect(marks.lines == [2, 3])

    // Replace All: one span from a match inside line 1 to one inside line 3
    marks = LineBookmarks(lines: [1, 2, 3])
    marks.applyEdit(
      replacing: NSRange(location: 1, length: 6), in: "ab\ncd\nef", with: "B\nCD\nE")
    #expect(marks.lines == [1, 2, 3])
  }

  @Test("A whole-text replacement changing the line count keeps marks whose line survives")
  func wholeTextReplacementReanchors() {
    // Format: "select 1;" moves down a line, "from a" is gone
    let text = "select 1;\nfrom a" as NSString
    var marks = LineBookmarks(lines: [1, 2])
    marks.applyEdit(
      replacing: NSRange(location: 0, length: text.length), in: text,
      with: "-- note\n  select 1;\nfrom b\nwhere x")
    #expect(marks.lines == [2])

    // Format with upper-case keywords: the unsplit line keeps its mark despite its new case and
    // spacing; the split line cannot be found again
    let query = "select  1;\nselect a from t where x = 1;" as NSString
    marks = LineBookmarks(lines: [1, 2])
    marks.applyEdit(
      replacing: NSRange(location: 0, length: query.length), in: query,
      with: "SELECT 1;\nSELECT a\nFROM t\nWHERE x = 1;")
    #expect(marks.lines == [1])
  }

  @Test("Toggle Bookmark does nothing without the tab's editor")
  @MainActor
  func toggleWithoutCaret() {
    let viewModel = NotebookViewModel()
    viewModel.viewMode = .editor
    viewModel.editorContent = "select 1;\nselect 2;"
    viewModel.toggleLineBookmarkAtCaret()
    #expect(viewModel.lineBookmarks.isEmpty)
  }

  @Test("Saved marks keep a matching line, else move to the nearest same line, else go")
  func reanchorAfterOutsideChange() {
    let original = "select 1;\nfrom a\nselect 2;\nwhere x"
    let saved = LineBookmarks(lines: [1, 3, 4]).entries(in: original)
    #expect(LineBookmarks(restoring: saved, in: original).lines == [1, 3, 4])

    // Outside the app: two lines inserted at the top, "where x" removed, "select 2;" also
    // further down (the nearer copy wins)
    let changed = "-- note\n\nselect 1;\nfrom a\nselect 2;\nlimit 5\nselect 2;"
    #expect(LineBookmarks(restoring: saved, in: changed).lines == [3, 5])
  }

  @Test("A saved line out of range never crashes: below 1 it goes, past the end it is clamped")
  func outOfRangeSavedLines() throws {
    // Two blank lines share one anchor, so every entry reaches the nearest-line search
    let blank = LineBookmarks.anchor(of: "")
    func restored(_ line: String) throws -> [Int] {
      let json = #"[{"line": \#(line), "anchor": "\#(blank)"}]"#
      let entries = try JSONDecoder().decode([LineBookmarks.Entry].self, from: Data(json.utf8))
      return LineBookmarks(restoring: entries, in: "\n").lines
    }
    #expect(try restored("0") == [])
    #expect(try restored("\(Int.min)") == [])
    // Past the end: the nearest blank line is the last one
    #expect(try restored("\(Int.max)") == [2])
  }
}
