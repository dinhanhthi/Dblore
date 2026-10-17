// DocumentTreeModelTests.swift
// DocumentTreeModel: documents rebuilt from Mongo result rows and column BSON types, tree nodes
// (keys, previews, type badges, dot paths), expand/collapse, paging of large containers, copy
// texts, and the Grid / Documents display mode rule.

import Foundation
import Testing

@testable import Dblore

@Suite("Document tree model")
struct DocumentTreeModelTests {
  private static let hex = "507f1f77bcf86cd799439011"

  private func doc(_ pairs: (String, MongoValue)...) -> MongoValue {
    .document(pairs.map { MongoValue.Field($0.0, $0.1) })
  }

  private func oid(_ hex: String = Self.hex) -> MongoValue {
    .objectId(MongoObjectId(hex: hex)!)
  }

  /// The model of `documents` as the session hands them to the grid (Key decision d).
  private func model(
    _ documents: [MongoValue], carrying previous: DocumentTreeModel? = nil
  ) -> DocumentTreeModel {
    let columns = MongoBSONMapping.columns(for: documents)
    let rows = documents.map { MongoBSONMapping.row(for: $0, columns: columns) }
    return DocumentTreeModel(columns: columns, rows: rows, carrying: previous)
  }

  private func node(_ model: DocumentTreeModel, path: String) -> DocumentTreeNode? {
    model.visibleNodes.first { $0.path == path && $0.kind == .value }
  }

  // MARK: - Rebuild

  @Test("every BSON type survives the grid cells and column types")
  func rebuildEveryType() {
    let original = doc(
      ("_id", oid()),
      ("str", .string("h\u{E9}llo")),
      ("i32", .int32(-7)),
      ("i64", .int64(1 << 40)),
      ("smallLong", .int64(5)),
      ("dbl", .double(2.5)),
      ("dec", .decimal128("1.50")),
      ("flag", .bool(true)),
      ("when", .date(1_700_000_000_123)),
      ("bin", .binary(subtype: 0, data: Data([1, 2, 3]))),
      ("re", .regex(pattern: "^a", options: "i")),
      ("ts", .timestamp(t: 10, i: 2)),
      ("min", .minKey),
      ("max", .maxKey),
      ("sub", doc(("n", .int32(1)), ("l", .int64(2)), ("d", .double(3)))),
      ("list", .array([.int32(1), .string("x"), doc(("k", .null))])),
      ("code", doc(("$code", .string("function() {}"))))
    )
    #expect(model([original]).documents == [original])
  }

  @Test("a mixed column infers each value from its cell")
  func mixedColumn() {
    let documents = [
      doc(("_id", .int32(1)), ("v", .string("text"))),
      doc(("_id", .int32(2)), ("v", .int32(4))),
      doc(("_id", .int32(3)), ("v", .int64(1 << 40))),
      doc(("_id", .int32(4)), ("v", .double(1.5))),
      doc(("_id", .int32(5)), ("v", .bool(false))),
      doc(("_id", .int32(6)), ("v", .date(86_400_000))),
      doc(("_id", .int32(7)), ("v", doc(("a", .int64(1))))),
    ]
    let rebuilt = model(documents)
    #expect(rebuilt.documents == documents)
    // An ObjectId in a mixed column is a 24-hex `.string` cell: it reads back as a string
    let ids = [doc(("_id", oid())), doc(("_id", .string("plain")))]
    #expect(model(ids).documents == [doc(("_id", .string(Self.hex))), ids[1]])
  }

  @Test("a null cell is a missing key: explicit nulls and absent keys look the same")
  func nullCellIsMissing() {
    let documents = [
      doc(("_id", .int32(1)), ("a", .int32(5))), doc(("_id", .int32(2)), ("a", .null)),
    ]
    let sparse = [doc(("_id", .int32(1)), ("a", .int32(5))), doc(("_id", .int32(2)))]
    #expect(model(documents).documents == sparse)
    #expect(model(sparse).documents == sparse)
  }

  @Test("dates at the Int64 limits clamp instead of trapping")
  func extremeDates() {
    for millis in [Int64.max, Int64.min] {
      let original = doc(("_id", .int32(1)), ("when", .date(millis)))
      #expect(model([original]).documents == [original], "\(millis)")
    }
  }

  @Test("a malformed json cell falls back to a string node")
  func malformedJSONCell() {
    let columns = [ColumnInfo(name: "_id", type: "int"), ColumnInfo(name: "sub", type: "object")]
    let tree = DocumentTreeModel(columns: columns, rows: [[.int(1), .json("{oops")]])
    #expect(tree.documents == [doc(("_id", .int32(1)), ("sub", .string("{oops")))])
    let sub = node(tree, path: "sub")
    #expect(sub?.typeName == "string")
    #expect(sub?.isExpandable == false)
  }

