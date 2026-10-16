// MongoSchemaAnalyzer.swift
// Field statistics over a sample of MongoDB documents, for the collection's Schema tab. One pass
// per document, state kept per field node, a node being one key under one parent node (the top
// level has none), so a key holding a dot or an empty key never merges with another field:
//
// - Paths: top-level keys, keys of embedded documents and keys of documents inside arrays (no
//   index in the path), down to three segments. Scalar array elements get no path of their own;
//   they are counted in the array field's `elementTypes`. The dotted `path` is for display only;
//   `keyPath` (the keys one by one) identifies a field.
// - Presence: every document met at a path (top-level document, embedded document, array
//   element document) is one parent occurrence of its keys. A parent occurrence lacking the key
//   counts as type "undefined"; a null or missing parent is not an occurrence.
// - Types are MongoDB's `$type` aliases (`MongoBSONMapping.typeName`).
// - Values: top values for strings (raw text), numbers and bools (mongosh text), a string never
//   counted with a number or bool of the same text; texts over 256 characters are cut (no exact
//   value to filter on then); number range over int, long, double and decimal (when its text
//   reads as a finite Double); date range, weekday and hour histograms for dates and ObjectId
//   timestamps, in the injected calendar.
// - Samples: up to five distinct values per field (objects excluded, their fields are listed),
//   first seen first, as mongosh text.
//
// `sampleCommand` builds the mongosh text that reads the sample, refusing a filter that would
// run JavaScript on the server.

import Foundation

