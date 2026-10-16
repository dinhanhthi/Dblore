// DocumentTreeModel.swift
// The Documents view of a MongoDB result: documents rebuilt from the grid rows and the column BSON
// type names (Key decision d), shown as one card per document. A card starts with its top-level
// fields shown and its nested documents and arrays collapsed; the visible rows page large
// containers. Staged inserts follow the stored documents as extra cards.
//
// Edit info: each row has its raw key path from the document. A primitive scalar
// (`NotebookViewModel.primitiveDocumentTypes`) has an edit type and an edit text when its BSON type
// is exact: always for nested values (parsed from canonical Extended JSON), for a top-level field
// only when its column has that type (a `mixed` column infers it from the cell). Never for `_id`
// or anything under it, nor for staged inserts.
//
// Rebuild rules (the grid cells are the only source, so some details are not recoverable):
// - A `.null` cell is a missing key. `MongoBSONMapping.row` writes `.null` for an explicit null
//   and for an absent key alike; the tree shows the document's shape, so a key absent from most
//   documents of a sparse collection does not show up in every one. Explicit top-level nulls are
//   therefore not shown (nulls inside documents and arrays are, as they come from `.json` cells).
// - Fields follow the result columns (`_id` first, then first-seen order), not each document's
//   stored order; a duplicate top-level key keeps its first value.
// - `.json` cells (documents, arrays, JavaScript code) are parsed back with `MongoRelaxedJSON`
//   (canonical Extended JSON, exact). Text over `MongoRelaxedJSON.maxInputBytes` or malformed
//   text shows as a string.
// - Scalars are typed by their column (`int`, `long`, `decimal`, `objectId`, `regex`, ...).
//   A `mixed` column infers the type from the cell: an integer is int32 when it fits, else int64;
//   text stays a string (an ObjectId or Decimal128 there cannot be told from a string).
// - Binary keeps its bytes but not its subtype (the grid cell has none): it reads as subtype 0.
//
// Row keys and previews are display text: cut to `previewLimit` characters, with control, bidi
// and line separator characters written as `\uXXXX`. The copy texts are exact.

import Foundation

/// Identity of a tree row: the document position and the child positions below it (field order
/// for documents, item index for arrays). Positions, not keys: documents may repeat a key.
nonisolated struct DocumentTreeNodeID: Hashable, Sendable {
  let document: Int
  let indexes: [Int]
  /// The "show more" row under the container `indexes` points to.
  var isShowMore = false
}

/// One visible row of the tree.
nonisolated struct DocumentTreeNode: Identifiable, Equatable, Sendable {
  nonisolated enum Kind: Equatable, Sendable {
    case value
    /// Loads the next page of the parent's children; `remaining` children are not shown yet.
    case showMore(remaining: Int)
  }

  let id: DocumentTreeNodeID
  let kind: Kind
  /// 0 for a document (the card header), 1 for its fields, ...
  let depth: Int
  /// Field key, array index, or for a document its `_id` (mongosh notation) or `(position)`.
  /// Display text (see the file header).
  let key: String
  /// mongosh notation for scalars, `{n fields}` / `[n items]` for documents and arrays.
  /// Display text (see the file header).
  let preview: String
  /// MongoDB `$type` alias (`MongoBSONMapping.typeName`); empty for a "show more" row.
  let typeName: String
  /// Dot path from the document (`items.3.sku`), keys as they are; empty for a document itself.
  /// Copy Path quotes the keys (`DocumentTreeModel.copyPathText`).
  let path: String
  /// Raw keys from the document (array indexes as decimal digits); empty for a document itself.
  let keys: [String]
  /// `$type` alias of a value edited as text (see the file header); nil otherwise.
  let editType: String?
  let isExpandable: Bool
  let isExpanded: Bool
}

/// One document of the Documents view: its header row and the visible rows below it.
nonisolated struct DocumentTreeCard: Identifiable, Equatable, Sendable {
  /// Document position: page index for a stored document, `storedCount + n` for a staged insert.
  let document: Int
  /// `nodes[0]` is the document (depth 0), the rest its visible fields and items.
  let nodes: [DocumentTreeNode]
  let isStaged: Bool

  var id: Int { document }
}