  // MARK: - Nodes

  @Test("nodes show keys, mongosh previews, type badges and dot paths with array indices")
  func nestedNodes() {
    let items = MongoValue.array([doc(("sku", .string("A1"))), doc(("sku", .string("B2")))])
    var tree = model([doc(("_id", oid()), ("qty", .int64(3)), ("items", items))])

    let root = tree.visibleNodes[0]
    #expect(root.key == "ObjectId(\"\(Self.hex)\")")
    #expect(root.preview == "{3 fields}")
    #expect(root.typeName == "object")
    #expect(root.path == "")
    #expect(root.isExpandable && root.isExpanded)
    #expect(tree.visibleNodes.map(\.path) == ["", "_id", "qty", "items"])
    #expect(node(tree, path: "qty")?.preview == "NumberLong(\"3\")")
    #expect(node(tree, path: "qty")?.typeName == "long")
    #expect(node(tree, path: "items")?.preview == "[2 items]")
    #expect(node(tree, path: "items")?.typeName == "array")

    tree.toggleExpansion(node(tree, path: "items")!.id)
    tree.toggleExpansion(node(tree, path: "items.1")!.id)
    let sku = node(tree, path: "items.1.sku")
    #expect(node(tree, path: "items.1")?.key == "1")
    #expect(node(tree, path: "items.1")?.preview == "{1 field}")
    #expect(sku?.key == "sku")
    #expect(sku?.preview == "\"B2\"")
    #expect(sku?.depth == 3)

    tree.toggleExpansion(node(tree, path: "items")!.id)
    #expect(tree.visibleNodes.map(\.path) == ["", "_id", "qty", "items"])

    tree.toggleExpansion(root.id)
    #expect(tree.visibleNodes.count == 1)
    #expect(tree.visibleNodes[0].isExpandable && !tree.visibleNodes[0].isExpanded)
  }

  @Test("a document without a scalar _id is keyed by its position")
  func rootKeyWithoutID() {
    let tree = model([doc(("a", .int32(1))), doc(("a", .int32(2)))])
    #expect(tree.cards.map { $0.nodes[0].key } == ["(1)", "(2)"])
  }

  @Test("large arrays page in steps of 100 behind a show more node")
  func paging() {
    let big = MongoValue.array((0..<250).map { .int32(Int32($0)) })
    var tree = model([doc(("_id", .int32(1)), ("big", big))])
    let bigNode = node(tree, path: "big")!
    tree.toggleExpansion(bigNode.id)

    func children() -> [DocumentTreeNode] { tree.visibleNodes.filter { $0.depth == 2 } }
    #expect(children().count == 101)
    #expect(children().last?.kind == .showMore(remaining: 150))
    #expect(children()[99].path == "big.99")

    tree.showMore(children().last!.id)
    #expect(children().count == 201)
    #expect(children().last?.kind == .showMore(remaining: 50))

    tree.showMore(children().last!.id)
    #expect(children().count == 250)
    #expect(children().allSatisfy { $0.kind == .value })
    #expect(children().last?.path == "big.249")
  }

  @Test("huge scalars preview in bounded time and the visible rows are stored")
  func hugeScalarPreview() {
    let big = String(repeating: "ab", count: 4_000_000)
    let bytes = Data(repeating: 7, count: 8_000_000)
    let original = doc(
      ("_id", .string(big)), ("s", .string(big)), ("b", .binary(subtype: 0, data: bytes)),
      // Under MongoRelaxedJSON.maxInputBytes, so the regex cell parses back
      ("r", .regex(pattern: String(repeating: "ab", count: 250_000), options: "i")))
    var tree = model([original])
    let clock = ContinuousClock()
    let elapsed = clock.measure {
      // Collapse and expand again: one rebuild of the visible rows
      tree.toggleExpansion(tree.visibleNodes[0].id)
      tree.toggleExpansion(tree.visibleNodes[0].id)
      _ = tree.visibleNodes
    }
    #expect(elapsed < .milliseconds(100), "\(elapsed)")
    let limit = DocumentTreeModel.previewLimit + 1
    #expect(tree.visibleNodes.count == 5)
    #expect(tree.visibleNodes.allSatisfy { $0.preview.count <= limit && $0.key.count <= limit })
    #expect(node(tree, path: "s")?.preview == "\"" + String(big.prefix(limit - 2)) + "…")
    #expect(tree.visibleNodes == tree.visibleNodes)
    #expect(tree.copyValueText(node(tree, path: "s")!.id) == big)
  }