nonisolated enum MongoSchemaAnalyzer {
  /// Deepest dotted path listed (segments).
  static let maxDepth = 3
  /// Top values kept per field.
  static let topValueLimit = 20
  /// Sample values kept per field.
  static let sampleLimit = 5
  /// Type name of a parent occurrence lacking the field.
  static let undefinedTypeName = "undefined"
  /// Characters kept of a counted value or sample text; longer texts end with "…".
  static let valueTextLimit = 256

  nonisolated struct TypeShare: Equatable, Sendable {
    let name: String
    let count: Int
  }

  nonisolated struct ValueShare: Equatable, Sendable {
    /// Display text: raw text for a string, mongosh text for a number or bool (cut at 256).
    let value: String
    let count: Int
    /// The exact value to filter on (`.string` apart from numbers of the same text); nil when
    /// the counted text was cut.
    let filterValue: MongoValue?
  }

  nonisolated struct Field: Equatable, Sendable, Identifiable {
    /// The keys from the top level, one per segment. Unique per field, unlike `path`: a top-level
    /// key "a.b" and the key "b" inside "a" share the path "a.b".
    let keyPath: [String]
    var id: [String] { keyPath }
    /// The keys joined with dots, for display.
    var path: String { keyPath.joined(separator: ".") }
    /// The parent field's display path, "" for a top-level key.
    var parentPath: String { keyPath.dropLast().joined(separator: ".") }
    /// The field's own key.
    var name: String { keyPath.last ?? "" }
    /// Number of path segments (1 for a top-level key).
    var depth: Int { keyPath.count }
    /// Parent occurrences that have the key.
    let presentCount: Int
    /// Count descending, then name ascending; includes "undefined".
    let types: [TypeShare]
    /// Types of the elements, counted one by one; nil when the field was never an array.
    let elementTypes: [TypeShare]?
    /// Strings, numbers and bools: count descending, then value ascending, at most 20.
    let topValues: [ValueShare]
    /// Distinct string, number and bool values; nil when there are none.
    let distinctCount: Int?
    let numberRange: ClosedRange<Double>?
    let dateRange: ClosedRange<Date>?
    /// Seven buckets, Sunday first (calendar weekday - 1); nil without dates.
    let weekdays: [Int]?
    /// Twenty-four buckets by calendar hour; nil without dates.
    let hours: [Int]?
    /// Distinct values in mongosh text, first seen first.
    let samples: [String]
  }

  nonisolated struct Report: Equatable, Sendable {
    /// Documents analyzed.
    let sampleSize: Int
    /// Tree order: top-level fields first seen first (`_id` first), children after their parent.
    let fields: [Field]
  }

  /// A sample filter that cannot be sent.
  nonisolated enum SampleCommandError: Error, Equatable, Sendable, LocalizedError {
    /// The filter uses `$where`, `$function` or `$accumulator`.
    case serverSideJavaScript
    /// The filter does not parse or is not a document.
    case invalidFilter(DataViewerState.DocumentFilterError)

    var errorDescription: String? {
      switch self {
      case .serverSideJavaScript:
        "Server-side JavaScript ($where, $function, $accumulator) is not allowed in a schema sample filter."
      case .invalidFilter(let error): error.errorDescription
      }
    }
  }

  // MARK: - Analysis

  static func analyze(_ documents: [MongoValue], calendar: Calendar) -> Report {
    var state = State(calendar: calendar)
    var sampleSize = 0
    for document in documents {
      guard case .document(let fields) = document else { continue }
      sampleSize += 1
      state.visit(fields, under: nil)
    }
    return Report(sampleSize: sampleSize, fields: state.fields())
  }

  // MARK: - Sample command

  /// `db.getCollection(<name>).aggregate([ { $sample: { size: N } } ])` for a blank or `{}`
  /// filter, else `db.getCollection(<name>).find(<filter>).limit(N)`. Throws for a filter that
  /// does not parse, is not a document, or uses server-side JavaScript.
  static func sampleCommand(collection: String, filterText: String, size: Int) throws -> String {
    let target = "db.getCollection(\(MongoRelaxedJSON.render(.string(collection), as: .mongosh)))"
    let limit = MongoRelaxedJSON.render(.int32(Int32(clamping: size)), as: .mongosh)
    let text: String
    let filter: MongoValue?
    switch DataViewerState.documentFilterValue(filterText) {
    case .success(let value): filter = value
    case .failure(let error): throw SampleCommandError.invalidFilter(error)
    }
    if let filter {
      let rendered = MongoRelaxedJSON.render(filter, as: .mongosh)
      text = "\(target).find(\(rendered)).limit(\(limit))"
    } else {
      text = "\(target).aggregate([ { $sample: { size: \(limit) } } ])"
    }
    guard !MongoCommandClassifier.usesServerSideJavaScript(text) else {
      throw SampleCommandError.serverSideJavaScript
    }
    return text
  }

  /// `text` cut to `valueTextLimit` characters, "…" appended when cut.
  fileprivate static func capped(_ text: String) -> String {
    guard let end = text.index(text.startIndex, offsetBy: valueTextLimit, limitedBy: text.endIndex),
      end < text.endIndex
    else { return text }
    return text[..<end] + "…"
  }
}

// MARK: - Accumulation

extension MongoSchemaAnalyzer {
  /// A counted value: strings apart from numbers and bools of the same text ("5" and 5).
  fileprivate nonisolated struct ValueKey: Hashable {
    let isString: Bool
    let text: String
  }

  /// How often a value was counted, and its exact value (nil when its text was cut).
  fileprivate nonisolated struct ValueCount {
    var count: Int
    let filterValue: MongoValue?
  }

