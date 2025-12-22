//
//  SQLNotebookDocument.swift
//  SQLNotebook
//

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    nonisolated static var sqlNotebook: UTType {
        UTType(exportedAs: "com.sqlnotebook.document")
    }
}

/// Document wrapper for SQL Notebook files
struct SQLNotebookDocument: FileDocument {
    var notebook: SQLNotebook

    nonisolated static var readableContentTypes: [UTType] {
        [.sqlNotebook, .json]
    }
    nonisolated static var writableContentTypes: [UTType] {
        [.sqlNotebook]
    }

    init(notebook: SQLNotebook = SQLNotebook.newDocument()) {
        self.notebook = notebook
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }

        self.notebook = try DocumentCoder.decode(from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        var notebookToSave = notebook
        notebookToSave.metadata.modifiedAt = Date()
        let data = try DocumentCoder.encode(notebookToSave)
        return FileWrapper(regularFileWithContents: data)
    }
}

/// Handles encoding/decoding outside of MainActor context
private enum DocumentCoder {
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
        let createdAt = (metadataDict["createdAt"] as? String).flatMap { dateFormatter.date(from: $0) } ?? Date()
        let modifiedAt = (metadataDict["modifiedAt"] as? String).flatMap { dateFormatter.date(from: $0) } ?? Date()
        let title = metadataDict["title"] as? String ?? "Untitled"
        let metadata = NotebookMetadata(createdAt: createdAt, modifiedAt: modifiedAt, title: title)

        // Decode connection config if present
        var connectionConfig: ConnectionConfig? = nil
        if let connDict = json["connectionConfig"] as? [String: Any] {
            connectionConfig = ConnectionConfig(
                host: connDict["host"] as? String ?? "localhost",
                port: connDict["port"] as? Int ?? 5432,
                database: connDict["database"] as? String ?? "",
                username: connDict["username"] as? String ?? "",
                password: connDict["password"] as? String ?? "",
                sslMode: SSLMode(rawValue: connDict["sslMode"] as? String ?? "prefer") ?? .prefer
            )
        }

        // Decode cells
        var cells: [NotebookCell] = []
        if let cellsArray = json["cells"] as? [[String: Any]] {
            for cellDict in cellsArray {
                let cellId = (cellDict["id"] as? String).flatMap { UUID(uuidString: $0) } ?? UUID()
                let cellTypeRaw = cellDict["cellType"] as? String ?? cellDict["type"] as? String ?? "sql"
                let cellType = CellType(rawValue: cellTypeRaw) ?? .sql
                let content = cellDict["content"] as? String ?? ""
                let executionCount = cellDict["executionCount"] as? Int
                // Skip result decoding for simplicity - results are regenerated on run
                let cell = NotebookCell(
                    id: cellId,
                    cellType: cellType,
                    content: content,
                    executionCount: executionCount,
                    result: nil,
                    isRunning: false
                )
                cells.append(cell)
            }
        }

        return SQLNotebook(id: id, cells: cells, metadata: metadata, connectionConfig: connectionConfig)
    }

    nonisolated static func encode(_ notebook: SQLNotebook) throws -> Data {
        let dateFormatter = ISO8601DateFormatter()

        var json: [String: Any] = [
            "version": "1.0",
            "id": notebook.id.uuidString,
            "metadata": [
                "createdAt": dateFormatter.string(from: notebook.metadata.createdAt),
                "modifiedAt": dateFormatter.string(from: notebook.metadata.modifiedAt),
                "title": notebook.metadata.title
            ]
        ]

        if let config = notebook.connectionConfig {
            json["connectionConfig"] = [
                "host": config.host,
                "port": config.port,
                "database": config.database,
                "username": config.username,
                "password": config.password,
                "sslMode": config.sslMode.rawValue
            ]
        }

        var cellsArray: [[String: Any]] = []
        for cell in notebook.cells {
            var cellDict: [String: Any] = [
                "id": cell.id.uuidString,
                "cellType": cell.cellType.rawValue,
                "content": cell.content
            ]
            if let count = cell.executionCount {
                cellDict["executionCount"] = count
            }
            // Skip encoding results for now
            cellsArray.append(cellDict)
        }
        json["cells"] = cellsArray

        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }
}
