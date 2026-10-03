// CellUndoRoutingTests.swift
// Cmd+Z routes to cell or staged-change undo for a notebook or data viewer, and
// leaves a text view, field editor, or SQL editor tab alone.

import Foundation
import Testing

@testable import Dblore

struct CellUndoRouteCase: Sendable {
  var firstResponderIsText: Bool
  var notebook: Bool
  var hasDataViewer: Bool
  var routes: Bool
}

@Suite("Cell undo routing")
struct CellUndoRoutingTests {
  @Test(
    "A notebook or data viewer routes when no text view is first responder",
    arguments: [
      CellUndoRouteCase(
        firstResponderIsText: false, notebook: true, hasDataViewer: false, routes: true),
      CellUndoRouteCase(
        firstResponderIsText: true, notebook: true, hasDataViewer: false, routes: false),
      CellUndoRouteCase(
        firstResponderIsText: false, notebook: false, hasDataViewer: true, routes: true),
      CellUndoRouteCase(
        firstResponderIsText: true, notebook: false, hasDataViewer: true, routes: false),
      CellUndoRouteCase(
        firstResponderIsText: false, notebook: false, hasDataViewer: false, routes: false),
      CellUndoRouteCase(
        firstResponderIsText: true, notebook: false, hasDataViewer: false, routes: false),
    ])
  func routes(_ row: CellUndoRouteCase) {
    #expect(
      CellUndoRouting.routesCellUndo(
        firstResponderIsText: row.firstResponderIsText,
        viewMode: row.notebook ? .notebook : .editor,
        hasDataViewer: row.hasDataViewer
      ) == row.routes)
  }
}