  @Test("keys and previews escape control and bidi characters for display only")
  func displayEscaping() {
    let key = "a\u{202E}b\u{7}"
    let value = "x\u{2067}y\u{85}"
    let tree = model([doc(("_id", .int32(1)), (key, .string(value)))])
    let row = tree.visibleNodes[2]
    #expect(row.key == "a\\u202eb\\u0007")
    #expect(row.preview == "\"x\\u2067y\\u0085\"")
    #expect(tree.copyValueText(row.id) == value)
  }

  // MARK: - Cards

  @Test("fields carry key paths; exact primitives get an edit type and a text that parses back")
  func editInfo() throws {
    let items = MongoValue.array([doc(("qty", .int64(1))), doc(("qty", .int64(9_000_000_000)))])
    var tree = model([
      doc(
        ("_id", oid()), ("when", .date(1_700_000_000_123)), ("old", .date(-1)), ("items", items))
    ])
    tree.toggleExpansion(node(tree, path: "items")!.id)
    tree.toggleExpansion(node(tree, path: "items.1")!.id)

    let qty = try #require(node(tree, path: "items.1.qty"))
    #expect(qty.keys == ["items", "1", "qty"])
    #expect(qty.editType == "long")
    let qtyText = tree.editText(qty.id)
    #expect(
      try NotebookViewModel.parsedDocumentValue(qtyText, columnType: "long")
        == .int64(9_000_000_000))
    for (path, millis) in [("when", Int64(1_700_000_000_123)), ("old", -1)] {
      let date = try #require(node(tree, path: path))
      #expect(date.editType == "date")
      let text = tree.editText(date.id)
      #expect(
        try NotebookViewModel.parsedDocumentValue(text, columnType: "date") == .date(millis),
        "\(text ?? "nil")")
    }
    #expect(tree.visibleNodes[0].keys == [])
    #expect(tree.visibleNodes[0].editType == nil)
    #expect(node(tree, path: "_id")?.editType == nil)
    #expect(node(tree, path: "items")?.editType == nil)
    #expect(tree.editText(node(tree, path: "_id")!.id) == nil)

    // A mixed column infers its values from the cells: not exact, so not edited as text
    let mixed = model([
      doc(("_id", .int32(1)), ("v", .int32(4))), doc(("_id", .int32(2)), ("v", .string("x"))),
    ])
    #expect(node(mixed, path: "v")?.editType == nil)
  }

  @Test("expand all opens every nested document and array of one card; collapse all closes them")
  func expandAndCollapseAll() {
    let nested = doc(
      ("_id", .int32(1)),
      ("a", doc(("b", doc(("c", .int32(1)))))),
      ("tags", .array([doc(("x", .int32(2)))])))
    var tree = model([nested, doc(("_id", .int32(2)), ("d", doc(("e", .int32(3)))))])
    #expect(!tree.isFullyExpanded(document: 0))

    tree.expandAll(document: 0)
    #expect(
      tree.cards[0].nodes.map(\.path) == [
        "", "_id", "a", "a.b", "a.b.c", "tags", "tags.0", "tags.0.x",
      ]
    )
    #expect(tree.isFullyExpanded(document: 0))
    // Only that card
    #expect(tree.cards[1].nodes.map(\.path) == ["", "_id", "d"])

    tree.collapseAll(document: 0)
    #expect(tree.cards[0].nodes.map(\.path) == ["", "_id", "a", "tags"])
    #expect(!tree.isFullyExpanded(document: 0))
  }

  @Test("expand all documents opens every card and its containers; collapse all closes every card")
  func expandAndCollapseAllDocuments() {
    var tree = model([
      doc(("_id", .int32(1)), ("a", doc(("b", .int32(1))))),
      doc(("_id", .int32(2)), ("tags", .array([.int32(2)]))),
    ])
    tree.toggleExpansion(tree.cards[1].nodes[0].id)

    tree.expandAllDocuments()
    #expect(
      tree.cards.map { $0.nodes.map(\.path) } == [
        ["", "_id", "a", "a.b"], ["", "_id", "tags", "tags.0"],
      ])

    tree.collapseAllDocuments()
    #expect(tree.cards.map { $0.nodes.map(\.path) } == [[""], [""]])
  }

  @Test("staged inserts follow the stored documents; tree state survives inserts and rebuilds")
  func stagedInsertsAndCarryOver() throws {
    let stored = [doc(("_id", .int32(1)), ("sub", doc(("a", .int32(1))))), doc(("_id", .int32(2)))]
    var tree = model(stored)
    tree.toggleExpansion(node(tree, path: "sub")!.id)
    tree.toggleExpansion(tree.cards[1].nodes[0].id)

    let inserted = doc(("name", .string("new")))
    tree.setStagedInserts([inserted])
    #expect(tree.storedCount == 2)
    #expect(tree.documents == stored + [inserted])
    #expect(tree.isStaged(document: 2) && !tree.isStaged(document: 1))
    #expect(tree.cards.map(\.document) == [0, 1, 2])
    #expect(tree.cards.map(\.isStaged) == [false, false, true])
    #expect(tree.cards[0].nodes.map(\.path) == ["", "_id", "sub", "sub.a"])
    #expect(tree.cards[1].nodes.count == 1)
    #expect(tree.cards[2].nodes.map(\.path) == ["", "name"])
    #expect(tree.cards[2].nodes[1].editType == nil)

    tree.setStagedInserts([])
    #expect(tree.documents == stored)

    let rebuilt = model(stored, carrying: tree)
    #expect(rebuilt.visibleNodes == tree.visibleNodes)
  }

  // MARK: - Copy

  @Test("copy path quotes keys that are not plain identifiers, indexes stay bare")
  func copyPathQuoting() {
    let original = doc(
      ("_id", .int32(1)),
      ("a.b", doc(("c", .int32(1)))),
      ("3", .array([.int32(0), doc(("$x", .int32(2)))])),
      ("", .int32(4)),
      ("r\u{202E}\n", .int32(5)),
      ("first name", .int32(6)),
      ("snake_case9", .int32(7)))
    var tree = model([original])
    tree.toggleExpansion(tree.visibleNodes[2].id)
    tree.toggleExpansion(tree.visibleNodes[4].id)
    tree.toggleExpansion(tree.visibleNodes[6].id)
    let paths = tree.visibleNodes.dropFirst().map { tree.copyPathText($0.id) }
    #expect(
      paths == [
        "_id", "\"a.b\"", "\"a.b\".c", "\"3\"", "\"3\".0", "\"3\".1", "\"3\".1.\"$x\"", "\"\"",
        "\"r\\u202e\\n\"", "\"first name\"", "snake_case9",
      ])
  }

  @Test("copy value, path and document texts")
  func copyTexts() {
    let original = doc(
      ("_id", oid()), ("name", .string("a \"b\"")), ("n", .int32(5)),
      ("tags", .array([.string("x"), .int64(2)])))
    var tree = model([original])
    let root = tree.visibleNodes[0]
    tree.toggleExpansion(node(tree, path: "tags")!.id)

    let name = node(tree, path: "name")!.id
    let n = node(tree, path: "n")!.id
    let id = node(tree, path: "_id")!.id
    let tags = node(tree, path: "tags")!.id
    let tag1 = node(tree, path: "tags.1")!.id

    #expect(tree.copyValueText(name) == "a \"b\"")
    #expect(tree.copyValueText(n) == "5")
    #expect(tree.copyValueText(id) == "ObjectId(\"\(Self.hex)\")")
    #expect(tree.copyValueText(tag1) == "NumberLong(\"2\")")
    #expect(tree.copyValueText(tags) == "[\"x\", {\"$numberLong\": \"2\"}]")
    #expect(tree.copyPathText(tag1) == "tags.1")
    #expect(tree.copyPathText(root.id) == nil)
    let canonical = MongoRelaxedJSON.render(original, as: .canonicalExtendedJSON)
    #expect(tree.copyDocumentText(tag1) == canonical)
    #expect(tree.copyDocumentText(root.id) == canonical)
    #expect(tree.copyValueText(root.id) == canonical)
  }

  // MARK: - Display mode

  @Test("Grid by default; Documents stays for later results, Chart only for its result")
  func displayMode() {
    let first = Date(timeIntervalSince1970: 1)
    let second = Date(timeIntervalSince1970: 2)
    typealias Mode = ResultDisplayMode
    #expect(Mode.shown(stored: .grid, stamp: nil, resultTimestamp: first) == .grid)
    #expect(Mode.shown(stored: .chart, stamp: first, resultTimestamp: first) == .chart)
    #expect(Mode.shown(stored: .chart, stamp: first, resultTimestamp: second) == .grid)
    #expect(Mode.shown(stored: .documents, stamp: first, resultTimestamp: second) == .documents)
    #expect(Mode.tabs(chartable: true, documents: false) == [.grid, .chart])
    #expect(Mode.tabs(chartable: false, documents: true) == [.grid, .documents])
    #expect(Mode.tabs(chartable: true, documents: true) == [.grid, .documents, .chart])
    #expect(Mode.tabs(chartable: false, documents: false) == [.grid])
    #expect(Mode.pickerTabs(chartable: false, documents: false) == nil)
    #expect(Mode.pickerTabs(chartable: false, documents: true) == [.grid, .documents])
  }
}
