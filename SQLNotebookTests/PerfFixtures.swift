// PerfFixtures.swift
// Deterministic fixtures, an offscreen editor host and a tiny reporter for the baseline
// benchmarks (PerformanceBenchmarkTests). No randomness: a seeded PRNG drives every fixture.

import AppKit
import Foundation
import SwiftUI

@testable import SQLNotebook

/// SplitMix64: small, seedable and stable across runs and platforms
struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

enum PerfFixtures {
  static let seed: UInt64 = 0x5EED_5EED

  private static let keywords = [
    "SELECT", "FROM", "WHERE", "JOIN", "LEFT", "INNER", "GROUP BY", "ORDER BY", "HAVING",
    "INSERT INTO", "UPDATE", "DELETE", "CREATE TABLE", "ALTER", "AND", "OR", "NOT", "AS", "ON",
    "LIMIT", "UNION", "DISTINCT", "CASE", "WHEN", "THEN", "ELSE", "END",
  ]
  private static let functions = ["count", "sum", "avg", "max", "min", "coalesce", "lower", "now"]
  private static let types = ["integer", "text", "varchar", "boolean", "timestamp", "numeric"]
  private static let words = [
    "users", "orders", "items", "id", "name", "email", "total", "created_at", "status", "amount",
  ]

  /// About 2,000 lines and 100 KB of SQL: keywords, functions before "(", types, numbers, "--"
  /// and multi-line block comments, single-quoted strings, dollar-quoted bodies and one line
  /// with CJK and emoji
  static func sql2kLines() -> String {
    var rng = SeededGenerator(seed: seed)
    var lines: [String] = []
    lines.reserveCapacity(2000)
    func pick(_ list: [String], _ rng: inout SeededGenerator) -> String {
      list[Int(rng.next() % UInt64(list.count))]
    }
    func num(_ rng: inout SeededGenerator) -> Int { Int(rng.next() % 100_000) }

    while lines.count < 2000 {
      let n = lines.count
      if n == 1000 {
        lines.append("-- 日本語のコメント 中文 한국어 emoji 😀🚀 SELECT '日本語' AS 名前, '🎉' AS e;")
        continue
      }
      switch n % 50 {
      case 10:
        lines.append("/* block comment start \(num(&rng))")
        lines.append("   SELECT inside comment WHERE 1 = \(num(&rng))")
        lines.append("   still a comment with 'quote' and count(*) */")
      case 30:
        lines.append("CREATE FUNCTION f\(n)() RETURNS integer AS $$")
        lines.append("  DECLARE v integer := \(num(&rng));")
        lines.append("  BEGIN RETURN v + \(num(&rng)); END;")
        lines.append("$$ LANGUAGE plpgsql;")
      case 5, 25, 45:
        lines.append("-- \(pick(words, &rng)) note \(num(&rng)) and more filler text here")
      default:
        let a = pick(words, &rng)
        let b = pick(words, &rng)
        switch Int(rng.next() % 4) {
        case 0:
          lines.append(
            "\(pick(keywords, &rng)) \(pick(functions, &rng))(\(a)), \(b) FROM \(a) WHERE \(b) > \(num(&rng));"
          )
        case 1:
          lines.append(
            "\(pick(keywords, &rng)) \(a) \(pick(types, &rng)), \(b) \(pick(types, &rng)) DEFAULT \(num(&rng)).5;"
          )
        case 2:
          lines.append(
            "\(pick(keywords, &rng)) \(a) = 'value \(num(&rng)) it''s ok' AND \(b) LIKE '%\(a)%'; -- trailing"
          )
        default:
          lines.append(
            "\(pick(keywords, &rng)) \(pick(functions, &rng))(\(a)) AS t\(num(&rng)), \(pick(functions, &rng))(\(b)) FROM \(b) JOIN \(a) ON \(a).id = \(b).id"
          )
        }
      }
    }
    return lines.prefix(2000).joined(separator: "\n")
  }

  /// 1000 rows x 30 columns mixing string, int, double, date, null and json cells
  static func cellResult(rows rowCount: Int = 1000, columns columnCount: Int = 30) -> CellResult {
    var rng = SeededGenerator(seed: seed &+ 1)
    let columns = (0..<columnCount).map { ColumnInfo(name: "col\($0)", type: "text") }
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let rows: [[CellValue]] = (0..<rowCount).map { r in
      (0..<columnCount).map { c in
        switch c % 6 {
        case 0: return .string("row \(r) col \(c) value \(rng.next() % 10_000)")
        case 1: return .int(Int(rng.next() % 1_000_000))
        case 2: return .double(Double(rng.next() % 1_000_000) / 100)
        case 3: return .date(base.addingTimeInterval(Double(rng.next() % 100_000_000)))
        case 4: return rng.next() % 3 == 0 ? .null : .string("maybe \(r)")
        default: return .json("{\"k\": \(r), \"c\": \(c)}")
        }
      }
    }
    return CellResult(columns: columns, rows: rows, rowCount: rows.count)
  }
}

