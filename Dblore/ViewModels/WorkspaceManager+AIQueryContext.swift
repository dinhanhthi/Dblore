//
//  WorkspaceManager+AIQueryContext.swift
//  Dblore
//
//  The catalog-only AI context of one statement on the workspace connection.
//

import Foundation

extension WorkspaceManager {
  /// `AIQueryContext.build` for `statement` on the workspace connection: tables resolved against
  /// the loaded schema, structures read with `fetchTableStructure`. Empty unless the AI access
  /// gate allows the connection and this connection's schema has landed; empty on MongoDB, and
  /// when the connection or its AI access changed while the structures were read. Callers get
  /// `plan` from `ExplainResultPlan.parse(_:)` on the shown EXPLAIN result (the plan view's
  /// parse); engines without a plan adapter pass nil (no plan section).
  func aiQueryContext(statement: String, plan: ExplainPlan? = nil) async throws -> String {
    guard let config = workspace.connectionConfig, let epoch = schemaConnectionEpoch, isAIAllowed()
    else { return "" }
    let connection = connectionManager
    let context = try await AIQueryContext.build(
      statement: statement, dialect: config.databaseType.dialect, tables: databaseTables,
      plan: plan
    ) { schema, table in
      try await connection.fetchTableStructure(schema: schema, table: table)
    }
    return schemaConnectionEpoch == epoch && isAIAllowed() ? context : ""
  }

  /// `AIInlineCompletion.schema` of the text before the caret, built off the main actor from
  /// the loaded schema. Nil unless the AI access gate allows the connection and this
  /// connection's schema has landed (until then the arrays may hold the previous connection's),
  /// and when the connection or its AI access changed while it was built.
  func aiInlineSchema(prefix: String) async -> String? {
    guard let epoch = schemaConnectionEpoch, isAIAllowed() else { return nil }
    let key = workspace.connectionConfig.map(AIAccessGate.sessionKey(for:))
    // The arrays are copied here (copy on write) and scored off the main actor
    let schema = await AIInlineCompletion.schemaOffMain(
      prefix: prefix, tables: databaseTables, foreignKeys: databaseForeignKeys)
    guard schemaConnectionEpoch == epoch, isAIAllowed(),
      workspace.connectionConfig.map(AIAccessGate.sessionKey(for:)) == key
    else { return nil }
    return schema
  }

  func isAIAllowed() -> Bool {
    aiAccessSource()?.decision(settings: aiAssistant.settings.configuration) == .allowed
  }
}