  /// Everything gathered for one field node.
  fileprivate nonisolated struct Accumulator {
    /// The parent node's index, nil for a top-level key.
    let parent: Int?
    let keyPath: [String]
    var typeCounts: [String: Int] = [:]
    var elementTypeCounts: [String: Int]?
    var valueCounts: [ValueKey: ValueCount] = [:]
    var numberRange: ClosedRange<Double>?
    var dateRange: ClosedRange<Date>?
    var weekdays: [Int]?
    var hours: [Int]?
    var samples: [String] = []
    var sampleSet: Set<String> = []
    /// Documents met at this field (embedded or array element): parent occurrences of its keys.
    var documentCount = 0
    /// Child node indices, first seen first.
    var children: [Int] = []

    init(parent: Int?, keyPath: [String]) {
      self.parent = parent
      self.keyPath = keyPath
    }

    var depth: Int { keyPath.count }

    mutating func addNumber(_ number: Double) {
      guard number.isFinite else { return }
      numberRange =
        numberRange.map { min($0.lowerBound, number)...max($0.upperBound, number) }
        ?? number...number
    }

    mutating func addDate(_ date: Date, calendar: Calendar) {
      dateRange =
        dateRange.map { min($0.lowerBound, date)...max($0.upperBound, date) }
        ?? date...date
      var weekdays = self.weekdays ?? Array(repeating: 0, count: 7)
      var hours = self.hours ?? Array(repeating: 0, count: 24)
      let components = calendar.dateComponents([.weekday, .hour], from: date)
      if let weekday = components.weekday, (1...7).contains(weekday) { weekdays[weekday - 1] += 1 }
      if let hour = components.hour, (0..<24).contains(hour) { hours[hour] += 1 }
      self.weekdays = weekdays
      self.hours = hours
    }

    /// One more `value` counted under `key`; the first exact value of the key is kept.
    mutating func addValue(_ value: MongoValue, as key: ValueKey, cut: Bool) {
      valueCounts[key, default: ValueCount(count: 0, filterValue: cut ? nil : value)].count += 1
    }

    mutating func addSample(_ value: MongoValue) {
      guard samples.count < MongoSchemaAnalyzer.sampleLimit else { return }
      let text = MongoSchemaAnalyzer.capped(MongoRelaxedJSON.render(value, as: .mongosh))
      guard sampleSet.insert(text).inserted else { return }
      samples.append(text)
    }
  }

