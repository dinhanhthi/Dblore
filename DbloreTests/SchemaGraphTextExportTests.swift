// SchemaGraphTextExportTests.swift
// The ER diagram as Mermaid and Graphviz DOT text: identifiers from any table name stay valid,
// distinct and quoted, and relationships point at the right entities.

import Foundation
import Testing

@testable import Dblore

@Suite("Schema graph text export")
@MainActor
struct SchemaGraphTextExportTests {
  @Test("Mermaid ids are sanitized with the real name as a quoted alias")
  func mermaidSanitizesNames() {
    let mermaid = SchemaGraphTextExport.mermaid(sampleGraph())
    let lines = mermaid.split(separator: "\n").map(String.init)

    #expect(lines.first == "erDiagram")
    #expect(lines.contains("    order_items[\"order items\"] {"))
    #expect(lines.contains("    say_hi_[\"say 'hi'\"] {"))
    #expect(lines.contains("    v1_2[\"v1.2\"] {"))
    #expect(lines.contains("    caf_[\"café\"] {"))
    // A non-ASCII column name keeps its real name as the attribute comment
    #expect(lines.contains("        character_varying(20) pr_x \"prèx\""))
    // Every entity line is an id of letters, digits, _ and -, then an optional quoted alias
    let entityLines = lines.filter { $0.hasPrefix("    ") && !$0.hasPrefix("        ") }
      .filter { !$0.contains("--") && $0 != "    }" }
    #expect(entityLines.count == 7)
    for line in entityLines {
      #expect(line.wholeMatch(of: /\ {4}[A-Za-z_][A-Za-z0-9_-]*(\["[^"]*"\])?( \{)?/) != nil)
    }
  }

  @Test("Names that sanitize to the same id get distinct suffixes")
  func mermaidCollisionSuffixes() {
    let mermaid = SchemaGraphTextExport.mermaid(sampleGraph())
    #expect(mermaid.contains("    a_b[\"a b\"]"))
    #expect(mermaid.contains("    a_b_2[\"a.b\"]"))
  }

  @Test("Mermaid relationships join the sanitized ids with the key's cardinality")
  func mermaidRelationshipIDs() {
    let mermaid = SchemaGraphTextExport.mermaid(sampleGraph())
    // Required foreign key column, not unique: exactly one café, zero or more items
    #expect(mermaid.contains("    caf_ ||--o{ order_items : \"items_cafe_fk\""))
    // Nullable key: zero or one target
    #expect(mermaid.contains("    a_b_2 |o--o{ say_hi_ : \"say 'fk'\""))
  }

  @Test("Mermaid keywords get a suffix and quoted text holds no line or control characters")
  func mermaidReservedWordsAndControls() {
    let tables = [
      DatabaseTable(
        schema: "public", name: "style", columns: [DatabaseColumn(name: "pk", type: "int")]),
      DatabaseTable(
        schema: "public", name: "Note\u{2028}s\u{0B}x",
        columns: [DatabaseColumn(name: "style_id", type: "int")]),
    ]
    let foreignKeys = [
      ForeignKey(
        constraintName: "fk\u{85}x\u{2029}y", sourceSchema: "public",
        sourceTable: "Note\u{2028}s\u{0B}x", sourceColumns: ["style_id"], targetSchema: "public",
        targetTable: "style", targetColumns: ["pk"])
    ]
    let mermaid = SchemaGraphTextExport.mermaid(
      SchemaGraph.build(from: tables, foreignKeys: foreignKeys))
    let lines = mermaid.split(separator: "\n").map(String.init)

    #expect(lines.contains("    style_e[\"style\"] {"))
    #expect(lines.contains("        int pk_e \"pk\""))
    #expect(lines.contains("    Note_s_x[\"Note s x\"] {"))
    #expect(lines.contains("    style_e |o--o{ Note_s_x : \"fk x y\""))
    #expect(
      !mermaid.unicodeScalars.contains {
        ["\u{2028}", "\u{2029}", "\u{85}", "\u{0B}"].contains($0)
      })
  }

  @Test("DOT quotes and escapes every label, with an id per node")
  func dotQuotesEverything() {
    let dot = SchemaGraphTextExport.dot(sampleGraph())
    #expect(dot.hasPrefix("digraph \"schema\" {\n"))
    #expect(dot.contains("  n3 [label=\"say \\\"hi\\\"\\n"))
    #expect(dot.contains("  n7 [label=\"back\\\\slash\"];"))
    #expect(dot.contains("  n1 -> n2 [label=\"items_cafe_fk\"];"))
    #expect(dot.contains("  n3 -> n6 [label=\"say \\\"fk\\\"\"];"))
  }

  @Test("DOT keeps tables apart whose qualified names read the same")
  func dotDistinctIDsForDottedNames() {
    let tables = [
      DatabaseTable(schema: "a.b", name: "c"), DatabaseTable(schema: "a", name: "b.c"),
    ]
    let dot = SchemaGraphTextExport.dot(SchemaGraph.build(from: tables, foreignKeys: []))
    #expect(dot.contains("  n1 [label=\"a.b.c\"];"))
    #expect(dot.contains("  n2 [label=\"a.b.c\"];"))
  }

  private func sampleGraph() -> SchemaGraph {
    let tables = [
      DatabaseTable(
        schema: "public", name: "order items",
        columns: [
          DatabaseColumn(name: "id", type: "integer", isNullable: false, isPrimaryKey: true),
          DatabaseColumn(name: "cafe_id", type: "integer", isNullable: false),
        ]),
      DatabaseTable(
        schema: "public", name: "café",
        columns: [
          DatabaseColumn(name: "id", type: "integer", isNullable: false, isPrimaryKey: true),
          DatabaseColumn(name: "prèx", type: "character varying(20)"),
        ]),
      DatabaseTable(
        schema: "public", name: "say \"hi\"",
        columns: [DatabaseColumn(name: "ab_id", type: "int")]),
      DatabaseTable(
        schema: "public", name: "v1.2", columns: [DatabaseColumn(name: "x", type: "text")]),
      DatabaseTable(schema: "public", name: "a b"),
      DatabaseTable(
        schema: "public", name: "a.b",
        columns: [DatabaseColumn(name: "id", type: "int", isPrimaryKey: true)]),
      DatabaseTable(schema: "public", name: "back\\slash"),
    ]
    let foreignKeys = [
      ForeignKey(
        constraintName: "items_cafe_fk", sourceSchema: "public", sourceTable: "order items",
        sourceColumns: ["cafe_id"], targetSchema: "public", targetTable: "café",
        targetColumns: ["id"]),
      ForeignKey(
        constraintName: "say \"fk\"", sourceSchema: "public", sourceTable: "say \"hi\"",
        sourceColumns: ["ab_id"], targetSchema: "public", targetTable: "a.b",
        targetColumns: ["id"]),
    ]
    return SchemaGraph.build(from: tables, foreignKeys: foreignKeys)
  }
}
