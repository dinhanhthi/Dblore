// QueryParameterDocumentTests.swift
// Named notebook parameters and document coding

import Foundation
import Testing

@testable import Dblore

@Suite("Query Parameter Document Tests")
@MainActor
struct QueryParameterDocumentTests {
  @Test("Text and NULL map to .text and .null")
  func textAndNullMap() {
    let parameters = [
      QueryParameter(name: "name", value: "ada"),
      QueryParameter(name: "empty", value: ""),
      QueryParameter(name: "absent", value: nil),
    ]

    let bound = parameters.bindValues(for: ["name", "empty", "absent"])

    #expect(bound.values["name"] == .text("ada"))
    #expect(bound.values["empty"] == .text(""))
    #expect(bound.values["absent"] == .null)
    #expect(bound.missing.isEmpty)
  }

  @Test("Missing names come back in request order")
  func missingNamesKeepRequestOrder() {
    let parameters = [QueryParameter(name: "present", value: "1")]

    let bound = parameters.bindValues(for: ["gone", "present", "also", "gone"])

    #expect(bound.missing == ["gone", "also"])
    #expect(bound.values["present"] == .text("1"))
  }

  @Test("Extra stored parameters are ignored")
  func extraStoredParametersIgnored() {
    let parameters = [
      QueryParameter(name: "id", value: "1"),
      QueryParameter(name: "extra", value: "no"),
    ]

    let bound = parameters.bindValues(for: ["id"])

    #expect(bound.values == ["id": .text("1")])
    #expect(bound.missing.isEmpty)
  }

  @Test(":Id and :id are different names")
  func namesAreCaseSensitive() {
    let parameters = [QueryParameter(name: ":Id", value: "1")]

    let bound = parameters.bindValues(for: [":Id", ":id"])

    #expect(bound.values[":Id"] == .text("1"))
    #expect(bound.values[":id"] == nil)
    #expect(bound.missing == [":id"])
  }

  @Test("The first duplicate stored name wins")
  func firstDuplicateStoredNameWins() {
    let parameters = [
      QueryParameter(name: "id", value: "1"),
      QueryParameter(name: "id", value: nil),
    ]

    let bound = parameters.bindValues(for: ["id"])

    #expect(bound.values["id"] == .text("1"))
    #expect(bound.missing.isEmpty)
  }

  @Test("Encode then decode keeps a null value and a text value")
  func encodeDecodeKeepsNullAndText() throws {
    let notebook = DbloreNotebook(
      cells: [
        NotebookCell(
          content: "SELECT :id, :name",
          parameters: [
            QueryParameter(name: "id", value: "7"),
            QueryParameter(name: "name", value: nil),
          ],
          savesParameterValues: true)
      ],
      metadata: NotebookMetadata(title: "Params")
    )

    let data = try DocumentCoder.encode(notebook, includeResultsOnSave: true)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let cells = try #require(object["cells"] as? [[String: Any]])
    let parameters = try #require(cells[0]["parameters"] as? [[String: Any]])
    #expect(parameters[0]["name"] as? String == "id")
    #expect(parameters[0]["value"] as? String == "7")
    #expect(parameters[1]["name"] as? String == "name")
    #expect(parameters[1]["value"] is NSNull)

    let decoded = try DocumentCoder.decode(from: data)
    #expect(decoded.cells[0].parameters == notebook.cells[0].parameters)
    #expect(decoded.cells[0].savesParameterValues)
    #expect(decoded.cells.map(\.content) == ["SELECT :id, :name"])
    #expect(decoded.metadata.title == "Params")
    #expect(decoded.id == notebook.id)
  }

  @Test("JSON without cell parameters decodes to an empty list")
  func missingParametersKeyDecodesEmpty() throws {
    let json: [String: Any] = [
      "version": "1.0",
      "cells": [["content": "SELECT 1", "cellType": "sql"]],
      "metadata": ["title": "Old"],
    ]
    let data = try JSONSerialization.data(withJSONObject: json)

    let notebook = try DocumentCoder.decode(from: data)

    #expect(notebook.cells[0].parameters == [])
    #expect(notebook.cells[0].savesParameterValues == false)
    #expect(notebook.cells.map(\.content) == ["SELECT 1"])
  }