/// Documents of a result plus the expanded and paged state of their tree.
nonisolated struct DocumentTreeModel: Sendable {
  /// Children shown per page of a document or array.
  static let pageSize = 100
  /// Longest scalar preview, in characters (the copy texts are never cut).
  static let previewLimit = 200

  /// The stored documents, then the staged inserts (`setStagedInserts`).
  private(set) var documents: [MongoValue]
  /// Stored documents: the result rows. Positions from here on are staged inserts.
  let storedCount: Int
  /// BSON type per top-level column (first column of a name), for the edit types.
  private let columnTypes: [String: String]
  /// Expanded documents and arrays below a document; documents themselves are in `collapsed`.
  private var expanded: Set<DocumentTreeNodeID> = []
  /// Collapsed documents (cards start expanded).
  private var collapsed: Set<DocumentTreeNodeID> = []
  /// Children shown per expanded container, when more than the first page.
  private var shownCounts: [DocumentTreeNodeID: Int] = [:]
  /// The rows to draw, one card per document: the document and the shown children of its
  /// expanded containers. A change of expanded or paged state rebuilds only its own card, so a
  /// view reads them for free.
  private(set) var cards: [DocumentTreeCard] = []
  /// Every card's rows, in order.
  var visibleNodes: [DocumentTreeNode] { cards.flatMap(\.nodes) }

  /// `previous` (the model of an earlier result of the same view) hands over its expanded,
  /// collapsed and paged state by position; positions that no longer exist are ignored.
  init(columns: [ColumnInfo], rows: [[CellValue]], carrying previous: DocumentTreeModel? = nil) {
    documents = rows.map { Self.document(row: $0, columns: columns) }
    storedCount = rows.count
    columnTypes = Dictionary(
      columns.map { ($0.name, $0.type) }, uniquingKeysWith: { first, _ in first })
    if let previous {
      expanded = previous.expanded
      collapsed = previous.collapsed
      shownCounts = previous.shownCounts
    }
    rebuildCards()
  }

  // MARK: - Rebuild

  /// The document of one result row. Null cells are missing keys (see the file header).
  static func document(row: [CellValue], columns: [ColumnInfo]) -> MongoValue {
    var fields: [MongoValue.Field] = []
    for (index, column) in columns.enumerated() where index < row.count {
      if let value = value(of: row[index], columnType: column.type) {
        fields.append(MongoValue.Field(column.name, value))
      }
    }
    return .document(fields)
  }

  /// The value of a grid cell in a column of BSON type `columnType`; nil for a null cell.
  static func value(of cell: CellValue, columnType: String) -> MongoValue? {
    switch (columnType, cell) {
    case (_, .null): return nil
    case ("long", .int(let number)): return .int64(Int64(number))
    case ("double", .int(let number)): return .double(Double(number))
    case ("decimal", .string(let text)) where MongoRelaxedJSON.Lexer.isDecimal(text):
      return .decimal128(text)
    case ("objectId", .string(let text)):
      return MongoObjectId(hex: text).map(MongoValue.objectId) ?? .string(text)
    case ("regex", .string(let text)), ("timestamp", .string(let text)),
      ("minKey", .string(let text)), ("maxKey", .string(let text)):
      // Written in mongosh notation, which parses back exactly
      guard let parsed = try? MongoRelaxedJSON.parse(text),
        MongoBSONMapping.typeName(parsed) == columnType
      else { return .string(text) }
      return parsed
    default: return inferred(cell)
    }
  }

  /// The value a cell stands for without its column type (`mixed`, or a type it does not match).
  private static func inferred(_ cell: CellValue) -> MongoValue {
    switch cell {
    case .null: .null
    case .int(let number): Int32(exactly: number).map(MongoValue.int32) ?? .int64(Int64(number))
    case .double(let number): .double(number)
    case .bool(let flag): .bool(flag)
    case .string(let text): .string(text)
    case .date(let date): .date(MongoBSONMapping.millis(of: date))
    case .data(let data): .binary(subtype: 0, data: data)
    case .json(let text): (try? MongoRelaxedJSON.parse(text)) ?? .string(text)
    }
  }

  // MARK: - Tree state

  /// Expands a collapsed document or array, collapses an expanded one.
  mutating func toggleExpansion(_ id: DocumentTreeNodeID) {
    if id.indexes.isEmpty {
      if collapsed.remove(id) == nil { collapsed.insert(id) }
    } else if expanded.remove(id) == nil {
      expanded.insert(id)
    }
    rebuildCard(id.document)
  }

  /// Replaces the staged inserts shown after the stored documents; the stored documents are not
  /// rebuilt.
  mutating func setStagedInserts(_ inserts: [MongoValue]) {
    documents = Array(documents.prefix(storedCount)) + inserts
    cards =
      Array(cards.prefix(storedCount))
      + inserts.indices.map { card(at: storedCount + $0) }
  }

  /// Whether the document at `document` is a staged insert.
  func isStaged(document: Int) -> Bool {
    document >= storedCount
  }

  /// Shows the next page of the container whose "show more" row is `id`.
  mutating func showMore(_ id: DocumentTreeNodeID) {
    let parent = DocumentTreeNodeID(document: id.document, indexes: id.indexes)
    guard let count = value(at: parent).map(Self.childCount) else { return }
    shownCounts[parent] = min(shownCount(parent) + Self.pageSize, count)
    rebuildCard(parent.document)
  }

  private func shownCount(_ id: DocumentTreeNodeID) -> Int {
    shownCounts[id] ?? Self.pageSize
  }

  private func isExpanded(_ id: DocumentTreeNodeID) -> Bool {
    id.indexes.isEmpty ? !collapsed.contains(id) : expanded.contains(id)
  }

  private mutating func rebuildCards() {
    cards = documents.indices.map(card(at:))
  }

  private mutating func rebuildCard(_ position: Int) {
    guard cards.indices.contains(position) else { return }
    cards[position] = card(at: position)
  }

  private func card(at position: Int) -> DocumentTreeCard {
    var nodes: [DocumentTreeNode] = []
    let document = documents[position]
    let id = DocumentTreeNodeID(document: position, indexes: [])
    let key = Self.documentKey(document, position: position)
    append(document, id: id, key: key, path: "", keys: [], into: &nodes)
    return DocumentTreeCard(
      document: position, nodes: nodes, isStaged: isStaged(document: position))
  }

  private func append(
    _ value: MongoValue, id: DocumentTreeNodeID, key: String, path: String, keys: [String],
    into nodes: inout [DocumentTreeNode]
  ) {
    let isContainer = Self.isContainer(value)
    let isExpanded = isContainer && isExpanded(id)
    nodes.append(
      DocumentTreeNode(
        id: id, kind: .value, depth: id.indexes.count, key: key, preview: Self.preview(value),
        typeName: MongoBSONMapping.typeName(value), path: path, keys: keys,
        editType: editType(of: value, document: id.document, keys: keys),
        isExpandable: isContainer, isExpanded: isExpanded))
    guard isExpanded else { return }
    let count = Self.childCount(of: value)
    let shown = min(shownCount(id), count)
    for index in 0..<shown {
      guard let child = Self.child(of: value, at: index) else { break }
      let childPath = path.isEmpty ? child.key : path + "." + child.key
      let childID = DocumentTreeNodeID(document: id.document, indexes: id.indexes + [index])
      append(
        child.value, id: childID, key: Self.displayText(child.key), path: childPath,
        keys: keys + [child.key], into: &nodes)
    }
    if shown < count {
      nodes.append(
        DocumentTreeNode(
          id: DocumentTreeNodeID(document: id.document, indexes: id.indexes, isShowMore: true),
          kind: .showMore(remaining: count - shown), depth: id.indexes.count + 1, key: "",
          preview: "", typeName: "", path: path, keys: keys, editType: nil, isExpandable: false,
          isExpanded: false))
    }
  }

  // MARK: - Edit

  /// The value of a row, for the editor sheet; nil for a "show more" row.
  func currentValue(_ id: DocumentTreeNodeID) -> MongoValue? {
    id.isShowMore ? nil : value(at: id)
  }

  /// The text an inline edit starts from, in the form `NotebookViewModel.parsedDocumentValue`
  /// reads back to the same value (never the cut preview); nil for a row without an edit type.
  func editText(_ id: DocumentTreeNodeID) -> String? {
    guard !id.isShowMore, let entry = entry(at: id),
      let type = editType(of: entry.value, document: id.document, keys: entry.keys)
    else { return nil }
    let text: String? =
      switch entry.value {
      case .string(let text): text
      case .int32(let number): String(number)
      case .int64(let number): String(number)
      case .double(let number): number.description
      case .bool(let flag): flag ? "true" : "false"
      case .date(let millis): Self.isoText(millis: millis)
      case .objectId(let id): id.hex
      default: nil
      }
    // A date the ISO 8601 text cannot hold (far outside years 1...9999) is not edited as text
    guard let text,
      (try? NotebookViewModel.parsedDocumentValue(text, columnType: type)) == entry.value
    else { return nil }
    return text
  }

  /// See the file header.
  private func editType(of value: MongoValue, document: Int, keys: [String]) -> String? {
    guard !isStaged(document: document), let field = keys.first, field != "_id" else { return nil }
    let type = MongoBSONMapping.typeName(value)
    guard NotebookViewModel.primitiveDocumentTypes.contains(type) else { return nil }
    guard keys.count == 1 else { return type }
    let columnType = columnTypes[field]
    return columnType == type && columnType != MongoBSONMapping.mixedTypeName ? type : nil
  }

  /// `millis` as ISO 8601 UTC with milliseconds (`2023-11-14T22:13:20.123Z`). Formatted from the
  /// whole seconds, so the binary fraction of a `Date` cannot round the milliseconds down.
  private static func isoText(millis: Int64) -> String? {
    var (seconds, remainder) = millis.quotientAndRemainder(dividingBy: 1000)
    if remainder < 0 {
      seconds -= 1
      remainder += 1000
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let text = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    guard text.hasSuffix("Z") else { return nil }
    return String(text.dropLast()) + "." + String(format: "%03d", Int(remainder)) + "Z"
  }

  // MARK: - Copy

  /// Scalars as shown (strings without quotes); documents and arrays as canonical Extended JSON.
  func copyValueText(_ id: DocumentTreeNodeID) -> String? {
    guard !id.isShowMore, let value = value(at: id) else { return nil }
    switch value {
    case .string(let text): return text
    case .document, .array: return MongoRelaxedJSON.render(value, as: .canonicalExtendedJSON)
    default: return MongoRelaxedJSON.render(value, as: .mongosh)
    }
  }

  /// The path of a field or item; nil for a document itself. Segments are joined with `.`: an
  /// array index as its digits, a key matching `[A-Za-z_][A-Za-z0-9_]*` as it is, any other key
  /// (dots, digits only, `$` first, empty, spaces, other characters) as a JSON string literal
  /// with control, bidi and line separator characters as `\uXXXX`: `items.3.sku`,
  /// `"a.b".c`, `"3".0`, `"$x"`. A bare segment of digits is always an index.
  func copyPathText(_ id: DocumentTreeNodeID) -> String? {
    guard !id.isShowMore, !id.indexes.isEmpty, var value = documents[safe: id.document] else {
      return nil
    }
    var segments: [String] = []
    for index in id.indexes {
      guard let child = Self.child(of: value, at: index) else { return nil }
      if case .array = value {
        segments.append(String(index))
      } else {
        segments.append(Self.pathSegment(child.key))
      }
      value = child.value
    }
    return segments.joined(separator: ".")
  }

  /// The whole document the row belongs to, as canonical Extended JSON.
  func copyDocumentText(_ id: DocumentTreeNodeID) -> String? {
    documents[safe: id.document].map { MongoRelaxedJSON.render($0, as: .canonicalExtendedJSON) }
  }

  // MARK: - Helpers

  private func value(at id: DocumentTreeNodeID) -> MongoValue? {
    entry(at: id)?.value
  }

  /// The raw keys from the document to `id`, and its value.
  private func entry(at id: DocumentTreeNodeID) -> (keys: [String], value: MongoValue)? {
    guard var value = documents[safe: id.document] else { return nil }
    var keys: [String] = []
    for index in id.indexes {
      guard let child = Self.child(of: value, at: index) else { return nil }
      keys.append(child.key)
      value = child.value
    }
    return (keys, value)
  }

  private static func isContainer(_ value: MongoValue) -> Bool {
    switch value {
    case .document, .array: true
    default: false
    }
  }

  private static func childCount(of value: MongoValue) -> Int {
    switch value {
    case .document(let fields): fields.count
    case .array(let items): items.count
    default: 0
    }
  }

  /// Child `index` of a document (its field key) or an array (the index as key).
  private static func child(
    of value: MongoValue, at index: Int
  ) -> (key: String, value: MongoValue)? {
    switch value {
    case .document(let fields): fields[safe: index].map { ($0.key, $0.value) }
    case .array(let items): items[safe: index].map { (String(index), $0) }
    default: nil
    }
  }

  /// A document's row key: its scalar `_id` in mongosh notation, else its 1-based position.
  private static func documentKey(_ document: MongoValue, position: Int) -> String {
    if case .document(let fields) = document,
      let id = fields.first(where: { $0.key == "_id" })?.value, !isContainer(id)
    {
      return preview(id)
    }
    return "(\(position + 1))"
  }

  private static func preview(_ value: MongoValue) -> String {
    switch value {
    case .document(let fields): return "{\(fields.count) field\(fields.count == 1 ? "" : "s")}"
    case .array(let items): return "[\(items.count) item\(items.count == 1 ? "" : "s")]"
    default:
      return displayText(MongoRelaxedJSON.render(previewed(value), as: .mongosh))
    }
  }

  /// `value` with its text or bytes cut to about what a preview shows, so a large string or
  /// binary is not rendered whole. A cut value still renders past `previewLimit`.
  private static func previewed(_ value: MongoValue) -> MongoValue {
    switch value {
    case .string(let text): .string(String(text.prefix(previewLimit)))
    case .decimal128(let text): .decimal128(String(text.prefix(previewLimit)))
    case .regex(let pattern, let options):
      .regex(
        pattern: String(pattern.prefix(previewLimit)), options: String(options.prefix(previewLimit))
      )
    // Whole base64 groups: the encoded prefix is a prefix of the full encoding
    case .binary(let subtype, let data):
      .binary(subtype: subtype, data: Data(data.prefix(previewLimit / 3 * 3 + 3)))
    default: value
    }
  }

  /// `text` for a row: at most `previewLimit` characters (then "…"), with control, bidi and line
  /// separator characters as `\uXXXX`, so they cannot reorder or break the row.
  private static func displayText(_ text: String) -> String {
    let escaped = escapingInvisibles(String(text.prefix(previewLimit + 1)))
    guard
      let end = escaped.index(
        escaped.startIndex, offsetBy: previewLimit, limitedBy: escaped.endIndex),
      end < escaped.endIndex
    else { return escaped }
    return String(escaped[..<end]) + "…"
  }

  /// A Copy Path segment for a document key (see `copyPathText`).
  private static func pathSegment(_ key: String) -> String {
    func isWordStart(_ byte: UInt8) -> Bool {
      (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || byte == UInt8(ascii: "_")
    }
    guard let first = key.utf8.first, isWordStart(first),
      key.utf8.allSatisfy({ isWordStart($0) || (0x30...0x39).contains($0) })
    else { return escapingInvisibles(MongoRelaxedJSON.render(.string(key), as: .mongosh)) }
    return key
  }

  private static func escapingInvisibles(_ text: String) -> String {
    guard text.unicodeScalars.contains(where: isInvisible) else { return text }
    var result = ""
    for scalar in text.unicodeScalars {
      if isInvisible(scalar) {
        let hex = String(scalar.value, radix: 16)
        result += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
      } else {
        result.unicodeScalars.append(scalar)
      }
    }
    return result
  }

  /// Controls (C0, DEL, C1), bidi marks, embeddings, overrides and isolates, line separators
  private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0..<0x20, 0x7F...0x9F, 0x061C, 0x200E, 0x200F, 0x2028...0x202E, 0x2066...0x2069: true
    default: false
    }
  }
}

extension Array {
  fileprivate nonisolated subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