/// A real `SQLTextView` inside an offscreen `NSWindow` (the coordinator guards on
/// `textView.window != nil`) with a `HighlightedTextEditor.Coordinator` built directly
@MainActor
final class OffscreenEditorHost {
  let window: NSWindow
  let scrollView: PassthroughScrollView
  let textView: SQLTextView
  let coordinator: HighlightedTextEditorRepresentable.Coordinator
  private(set) var boundText: String

  init(text: String) {
    boundText = text
    let box = StateBox()
    coordinator = HighlightedTextEditorRepresentable.Coordinator(
      text: Binding(get: { box.text }, set: { box.text = $0 }),
      height: Binding(get: { box.height }, set: { box.height = $0 }),
      isEmpty: Binding(get: { box.isEmpty }, set: { box.isEmpty = $0 }),
      onTextChanged: nil)
    self.box = box

    scrollView = PassthroughScrollView()
    textView = SQLTextView()
    // Mirrors HighlightedTextEditorRepresentable.makeNSView (word wrap on)
    textView.delegate = nil  // the benchmark calls coordinator.textDidChange itself
    coordinator.textView = textView
    textView.isRichText = false
    textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    textView.drawsBackground = false
    textView.allowsUndo = true
    textView.textContainerInset = NSSize(width: 4, height: 2)
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: 0, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.heightTracksTextView = false
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    scrollView.documentView = textView
    scrollView.hasVerticalScroller = true

    window = NSWindow(
      contentRect: NSRect(x: -10_000, y: -10_000, width: 800, height: 600),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = scrollView
    textView.string = text
    coordinator.applyHighlighting(to: textView, text: text)
  }

  private var box: StateBox!

  var boundValue: String { box.text }

  /// Insert one character in the middle of the document without notifying the delegate
  func insertCharacterMidDocument(_ character: String = "x") {
    let storage = textView.textStorage!
    storage.replaceCharacters(in: NSRange(location: storage.length / 2, length: 0), with: character)
  }

  /// The path under test: the coordinator's `textDidChange`
  func fireTextDidChange() {
    coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
  }

  func close() {
    textView.delegate = nil
    window.contentView = nil
    window.close()
  }

  private final class StateBox {
    var text = ""
    var height: CGFloat = 40
    var isEmpty = false
  }
}

/// Forces `syntaxHighlightingEnabled` on for a benchmark and restores it afterwards
@MainActor
func withSyntaxHighlightingEnabled<T>(_ body: () throws -> T) rethrows -> T {
  let settings = AppSettings.shared
  let previous = settings.syntaxHighlightingEnabled
  settings.syntaxHighlightingEnabled = true
  defer { settings.syntaxHighlightingEnabled = previous }
  return try body()
}

enum PerfBench {
  /// Median wall time of `n` runs of `body` in milliseconds, after `warmup` unmeasured runs
  static func median(of n: Int, warmup: Int = 1, _ body: () -> Void) -> Double {
    for _ in 0..<warmup { body() }
    var samples: [Double] = []
    for _ in 0..<n {
      let d = ContinuousClock().measure { body() }
      samples.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
    }
    samples.sort()
    return samples[samples.count / 2]
  }
}

/// stdout is not visible in xcodebuild output for the app-hosted runner, so every result is
/// also appended to files: the runner's temp dir and /tmp (best effort)
enum PerfReport {
  static func record(_ name: String, ms: Double) {
    let line =
      "PERF \(name) median_ms=\(String(format: "%.3f", ms)) date=\(ISO8601DateFormatter().string(from: Date()))\n"
    print(line, terminator: "")
    let paths = [
      (NSTemporaryDirectory() as NSString).appendingPathComponent("perf-results.txt"),
      "/tmp/sqlnotebook-perf-results.txt",
    ]
    for path in paths {
      do { try append(line, to: path) } catch { continue }
    }
  }

  private static func append(_ line: String, to path: String) throws {
    if !FileManager.default.fileExists(atPath: path) {
      try Data().write(to: URL(fileURLWithPath: path))
    }
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(line.utf8))
  }
}
