// ResultPinPersistenceTests.swift
// A cell's pinned result in the hand-coded .dblore format

import Foundation
import Testing

@testable import Dblore

@Suite("Result pin persistence")
@MainActor
struct ResultPinPersistenceTests {
  // Whole seconds: the document coder writes ISO 8601 without fractions
  private let pinnedAt = Date(timeIntervalSince1970: 1_700_000_000)

  private func pin() -> PinnedResult {
    PinnedResult(
      result: CellResult(
        columns: [ColumnInfo(name: "id", type: "integer"), ColumnInfo(name: "name", type: "text")],
        rows: [[.int(1), .string("Alice")], [.int(2), .null]],
        executionTime: 0.5,
        rowCount: 2,
        timestamp: Date(timeIntervalSince1970: 1_699_999_000),
        sourceQuery: "SELECT id, name FROM users"
      ),
      pinnedAt: pinnedAt,
      sourceQuery: "SELECT id, name FROM users"
    )
  }

  private func notebook(pinned: PinnedResult?) -> DbloreNotebook {
    DbloreNotebook(
      id: UUID(),
      cells: [NotebookCell(cellType: .sql, content: "SELECT 1", pinnedResult: pinned)],
      metadata: NotebookMetadata(createdAt: pinnedAt, modifiedAt: pinnedAt, title: "Pins"),
      connectionConfig: nil,
      settings: NotebookSettings()
    )
  }

  private func firstCellObject(_ data: Data) throws -> [String: Any] {
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let cells = try #require(json["cells"] as? [[String: Any]])
    return try #require(cells.first)
  }

  private func document(cellPin: Any?) throws -> Data {
    var cell: [String: Any] = ["id": UUID().uuidString, "cellType": "sql", "content": "SELECT 1"]
    cell["pinnedResult"] = cellPin
    let json: [String: Any] = ["id": UUID().uuidString, "cells": [cell]]
    return try JSONSerialization.data(withJSONObject: json)
  }

  @Test("With results saved the pin round-trips")
  func roundTripKeepsPin() throws {
    let data = try DocumentCoder.encode(notebook(pinned: pin()), includeResultsOnSave: true)
    #expect(try firstCellObject(data)["pinnedResult"] != nil)

    let decoded = try #require(try DocumentCoder.decode(from: data).cells.first?.pinnedResult)
    #expect(decoded.pinnedAt == pinnedAt)
    #expect(decoded.sourceQuery == "SELECT id, name FROM users")
    #expect(decoded.result.columns.map(\.name) == ["id", "name"])
    #expect(decoded.result.columns.map(\.type) == ["integer", "text"])
    #expect(decoded.result.rows == [[.int(1), .string("Alice")], [.int(2), .null]])
    #expect(decoded.result.rowCount == 2)
  }

  @Test("With results not saved the pin is not written")
  func resultsOffOmitsPin() throws {
    let data = try DocumentCoder.encode(notebook(pinned: pin()), includeResultsOnSave: false)
    #expect(try firstCellObject(data)["pinnedResult"] == nil)
    #expect(try DocumentCoder.decode(from: data).cells.first?.pinnedResult == nil)
  }

  @Test("A file without a pin decodes")
  func missingPinDecodes() throws {
    let cells = try DocumentCoder.decode(from: document(cellPin: nil)).cells
    #expect(cells.count == 1)
    #expect(cells.first?.pinnedResult == nil)
  }

  @Test(
    "A malformed pin decodes to nil without failing the document",
    arguments: [
      #""nope""#,
      #"{"pinnedAt": 42, "sourceQuery": "SELECT 1"}"#,
      #"{"result": {"rows": []}, "pinnedAt": "not a date", "sourceQuery": "SELECT 1"}"#,
    ])
  func malformedPinIsDropped(pinJSON: String) throws {
    let pinObject = try JSONSerialization.jsonObject(
      with: Data(pinJSON.utf8), options: .fragmentsAllowed)
    let cells = try DocumentCoder.decode(from: document(cellPin: pinObject)).cells
    #expect(cells.count == 1)
    #expect(cells.first?.content == "SELECT 1")
    #expect(cells.first?.pinnedResult == nil)
  }

  @Test("A pin saved without its query still loads, with no query")
  func pinWithoutQueryDecodes() throws {
    let pinObject: [String: Any] = [
      "result": ["columns": [["name": "id", "type": "integer"]], "rows": [], "rowCount": 0],
      "pinnedAt": "2023-11-14T22:13:20Z",
    ]
    let decoded = try #require(
      try DocumentCoder.decode(from: document(cellPin: pinObject)).cells.first?.pinnedResult)
    #expect(decoded.pinnedAt == pinnedAt)
    #expect(decoded.sourceQuery == nil)
    #expect(decoded.result.columns.map(\.name) == ["id"])
  }

  @Test("Duplicating a cell keeps its pin")
  func duplicateKeepsPin() throws {
    let viewModel = NotebookViewModel(notebook: notebook(pinned: pin()))
    let id = try #require(viewModel.notebook.cells.first?.id)
    viewModel.duplicateCell(id: id, registerUndo: false)
    #expect(viewModel.notebook.cells.count == 2)
    #expect(viewModel.notebook.cells[1].pinnedResult == pin())
  }
}
