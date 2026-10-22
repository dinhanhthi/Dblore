// DataDictionaryRendererTests.swift
// The Markdown and HTML data dictionary: document structure, and escaping of every name,
// type, default and comment read from the catalog.

import Foundation
import Testing

@testable import Dblore

@Suite("Data dictionary renderer")
struct DataDictionaryRendererTests {
  private let date = Date(timeIntervalSince1970: 1_792_000_000)

  @Test("A table renders its header, table of contents, columns, indexes and foreign keys")
  func rendersMarkdownStructure() {
    let markdown = DataDictionaryRenderer.markdown(
      tables: [orders()], databaseName: "shop", generatedAt: date)

    #expect(markdown.hasPrefix("# Data Dictionary: shop\n"))
    #expect(markdown.contains("Generated \(date.ISO8601Format())"))
    #expect(markdown.contains("- [public.orders](#t1)"))
    #expect(markdown.contains("<a id=\"t1\"></a>\n\n## public.orders"))
    #expect(markdown.contains("Customer orders"))
    #expect(markdown.contains("| Column | Type | Nullable | Default | Key | Comment |"))
    #expect(markdown.contains("| id | bigint | NO | nextval\\('orders\\_id\\_seq'\\) | PK |  |"))
    #expect(markdown.contains("| customer\\_id | integer | YES |  | FK | Buyer |"))
    #expect(markdown.contains("| orders\\_pkey | id | YES | btree |"))
    #expect(
      markdown.contains(
        "| orders\\_customer\\_fk | customer\\_id | public.customers \\(id\\) | CASCADE | "
          + "NO ACTION |"))
  }

  @Test("Links, images and autolinks in catalog text render as plain text in Markdown")
  func neutralizesMarkdownLinks() {
    let payload = "![](https://attacker/b.png) [Re-auth](https://attacker/login)"
    var table = orders()
    table.name = "[t](https://attacker/t)"
    table.comment = payload
    table.columns[1].comment = payload
    table.columns[1].defaultExpression = payload

    let markdown = DataDictionaryRenderer.markdown(
      tables: [table], databaseName: "db", generatedAt: date)
    // The only links left are the table of contents' own anchors
    #expect(!markdown.replacing(/\]\(#t\d+\)/, with: "").contains("]("))
    #expect(!markdown.contains("!["))
    #expect(!markdown.contains("https:"))
    #expect(markdown.contains("\\[Re-auth\\]\\(https\\://attacker/login\\)"))
  }

  @Test("Tables that could not be read are listed as not included")
  func listsSkippedTables() {
    let markdown = DataDictionaryRenderer.markdown(
      tables: [orders()], databaseName: "shop", generatedAt: date,
      skipped: ["public.gone_[x]"])
    #expect(markdown.contains("Not included (could not be read): public.gone\\_\\[x\\]"))

    let html = DataDictionaryRenderer.html(
      tables: [orders()], databaseName: "shop", generatedAt: date, skipped: ["public.<gone>"])
    #expect(html.contains("Not included (could not be read): public.&lt;gone&gt;"))
  }

  @Test("Script tags, quotes and pipes in names and comments are escaped in both formats")
  func escapesUntrustedCatalogText() {
    var table = orders()
    table.name = "evil<script>|x"
    table.comment = "<script>alert(1)</script> | end"
    table.columns[1].name = "col|<b>"
    table.columns[1].defaultExpression = "'a' & \"b\""

    let markdown = DataDictionaryRenderer.markdown(
      tables: [table], databaseName: "db<script>", generatedAt: date)
    #expect(!markdown.contains("<script"))
    #expect(!markdown.contains("<b>"))
    #expect(markdown.contains("evil&lt;script&gt;\\|x"))
    #expect(markdown.contains("&lt;script&gt;alert\\(1\\)&lt;/script&gt; \\| end"))
    #expect(markdown.contains("| col\\|&lt;b&gt; |"))

    let html = DataDictionaryRenderer.html(
      tables: [table], databaseName: "db<script>", generatedAt: date)
    #expect(!html.contains("<script"))
    #expect(!html.contains("<b>"))
    #expect(html.contains("evil&lt;script&gt;|x"))
    #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt; | end"))
    #expect(html.contains("&#39;a&#39; &amp; &quot;b&quot;"))
    // Nothing but the inline style may load or run
    #expect(html.contains("content=\"default-src 'none'; style-src 'unsafe-inline'\""))
  }

  private func orders() -> TableStructure {
    TableStructure(
      tableID: TableRef("t"), schema: "public", name: "orders",
      columns: [
        column(1, "id", "bigint", nullable: false, default: "nextval('orders_id_seq')"),
        column(2, "customer_id", "integer", nullable: true, comment: "Buyer"),
      ],
      indexes: [
        TableStructure.Index(
          name: "orders_pkey", keys: [.column("id")], isUnique: true, isPrimary: true,
          method: "btree", isPartial: false, predicate: nil)
      ],
      constraints: [
        TableStructure.Constraint(name: "orders_pkey", kind: .primaryKey, columns: ["id"]),
        TableStructure.Constraint(
          name: "orders_customer_fk",
          kind: .foreignKey(
            TableStructure.ForeignKeyReference(
              schema: "public", table: "customers", columns: ["id"], onUpdate: .noAction,
              onDelete: .cascade)),
          columns: ["customer_id"]),
      ],
      comment: "Customer orders")
  }

  private func column(
    _ ordinal: Int, _ name: String, _ type: String, nullable: Bool, default value: String? = nil,
    comment: String? = nil
  ) -> TableStructure.Column {
    TableStructure.Column(
      ordinal: ordinal, name: name, dataType: type, isNullable: nullable,
      defaultExpression: value, identity: nil, generated: nil, comment: comment, columnType: nil,
      extra: nil, characterSet: nil, collation: nil)
  }
}