  @Test("Unknown keys on the document, a cell, and a parameter are ignored")
  func unknownKeysAreIgnored() throws {
    let json: [String: Any] = [
      "version": "1.0",
      "future": ["nested": true],
      "cells": [
        [
          "content": "SELECT :id",
          "unused": 1,
          "parameters": [
            ["name": "id", "value": "1", "note": "later"],
            ["name": "name", "value": NSNull(), "extra": false],
          ],
        ]
      ],
    ]
    let data = try JSONSerialization.data(withJSONObject: json)

    let notebook = try DocumentCoder.decode(from: data)

    #expect(
      notebook.cells[0].parameters == [
        QueryParameter(name: "id", value: "1"),
        QueryParameter(name: "name", value: nil),
      ])
    #expect(notebook.cells.map(\.content) == ["SELECT :id"])
  }

  @Test("A missing or non-string value is dropped and JSON null stays NULL")
  func nonStringParameterValueIsDropped() throws {
    let json: [String: Any] = [
      "version": "1.0",
      "cells": [
        [
          "content": "SELECT :id",
          "cellType": "sql",
          "parameters": [
            ["name": "id", "value": 1],
            ["name": "flag"],
            ["name": "ok", "value": NSNull()],
          ],
        ]
      ],
    ]
    let data = try JSONSerialization.data(withJSONObject: json)

    let notebook = try DocumentCoder.decode(from: data)

    #expect(notebook.cells[0].parameters == [QueryParameter(name: "ok", value: nil)])
  }

  @Test("Encoded document version stays 1.0")
  func encodedVersionStays1() throws {
    let notebook = DbloreNotebook(
      cells: [
        NotebookCell(
          content: "SELECT :n",
          parameters: [QueryParameter(name: "n", value: "1")],
          savesParameterValues: true)
      ]
    )

    let data = try DocumentCoder.encode(notebook, includeResultsOnSave: false)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["version"] as? String == "1.0")
  }

  @Test("A top-level parameters key is ignored on decode")
  func topLevelParametersKeyIsIgnored() throws {
    let json: [String: Any] = [
      "version": "1.0",
      "cells": [["content": "SELECT :id", "cellType": "sql"]],
      "parameters": [["name": "id", "value": "1"]],
    ]
    let data = try JSONSerialization.data(withJSONObject: json)

    let notebook = try DocumentCoder.decode(from: data)

    #expect(notebook.parameters == [])
    #expect(notebook.cells[0].parameters == [])
  }

  @Test("Encode writes no top-level parameters key")
  func encodeWritesNoTopLevelParametersKey() throws {
    let notebook = DbloreNotebook(
      cells: [NotebookCell(content: "SELECT :id")],
      parameters: [QueryParameter(name: "id", value: "1")]
    )

    let data = try DocumentCoder.encode(notebook, includeResultsOnSave: false)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["parameters"] == nil)
  }

  @Test("A cell that does not save values writes neither key")
  func unsavedCellWritesNoParameterKeys() throws {
    let notebook = DbloreNotebook(
      cells: [
        NotebookCell(
          content: "SELECT :id",
          parameters: [QueryParameter(name: "id", value: "1")],
          savesParameterValues: false)
      ]
    )

    let data = try DocumentCoder.encode(notebook, includeResultsOnSave: false)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let cells = try #require(object["cells"] as? [[String: Any]])

    #expect(cells[0]["parameters"] == nil)
    #expect(cells[0]["savesParameterValues"] == nil)
  }

  @Test("A saving cell writes the flag and its values round-trip")
  func savingCellWritesFlagAndRoundTrips() throws {
    let notebook = DbloreNotebook(
      cells: [
        NotebookCell(
          content: "SELECT :id",
          parameters: [QueryParameter(name: "id", value: "7")],
          savesParameterValues: true)
      ]
    )

    let data = try DocumentCoder.encode(notebook, includeResultsOnSave: true)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let cells = try #require(object["cells"] as? [[String: Any]])
    #expect(cells[0]["savesParameterValues"] as? Bool == true)
    let parameters = try #require(cells[0]["parameters"] as? [[String: Any]])
    #expect(parameters.count == 1)
    #expect(parameters[0]["name"] as? String == "id")
    #expect(parameters[0]["value"] as? String == "7")

    let decoded = try DocumentCoder.decode(from: data)
    #expect(decoded.cells[0].parameters == [QueryParameter(name: "id", value: "7")])
    #expect(decoded.cells[0].savesParameterValues)
  }

  @Test("Encode keeps only the parameters the cell SQL still uses")
  func encodeDropsUnusedCellParameters() throws {
    let notebook = DbloreNotebook(
      cells: [
        NotebookCell(
          content: "SELECT :id",
          parameters: [
            QueryParameter(name: "id", value: "1"),
            QueryParameter(name: "gone", value: "x"),
          ],
          savesParameterValues: true)
      ]
    )

    let data = try DocumentCoder.encode(notebook, includeResultsOnSave: false)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let cells = try #require(object["cells"] as? [[String: Any]])
    let parameters = try #require(cells[0]["parameters"] as? [[String: Any]])

    #expect(parameters.map { $0["name"] as? String } == ["id"])
  }

  @Test("A saving cell with only unused names writes no parameters key")
  func savingCellWithOnlyUnusedNamesWritesNoParameters() throws {
    let notebook = DbloreNotebook(
      cells: [
        NotebookCell(
          content: "SELECT 1",
          parameters: [QueryParameter(name: "gone", value: "x")],
          savesParameterValues: true)
      ]
    )

    let data = try DocumentCoder.encode(notebook, includeResultsOnSave: false)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let cells = try #require(object["cells"] as? [[String: Any]])

    #expect(cells[0]["savesParameterValues"] as? Bool == true)
    #expect(cells[0]["parameters"] == nil)
  }

  @Test("Values are written even when results are not saved")
  func savingCellWritesParametersWithoutResults() throws {
    let notebook = DbloreNotebook(
      cells: [
        NotebookCell(
          content: "SELECT :id",
          parameters: [QueryParameter(name: "id", value: "1")],
          savesParameterValues: true)
      ]
    )

    let data = try DocumentCoder.encode(notebook, includeResultsOnSave: false)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let cells = try #require(object["cells"] as? [[String: Any]])
    let parameters = try #require(cells[0]["parameters"] as? [[String: Any]])

    #expect(parameters[0]["value"] as? String == "1")
  }

  @Test("Two cells keep independent values through a round trip")
  func twoCellsKeepIndependentValues() throws {
    let notebook = DbloreNotebook(
      cells: [
        NotebookCell(
          content: "SELECT :id",
          parameters: [QueryParameter(name: "id", value: "1")],
          savesParameterValues: true),
        NotebookCell(
          content: "SELECT :id",
          parameters: [QueryParameter(name: "id", value: "2")],
          savesParameterValues: true),
      ]
    )

    let data = try DocumentCoder.encode(notebook, includeResultsOnSave: false)
    let decoded = try DocumentCoder.decode(from: data)

    #expect(decoded.cells[0].parameters == [QueryParameter(name: "id", value: "1")])
    #expect(decoded.cells[1].parameters == [QueryParameter(name: "id", value: "2")])
  }
}