  fileprivate nonisolated struct State {
    /// One key under one parent node (nil: the top level).
    struct NodeKey: Hashable {
      let parent: Int?
      let key: String
    }

    let calendar: Calendar
    var nodes: [Accumulator] = []
    var nodeIndex: [NodeKey: Int] = [:]
    /// Top-level node indices, first seen first.
    var roots: [Int] = []
    /// Top-level documents met.
    var documentCount = 0

    init(calendar: Calendar) {
      self.calendar = calendar
    }

    /// One document met at node `parent` (nil: a top-level document). Keys deeper than
    /// `maxDepth` are skipped.
    mutating func visit(_ fields: [MongoValue.Field], under parent: Int?) {
      let depth: Int
      if let parent {
        nodes[parent].documentCount += 1
        depth = nodes[parent].depth
      } else {
        documentCount += 1
        depth = 0
      }
      guard depth < MongoSchemaAnalyzer.maxDepth else { return }
      var seen = Set<String>()
      for field in fields where seen.insert(field.key).inserted {
        add(field.value, at: node(field.key, under: parent))
      }
    }

    /// The node of `key` under `parent`, created on first sight.
    private mutating func node(_ key: String, under parent: Int?) -> Int {
      let nodeKey = NodeKey(parent: parent, key: key)
      if let index = nodeIndex[nodeKey] { return index }
      let index = nodes.count
      let keyPath = (parent.map { nodes[$0].keyPath } ?? []) + [key]
      nodes.append(Accumulator(parent: parent, keyPath: keyPath))
      nodeIndex[nodeKey] = index
      if let parent {
        nodes[parent].children.append(index)
      } else {
        roots.append(index)
      }
      return index
    }

    private mutating func add(_ value: MongoValue, at node: Int) {
      let type = MongoBSONMapping.typeName(value)
      nodes[node].typeCounts[type, default: 0] += 1
      switch value {
      case .document(let fields):
        if type == "object" {
          enter(fields, at: node)
        } else {
          nodes[node].addSample(value)
        }
        return
      case .array(let items):
        var counts = nodes[node].elementTypeCounts ?? [:]
        for item in items {
          let itemType = MongoBSONMapping.typeName(item)
          counts[itemType, default: 0] += 1
          if itemType == "object", case .document(let fields) = item {
            enter(fields, at: node)
          }
        }
        nodes[node].elementTypeCounts = counts
      case .string(let text):
        let capped = MongoSchemaAnalyzer.capped(text)
        nodes[node].addValue(
          value, as: ValueKey(isString: true, text: capped), cut: capped != text)
      case .int32(let number):
        addValue(value, at: node)
        nodes[node].addNumber(Double(number))
      case .int64(let number):
        addValue(value, at: node)
        nodes[node].addNumber(Double(number))
      case .double(let number):
        addValue(value, at: node)
        nodes[node].addNumber(number)
      case .decimal128(let text):
        addValue(value, at: node)
        if let number = Double(text) { nodes[node].addNumber(number) }
      case .bool:
        addValue(value, at: node)
      case .date(let millis):
        let date = Date(timeIntervalSince1970: Double(millis) / 1000)
        let calendar = self.calendar
        nodes[node].addDate(date, calendar: calendar)
      case .objectId(let id):
        if let seconds = UInt32(id.hex.prefix(8), radix: 16) {
          let date = Date(timeIntervalSince1970: Double(seconds))
          let calendar = self.calendar
          nodes[node].addDate(date, calendar: calendar)
        }
      default:
        break
      }
      nodes[node].addSample(value)
    }

    /// An embedded or array element document at `node`, entered while its keys stay listed.
    private mutating func enter(_ fields: [MongoValue.Field], at node: Int) {
      guard nodes[node].depth < MongoSchemaAnalyzer.maxDepth else { return }
      visit(fields, under: node)
    }

    /// A number or bool counted by its mongosh text.
    private mutating func addValue(_ value: MongoValue, at node: Int) {
      let rendered = MongoRelaxedJSON.render(value, as: .mongosh)
      let text = MongoSchemaAnalyzer.capped(rendered)
      nodes[node].addValue(value, as: ValueKey(isString: false, text: text), cut: text != rendered)
    }

    // MARK: Report

    /// Depth first from the roots. Every node is listed once: a node is a child of one parent
    /// only, and `visited` stops any revisit.
    func fields() -> [Field] {
      var result: [Field] = []
      result.reserveCapacity(nodes.count)
      var roots = self.roots
      if let index = roots.firstIndex(where: { nodes[$0].keyPath == ["_id"] }), index > 0 {
        roots.insert(roots.remove(at: index), at: 0)
      }
      var visited = Set<Int>()
      var stack = Array(roots.reversed())
      while let node = stack.popLast() {
        guard visited.insert(node).inserted else { continue }
        result.append(field(nodes[node]))
        stack.append(contentsOf: nodes[node].children.reversed())
      }
      return result
    }

    private func field(_ accumulator: Accumulator) -> Field {
      let presentCount = accumulator.typeCounts.values.reduce(0, +)
      let parentCount = accumulator.parent.map { nodes[$0].documentCount } ?? documentCount
      let missing = max(0, parentCount - presentCount)
      var typeCounts = accumulator.typeCounts
      if missing > 0 { typeCounts[MongoSchemaAnalyzer.undefinedTypeName, default: 0] += missing }
      let values = accumulator.valueCounts
        .sorted { lhs, rhs in
          if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
          if lhs.key.text != rhs.key.text { return lhs.key.text < rhs.key.text }
          return !lhs.key.isString && rhs.key.isString
        }
        .prefix(MongoSchemaAnalyzer.topValueLimit)
        .map {
          ValueShare(value: $0.key.text, count: $0.value.count, filterValue: $0.value.filterValue)
        }
      return Field(
        keyPath: accumulator.keyPath, presentCount: presentCount,
        types: Self.shares(typeCounts),
        elementTypes: accumulator.elementTypeCounts.map(Self.shares),
        topValues: values, distinctCount: values.isEmpty ? nil : accumulator.valueCounts.count,
        numberRange: accumulator.numberRange, dateRange: accumulator.dateRange,
        weekdays: accumulator.weekdays, hours: accumulator.hours, samples: accumulator.samples)
    }

    /// Count descending, then name ascending.
    private static func shares(_ counts: [String: Int]) -> [TypeShare] {
      counts
        .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        .map { TypeShare(name: $0.key, count: $0.value) }
    }
  }
}
