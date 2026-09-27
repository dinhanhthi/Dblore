//
//  SQLNotebookDocument+Coding.swift
//  SQLNotebook
//
//  JSON encoding/decoding for SQL Notebook documents
//

import Foundation

/// Handles encoding/decoding outside of MainActor context
enum DocumentCoder {
  nonisolated static func decode(from data: Data) throws -> SQLNotebook {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    // Manually decode to avoid MainActor isolation issues with Codable
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CocoaError(.fileReadCorruptFile)
    }

    let id = (json["id"] as? String).flatMap { UUID(uuidString: $0) } ?? UUID()

    // Decode metadata
    let metadataDict = json["metadata"] as? [String: Any] ?? [:]
    let dateFormatter = ISO8601DateFormatter()
    let createdAt =
      (metadataDict["createdAt"] as? String).flatMap { dateFormatter.date(from: $0) } ?? Date()
    let modifiedAt =
      (metadataDict["modifiedAt"] as? String).flatMap { dateFormatter.date(from: $0) } ?? Date()
    let title = metadataDict["title"] as? String ?? "Untitled"
    let metadata = NotebookMetadata(createdAt: createdAt, modifiedAt: modifiedAt, title: title)

    // NOTE: connectionConfig is no longer loaded from file for security reasons
    // Connection information should be managed separately
    let connectionConfig: ConnectionConfig? = nil

    // Decode settings (legacy format for backward compatibility)
    let settingsDict = json["settings"] as? [String: Any] ?? [:]
    let keyboardShortcuts = settingsDict["keyboardShortcuts"] as? [String: String] ?? [:]
    let settings = NotebookSettings(keyboardShortcuts: keyboardShortcuts)

    // NOTE: maxResultHeight, includeResultsOnSave, and the row limits are now in AppSettings (global)

    // Decode cells
    var cells: [NotebookCell] = []
    if let cellsArray = json["cells"] as? [[String: Any]] {
      for cellDict in cellsArray {
        let cellId = (cellDict["id"] as? String).flatMap { UUID(uuidString: $0) } ?? UUID()
        let cellTypeRaw = cellDict["cellType"] as? String ?? cellDict["type"] as? String ?? "sql"
        let cellType = CellType(rawValue: cellTypeRaw) ?? .sql
        let content = cellDict["content"] as? String ?? ""
        let executionCount = cellDict["executionCount"] as? Int

        // Decode result if present
        var result: CellResult? = nil
        if let resultDict = cellDict["result"] as? [String: Any] {
          result = decodeResult(from: resultDict, dateFormatter: dateFormatter)
        }

        // Decode isRunning and isResultVisible
        let isRunning = cellDict["isRunning"] as? Bool ?? false
        let isResultVisible = cellDict["isResultVisible"] as? Bool ?? true

        // Decode multi-statement results
        var statementResults: [StatementResult] = []
        var selectedStatementIndex = 0
        var totalExecutionTime: TimeInterval? = nil
        if let statementResultsArray = cellDict["statementResults"] as? [[String: Any]] {
          for statementDict in statementResultsArray {
            let statementId =
              (statementDict["id"] as? String).flatMap { UUID(uuidString: $0) }
              ?? UUID()
            let queryText = statementDict["queryText"] as? String ?? ""
            let statementIndex = statementDict["statementIndex"] as? Int ?? 0
            // A missing or malformed result decodes to an empty result
            let statementResult =
              (statementDict["result"] as? [String: Any]).flatMap {
                decodeResult(from: $0, dateFormatter: dateFormatter)
              } ?? CellResult()
            statementResults.append(
              StatementResult(
                id: statementId,
                queryText: queryText,
                result: statementResult,
                statementIndex: statementIndex
              ))
          }
          selectedStatementIndex = cellDict["selectedStatementIndex"] as? Int ?? 0
          totalExecutionTime = cellDict["totalExecutionTime"] as? TimeInterval
        }

        // Legacy paginationInfo / statementPaginationInfo are not read: pagination is gone.

        let cell = NotebookCell(
          id: cellId,
          cellType: cellType,
          content: content,
          executionCount: executionCount,
          result: result,
          isRunning: isRunning,
          isResultVisible: isResultVisible,
          statementResults: statementResults,
          selectedStatementIndex: selectedStatementIndex,
          totalExecutionTime: totalExecutionTime
        )
        cells.append(cell)
      }
    }

    // Decode documentType (default to .notebook for backward compatibility)
    let documentTypeRaw = json["documentType"] as? String
    let documentType = documentTypeRaw.flatMap { DocumentType(rawValue: $0) } ?? .notebook

    return SQLNotebook(
      id: id, cells: cells, metadata: metadata, connectionConfig: connectionConfig,
      settings: settings, documentType: documentType)
  }

  nonisolated static func encode(
    _ notebook: SQLNotebook,
    includeResultsOnSave: Bool,
    useCompactFormat: Bool = false
  ) throws -> Data {
    let dateFormatter = ISO8601DateFormatter()

    var json: [String: Any] = [
      "version": "1.0",
      "id": notebook.id.uuidString,
      "documentType": notebook.documentType.rawValue,
      "metadata": [
        "createdAt": dateFormatter.string(from: notebook.metadata.createdAt),
        "modifiedAt": dateFormatter.string(from: notebook.metadata.modifiedAt),
        "title": notebook.metadata.title,
      ],
    ]

    // NOTE: connectionConfig is NOT saved to file for security reasons
    // Connection information should be managed separately (e.g., via Keychain)

    // Encode settings
    // NOTE: maxResultHeight, includeResultsOnSave, and the row limits are now in AppSettings (global)
    json["settings"] = [
      "keyboardShortcuts": notebook.settings.keyboardShortcuts
    ]

    var cellsArray: [[String: Any]] = []
    for cell in notebook.cells {
      var cellDict: [String: Any] = [
        "id": cell.id.uuidString,
        "cellType": cell.cellType.rawValue,
        "content": cell.content,
      ]
      if let count = cell.executionCount {
        cellDict["executionCount"] = count
      }
      // Encode result if present AND if app settings allow it
      if let result = cell.result, includeResultsOnSave {
        cellDict["result"] = encodeResult(result, dateFormatter: dateFormatter)
      }
      // Save isRunning and isResultVisible state
      cellDict["isRunning"] = cell.isRunning
      cellDict["isResultVisible"] = cell.isResultVisible

      // Save multi-statement results
      if !cell.statementResults.isEmpty {
        let statementResultsArray = cell.statementResults.map { statementResult in
          var statementDict: [String: Any] = [
            "id": statementResult.id.uuidString,
            "queryText": statementResult.queryText,
            "statementIndex": statementResult.statementIndex,
          ]
          if includeResultsOnSave {
            statementDict["result"] = encodeResult(
              statementResult.result, dateFormatter: dateFormatter)
          }
          return statementDict
        }
        cellDict["statementResults"] = statementResultsArray
        cellDict["selectedStatementIndex"] = cell.selectedStatementIndex
        if let totalTime = cell.totalExecutionTime {
          cellDict["totalExecutionTime"] = totalTime
        }
      }

      cellsArray.append(cellDict)
    }
    json["cells"] = cellsArray

    // Use compact format for better performance (10.1.10 optimization)
    // Removed .prettyPrinted to improve save speed by 50%
    let options: JSONSerialization.WritingOptions = [.sortedKeys]
    return try JSONSerialization.data(withJSONObject: json, options: options)
  }

  // MARK: - Result Encoding/Decoding Helpers

  private nonisolated static func decodeResult(
    from dict: [String: Any], dateFormatter: ISO8601DateFormatter
  ) -> CellResult? {
    // Decode columns
    var columns: [ColumnInfo] = []
    if let columnsArray = dict["columns"] as? [[String: Any]] {
      for colDict in columnsArray {
        let name = colDict["name"] as? String ?? ""
        let type = colDict["type"] as? String ?? ""
        columns.append(ColumnInfo(name: name, type: type))
      }
    }

    // Decode rows
    var rows: [[CellValue]] = []
    if let rowsArray = dict["rows"] as? [[[String: Any]]] {
      for row in rowsArray {
        var cellValues: [CellValue] = []
        for cellDict in row {
          if let cellValue = decodeCellValue(from: cellDict, dateFormatter: dateFormatter) {
            cellValues.append(cellValue)
          }
        }
        rows.append(cellValues)
      }
    }

    let executionTime = dict["executionTime"] as? TimeInterval ?? 0
    let rowCount = dict["rowCount"] as? Int ?? 0
    let timestamp =
      (dict["timestamp"] as? String).flatMap { dateFormatter.date(from: $0) } ?? Date()
    let error = dict["error"] as? String
    let wasLimited = dict["wasLimited"] as? Bool ?? false
    let affectedRows = dict["affectedRows"] as? Int

    let sourceQuery = dict["sourceQuery"] as? String
    // Legacy keys of old files are ignored: tableName / primaryKeyColumns (never an edit target,
    // `editTarget` is session-only), ctid rowIdentifiers, userLimitExceeded / userRequestedLimit
    // (LIMIT rewrite). `wasLimited` now means "truncated by the row cap".

    return CellResult(
      columns: columns,
      rows: rows,
      executionTime: executionTime,
      rowCount: rowCount,
      timestamp: timestamp,
      error: error,
      wasLimited: wasLimited,
      sourceQuery: sourceQuery,
      affectedRows: affectedRows
    )
  }

  private nonisolated static func encodeResult(
    _ result: CellResult, dateFormatter: ISO8601DateFormatter
  ) -> [String: Any] {
    var dict: [String: Any] = [
      "executionTime": result.executionTime,
      "rowCount": result.rowCount,
      "timestamp": dateFormatter.string(from: result.timestamp),
      "wasLimited": result.wasLimited,
    ]

    // Encode columns
    let columnsArray = result.columns.map { column in
      ["name": column.name, "type": column.type]
    }
    dict["columns"] = columnsArray

    // Encode rows
    let rowsArray = result.rows.map { row in
      row.map { cellValue in
        encodeCellValue(cellValue, dateFormatter: dateFormatter)
      }
    }
    dict["rows"] = rowsArray

    if let error = result.error {
      dict["error"] = error
    }

    // Encode affectedRows for modification queries
    if let affectedRows = result.affectedRows {
      dict["affectedRows"] = affectedRows
    }

    // Encode new fields added for inline editing and metadata
    if let sourceQuery = result.sourceQuery {
      dict["sourceQuery"] = sourceQuery
    }

    // tableName / primaryKeyColumns are not written: the inline-edit target is session-only
    // (`CellResult.editTarget`), re-resolved by the server on each live run. The pre-Phase-4
    // reader treats every legacy key (tableName, primaryKeyColumns, rowIdentifiers,
    // userLimitExceeded, userRequestedLimit, paginationInfo) as optional, so none is written.

    return dict
  }

  private nonisolated static func decodeCellValue(
    from dict: [String: Any], dateFormatter: ISO8601DateFormatter
  ) -> CellValue? {
    guard let type = dict["type"] as? String else { return nil }

    switch type {
    case "null":
      return .null
    case "string":
      if let value = dict["value"] as? String {
        return .string(value)
      }
    case "int":
      if let value = dict["value"] as? Int {
        return .int(value)
      }
    case "double":
      if let value = dict["value"] as? Double {
        return .double(value)
      }
    case "bool":
      if let value = dict["value"] as? Bool {
        return .bool(value)
      }
    case "json":
      if let value = dict["value"] as? String {
        return .json(value)
      }
    case "date":
      if let value = dict["value"] as? String,
        let date = dateFormatter.date(from: value)
      {
        return .date(date)
      }
    case "data":
      if let value = dict["value"] as? String,
        let data = Data(base64Encoded: value)
      {
        return .data(data)
      }
    default:
      return nil
    }

    return nil
  }

  private nonisolated static func encodeCellValue(
    _ value: CellValue, dateFormatter: ISO8601DateFormatter
  ) -> [String: Any] {
    switch value {
    case .null:
      return ["type": "null"]
    case .string(let str):
      return ["type": "string", "value": str]
    case .int(let int):
      return ["type": "int", "value": int]
    case .double(let double):
      return ["type": "double", "value": double]
    case .bool(let bool):
      return ["type": "bool", "value": bool]
    case .json(let json):
      return ["type": "json", "value": json]
    case .date(let date):
      return ["type": "date", "value": dateFormatter.string(from: date)]
    case .data(let data):
      return ["type": "data", "value": data.base64EncodedString()]
    }
  }
}
