//
//  CellInfoContent.swift
//  Dblore
//

import SwiftUI

// MARK: - Cell Info Content

struct CellInfoContent: View {
  let columnName: String
  let columnType: String
  let value: CellValue
  let onSave: ((String) -> Void)?
  let isReadOnly: Bool
  let onSetNull: () -> Void

  @State private var isCopied = false
  @State private var isEditing = false
  @State private var editedValue: String = ""
  @State private var editedBoolValue: Bool = false
  @State private var originalBoolValue: Bool = false
  @State private var validationError: String?
  @State private var isBeautified = false
  @State private var beautifiedJSON: String = ""
  /// Size of the whole Format JSON output; above `maxHighlightedPrettyBytes`, `beautifiedJSON` is
  /// its first `maxShownBytes`
  @State private var formattedTotalBytes = 0
  @State private var isWordWrapEnabled = true
  /// Off-main Format JSON of a large value; nil when idle
  @State private var formatTask: Task<Void, Never>?
  /// Copy of the whole value, built off main; only a newer copy cancels it
  @State private var copyTask: Task<Void, Never>?
  /// Viewer and text of a value, built off the main actor; the value area shows a loading card
  /// until they match `value`
  @State private var loaded: Loaded?
  @FocusState private var isTextEditorFocused: Bool

  /// Values above this many UTF-8 bytes are never beautified or highlighted on the main actor:
  /// they show raw in a LargeTextView, and Format JSON pretty-prints them off the main actor.
  /// A SwiftUI Text lays out a 256 KB line in about 200 ms on the main thread.
  nonisolated static let maxHighlightedBytes = 64 * 1024

  /// Formatted JSON above this many UTF-8 bytes shows as plain text, never highlighted:
  /// pretty-printing indents each element by its depth (a 61 KB array nested 512 deep grows to
  /// 30 MB), and highlighting costs about 8 ms per KB on the main actor in a Debug build.
  nonisolated static let maxHighlightedPrettyBytes = 2 * maxHighlightedBytes

  /// Format JSON gives up on output above this many UTF-8 bytes rather than writing it
  nonisolated static let maxFormattedBytes = 32 * 1024 * 1024

  /// A large value shows its first this many UTF-8 bytes. The text view lays out a whole
  /// paragraph at once on the main thread: about 15 ms for a 64 KB line, 1.8 s for 12 MB.
  nonisolated static let maxShownBytes = 64 * 1024

  @Environment(NotebookViewModel.self) private var viewModel

  var body: some View {
    let ready = loaded?.source == source ? loaded : nil
    let preview = ready?.preview
    VStack(alignment: .leading, spacing: 0) {
      // Fixed header section
      VStack(alignment: .leading, spacing: Spacing.md) {
        // Column info
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Column")
            .font(.caption)
            .foregroundColor(.foregroundSubtle)

          Text("\(columnName) (\(columnType))")
            .font(.mono)
            .foregroundColor(.foreground)
        }

        Divider()

        // Value type
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Type")
            .font(.caption)
            .foregroundColor(.foregroundSubtle)

          Text(valueTypeName)
            .font(.mono)
            .foregroundColor(.foregroundMuted)
        }

        Divider()

        // Value header with action buttons
        HStack {
          Text("Value")
            .font(.caption)
            .foregroundColor(.foregroundSubtle)

          Spacer()

          if canSetNull {
            Button("Set NULL", action: setNull)
              .buttonStyle(SecondaryButtonStyle())
          }

          if isEditing {
            // Cancel and Save icon buttons (for non-boolean types)
            FloatingPanelButton(
              icon: "xmark",
              helpText: "Cancel",
              useSymbolEffect: false,
              action: cancelEdit
            )

            FloatingPanelButton(
              icon: "checkmark",
              helpText: "Save",
              useSymbolEffect: false,
              action: saveEdit
            )
            .disabled(validationError != nil)
          } else if isBooleanValue {
            // For boolean: only show Save button if value changed (and not in read-only mode)
            if hasBooleanValueChanged && !isReadOnly {
              FloatingPanelButton(
                icon: "checkmark",
                helpText: "Save",
                useSymbolEffect: false,
                action: saveBooleanEdit
              )
            }

            FloatingPanelButton(
              icon: isCopied ? "checkmark" : "doc.on.doc",
              helpText: "Copy Value",
              useSymbolEffect: true,
              action: copyToClipboard
            )
          } else {
            // Word Wrap, Beautify, Edit and Copy buttons (for non-boolean types)

            // Word Wrap button (only for string type, not under a geometry or vector viewer)
            if isStringValue && preview == nil {
              FloatingPanelToggleButton(
                icon: "text.alignleft",
                helpText: "Word Wrap",
                isActive: isWordWrapEnabled,
                action: { isWordWrapEnabled.toggle() }
              )
            }

            // Beautify button (only for string type, not under a geometry or vector viewer)
            if isStringValue && preview == nil && formatTask != nil {
              ProgressView()
                .controlSize(.small)

              FloatingPanelButton(
                icon: "xmark",
                helpText: "Cancel Format JSON",
                useSymbolEffect: false,
                action: cancelFormat
              )
            } else if isStringValue && preview == nil {
              FloatingPanelToggleButton(
                icon: "curlybraces",
                helpText: isBeautified
                  ? "Show Original" : isLargeValue ? "Format JSON" : "Beautify JSON",
                isActive: isBeautified,
                action: isBeautified ? showOriginal : formatJSON
              )
            }

            if !isReadOnly {
              FloatingPanelButton(
                icon: "pencil",
                helpText: "Edit Value",
                useSymbolEffect: false,
                action: startEdit
              )
            }

            FloatingPanelButton(
              icon: isCopied ? "checkmark" : "doc.on.doc",
              helpText: "Copy Value",
              useSymbolEffect: true,
              action: copyToClipboard
            )
          }
        }
      }
      .padding(.bottom, Spacing.md)

      // Scrollable value content - spans remaining vertical space
      if isBooleanValue {
        // Boolean toggle UI - always visible, no edit mode needed
        HStack(spacing: Spacing.sm) {
          Toggle("", isOn: $editedBoolValue)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(.accent)
            .controlSize(.mini)
            .disabled(isReadOnly)
            .onChange(of: editedBoolValue) { _, _ in
              // Trigger UI update when toggle changes
            }

          Text(editedBoolValue ? "true" : "false")
            .font(.mono)
            .foregroundColor(.foreground)
        }.padding(.leading, -5)
      } else if isEditing {
        // Text editor for other types (only in edit mode)
        VStack(alignment: .leading, spacing: Spacing.xs) {
          PlainTextEditor(text: $editedValue)
            .background(Color.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
            .overlay(
              HairlineBorder(
                shape: RoundedRectangle(cornerRadius: CornerRadius.md),
                color: validationError != nil ? .destructive : .border)
            )
            .frame(maxHeight: .infinity)
            .focusedValue(\.isCellValueEditing, isEditing)
            .onChange(of: editedValue) { _, newValue in
              validateInput(newValue)
            }

          // Validation error message
          if let error = validationError {
            HStack(spacing: Spacing.xs) {
              Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.destructive)

              Text(error)
                .font(.caption)
                .foregroundColor(.destructive)
            }
            .padding(.top, Spacing.sm)
            .padding(.horizontal, Spacing.xs)
          }
        }
      } else {
        // Read-only view for non-boolean types
        if let preview {
          switch preview {
          case .geometry(let sketch):
            GeometryPreview(sketch: sketch)
          case .vector(let vector):
            VectorPreview(vector: vector, text: value.fullString)
          }
        } else if ready == nil {
          CellValueLoadingCard()
        } else if isLargeValue
          || (isBeautified && formattedTotalBytes > Self.maxHighlightedPrettyBytes)
        {
          // Too large for a SwiftUI Text: lazily laid-out text view, never highlighted
          VStack(alignment: .leading, spacing: Spacing.xs) {
            LargeTextView(
              text: isBeautified ? beautifiedJSON : ready?.text ?? "",
              wrapsLines: isWordWrapEnabled
            )
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.tableHeaderBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))

            let shown = isBeautified ? beautifiedJSON.utf8.count : ready?.text.utf8.count ?? 0
            let total = isBeautified ? formattedTotalBytes : ready?.totalBytes ?? 0
            if shown < total {
              Text(
                Self.truncationNote(
                  shownBytes: shown, totalBytes: total, isBinary: isBinaryValue,
                  isFormatted: isBeautified)
              )
              .font(.caption)
              .foregroundColor(.foregroundSubtle)
            }
          }
        } else if isBeautified {
          // Nested ScrollViews for both axes to avoid centering issue
          // Horizontal outside so scrollbar is always visible at bottom
          if isWordWrapEnabled {
            // With word wrap: only vertical scroll
            ScrollView(.vertical, showsIndicators: true) {
              HighlightedJSONText(json: beautifiedJSON)
                .padding(Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.tableHeaderBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
          } else {
            // Without word wrap: both horizontal and vertical scroll
            ScrollView(.horizontal, showsIndicators: true) {
              ScrollView(.vertical, showsIndicators: true) {
                HighlightedJSONText(json: beautifiedJSON)
                  .padding(Spacing.sm)
              }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.tableHeaderBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
          }
        } else {
          if isWordWrapEnabled {
            // With word wrap: only vertical scroll
            ScrollView(.vertical, showsIndicators: true) {
              Text(ready?.text ?? "")
                .font(.mono)
                .foregroundColor(value.isNull ? .foregroundSubtle : .foreground)
                .italic(value.isNull)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(Spacing.sm)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.tableHeaderBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
          } else {
            // Without word wrap: both horizontal and vertical scroll
            // Nested ScrollViews for both axes to avoid centering issue
            // Horizontal outside so scrollbar is always visible at bottom
            ScrollView(.horizontal, showsIndicators: true) {
              ScrollView(.vertical, showsIndicators: true) {
                Text(ready?.text ?? "")
                  .font(.mono)
                  .foregroundColor(value.isNull ? .foregroundSubtle : .foreground)
                  .italic(value.isNull)
                  .textSelection(.enabled)
                  .fixedSize(horizontal: true, vertical: true)
                  .padding(Spacing.sm)
              }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.tableHeaderBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
          }
        }
      }
    }
    .onAppear {
      // Initialize boolean values when view appears
      if case .bool(let boolValue) = value {
        editedBoolValue = boolValue
        originalBoolValue = boolValue
      }
    }
    // A Copy still building finishes: the user asked for that value
    .onDisappear(perform: cancelFormat)
    .task(id: source) {
      let built = await Self.load(source)
      guard !Task.isCancelled else { return }
      loaded = built
      // A JSON object or array shows formatted when its output is small enough to highlight
      if let formatted = built.formatted {
        showFormatted(formatted, totalBytes: formatted.utf8.count)
      }
    }
    .onChange(of: value) { _, newValue in
      // Reset beautified state when value changes
      cancelFormat()
      isBeautified = false
      beautifiedJSON = ""

      // Update boolean values when value changes
      if case .bool(let boolValue) = newValue {
        editedBoolValue = boolValue
        originalBoolValue = boolValue
      }
    }
  }

  private var source: CellValuePreview.Source {
    CellValuePreview.Source(value: value, columnType: columnType)
  }

  /// Viewer and display text of a value (base64 for binary), built together off the main actor.
  /// `text` is at most `maxShownBytes`; `totalBytes` is the size of the whole text. `formatted`
  /// is the pretty form of a JSON object or array, when it can be highlighted.
  nonisolated struct Loaded: Sendable {
    let source: CellValuePreview.Source
    let preview: CellValuePreview?
    let text: String
    let totalBytes: Int
    var formatted: String?
  }

  /// `@concurrent` leaves the main actor: a geometry can hold a million points, and the base64 of
  /// a large blob is megabytes. A geometry viewer needs no text.
  @concurrent nonisolated private static func load(
    _ source: CellValuePreview.Source
  ) async
    -> Loaded
  {
    let preview = await CellValuePreview.make(value: source.value, columnType: source.columnType)
    if case .geometry = preview {
      return Loaded(source: source, preview: preview, text: "", totalBytes: 0)
    }
    let text = source.value.fullString
    var loaded = Loaded(
      source: source, preview: preview, text: displayText(text, maxBytes: maxShownBytes),
      totalBytes: text.utf8.count)
    switch source.value {
    case .string, .json:
      let first = text.first(where: { !$0.isWhitespace })
      guard preview == nil, first == "{" || first == "[", text.utf8.count <= maxHighlightedBytes,
        case .formatted(let pretty, _) = prettyPrintedJSON(
          text, maxOutputBytes: maxHighlightedPrettyBytes)
      else { break }
      loaded.formatted = pretty
    default:
      break
    }
    return loaded
  }

  /// `text` cut to at most `maxBytes` UTF-8 bytes, on a character boundary
  nonisolated static func displayText(_ text: String, maxBytes: Int) -> String {
    guard text.utf8.count > maxBytes else { return text }
    var bytes = 0
    let end =
      text.firstIndex { character in
        bytes += character.utf8.count
        return bytes > maxBytes
      } ?? text.endIndex
    return String(text[..<end])
  }

  nonisolated private static func byteCount(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
  }

  /// Note under a cut value. Binary shows its base64 text, Format JSON its output; Copy always
  /// copies the whole original value.
  nonisolated static func truncationNote(
    shownBytes: Int, totalBytes: Int, isBinary: Bool, isFormatted: Bool
  ) -> String {
    let kind = isFormatted ? " of formatted JSON" : isBinary ? " of base64 text" : ""
    let copied = isFormatted ? "the whole original value" : "the whole value"
    return
      "Showing the first \(byteCount(shownBytes)) of \(byteCount(totalBytes))\(kind). Copy copies \(copied)."
  }

  /// Whole text of a value; `@concurrent` leaves the main actor (base64 of a large blob)
  @concurrent nonisolated private static func fullText(_ value: CellValue) async -> String {
    value.fullString
  }

  private var valueTypeName: String {
    switch value {
    case .string: return "String"
    case .int: return "Integer"
    case .double: return "Double"
    case .bool: return "Boolean"
    case .null: return "NULL"
    case .json: return "JSON"
    case .date: return "Date"
    case .data: return "Binary Data"
    }
  }

  private var isBooleanValue: Bool {
    if case .bool = value {
      return true
    }
    return false
  }

  /// Text that Word Wrap and Format JSON apply to: a string or a JSON value
  private var isStringValue: Bool {
    switch value {
    case .string, .json: true
    default: false
    }
  }

  private var isBinaryValue: Bool {
    if case .data = value {
      return true
    }
    return false
  }

  /// Sized from the value, without building its text (base64 of a whole blob for `.data`)
  private var isLargeValue: Bool {
    switch value {
    case .string(let text), .json(let text):
      text.utf8.count > Self.maxHighlightedBytes
    case .data(let data):
      (data.count + 2) / 3 * 4 > Self.maxHighlightedBytes
    case .int, .double, .bool, .null, .date:
      false
    }
  }

  private var hasBooleanValueChanged: Bool {
    editedBoolValue != originalBoolValue
  }

  /// Editable cell that still has a value. NULL is already set, so the button stays hidden.
  private var canSetNull: Bool {
    !isReadOnly && !value.isNull
  }

  private func setNull() {
    if isEditing { cancelEdit() }
    onSetNull()
  }

  private func startEdit() {
    cancelFormat()
    editedValue = value.fullString
    isEditing = true
    isTextEditorFocused = true
    validationError = nil  // Reset validation error

    // Validate the initial value to catch any issues
    validateInput(editedValue)

    NotificationCenter.default.post(name: .cellValueEditingStarted, object: nil)
  }

  private func saveBooleanEdit() {
    let valueToSave = String(editedBoolValue)
    onSave?(valueToSave)
    // Update original value after save
    originalBoolValue = editedBoolValue
  }

  private func cancelEdit() {
    isEditing = false
    isTextEditorFocused = false
    editedValue = ""
    validationError = nil
    NotificationCenter.default.post(name: .cellValueEditingEnded, object: nil)
  }

  private func saveEdit() {
    // Don't save if validation fails
    guard validationError == nil else { return }

    // For boolean values, convert toggle state to string
    let valueToSave = isBooleanValue ? String(editedBoolValue) : editedValue

    onSave?(valueToSave)
    isEditing = false
    isTextEditorFocused = false
    editedValue = ""
    validationError = nil
    NotificationCenter.default.post(name: .cellValueEditingEnded, object: nil)
  }

  private func copyToClipboard() {
    let value = value
    copyTask?.cancel()
    copyTask = Task {
      let text = await Self.fullText(value)
      // A newer copy replaced this one: keep its clipboard
      guard !Task.isCancelled else { return }
      copyTask = nil
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)

      // Show checkmark feedback
      isCopied = true

      // Reset back to copy icon after 500ms
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        isCopied = false
      }
    }
  }

  // MARK: - Validation

  private func validateInput(_ input: String) {
    // Use CellValueValidator helper
    let result = CellValueValidator.validate(input, for: value, columnType: columnType)
    validationError = result.errorMessage
  }

  // MARK: - JSON Beautification

  private func showOriginal() {
    isBeautified = false
    beautifiedJSON = ""
  }

  private func showFormatted(_ text: String, totalBytes: Int) {
    beautifiedJSON = text
    formattedTotalBytes = totalBytes
    isBeautified = true
  }

  /// Format JSON pretty-prints off the main actor; output too large to highlight shows as plain
  /// text, cut to `maxShownBytes`
  private func formatJSON() {
    guard let stringValue = jsonText, formatTask == nil else { return }
    if let formatted = loaded?.source == source ? loaded?.formatted : nil {
      showFormatted(formatted, totalBytes: formatted.utf8.count)
      return
    }
    formatTask = Task {
      let pretty = await Self.formattedJSON(stringValue)
      guard !Task.isCancelled else { return }
      formatTask = nil
      switch pretty {
      case .formatted(let text, let totalBytes):
        showFormatted(text, totalBytes: totalBytes)
      case .tooLarge:
        viewModel.showToast("The formatted JSON would be too large to show.", type: .warning)
      case .invalid:
        viewModel.showToast("Invalid JSON format. Cannot beautify.", type: .error)
      }
    }
  }

  private func cancelFormat() {
    formatTask?.cancel()
    formatTask = nil
  }

  /// Text of a string or JSON value, the one Format JSON reads
  private var jsonText: String? {
    switch value {
    case .string(let text), .json(let text): text
    default: nil
    }
  }

  /// Pretty-printed JSON, or why there is none
  nonisolated enum PrettyJSON: Equatable, Sendable {
    /// `text` is the whole output up to `maxHighlightedPrettyBytes`, else its first
    /// `maxShownBytes`; `totalBytes` is the size of the whole
    case formatted(text: String, totalBytes: Int)
    /// The output would pass the cap
    case tooLarge
    case invalid
  }

  /// `json` pretty-printed, given up before writing more than `maxOutputBytes`
  nonisolated static func prettyPrintedJSON(_ json: String, maxOutputBytes: Int) -> PrettyJSON {
    guard
      let object = try? JSONSerialization.jsonObject(
        with: Data(json.utf8), options: .allowFragments)
    else { return .invalid }
    guard prettyPrintedLowerBound(object) <= maxOutputBytes else { return .tooLarge }
    guard
      let pretty = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .fragmentsAllowed])
    else { return .invalid }
    guard pretty.count <= maxOutputBytes else { return .tooLarge }
    let text =
      pretty.count <= maxHighlightedPrettyBytes
      ? String(decoding: pretty, as: UTF8.self) : prefixText(pretty, maxBytes: maxShownBytes)
    return .formatted(text: text, totalBytes: pretty.count)
  }

  /// Bytes that pretty-printing `object` writes at least: every element of an array or object
  /// gets a newline and two spaces per level, then one byte or more. JSONSerialization parses at
  /// most 512 levels.
  nonisolated static func prettyPrintedLowerBound(_ object: Any) -> Int {
    var total = 0
    var containers: [(children: [Any], depth: Int)] = []
    func visit(_ node: Any, depth: Int) {
      if let array = node as? [Any] {
        containers.append((array, depth))
      } else if let dictionary = node as? [String: Any] {
        containers.append((Array(dictionary.values), depth))
      }
    }
    visit(object, depth: 0)
    while let (children, depth) = containers.popLast() {
      total += children.count * (2 * (depth + 1) + 2)
      for child in children { visit(child, depth: depth + 1) }
    }
    return total
  }

  /// The first `maxBytes` UTF-8 bytes of `data` as text, cut on a character boundary, without
  /// decoding the rest. It decodes a few bytes past the cut: a character that crosses the cut
  /// still ends past `maxBytes`, so `displayText` drops it.
  nonisolated static func prefixText(_ data: Data, maxBytes: Int) -> String {
    var count = min(data.count, maxBytes + 4)
    // Back off to the start of a scalar: UTF-8 continuation bytes are 0b10xxxxxx
    while count < data.count, data[data.startIndex + count] & 0xC0 == 0x80 { count -= 1 }
    return displayText(String(decoding: data.prefix(count), as: UTF8.self), maxBytes: maxBytes)
  }

  /// Format JSON output; `@concurrent` leaves the main actor
  @concurrent nonisolated private static func formattedJSON(_ json: String) async -> PrettyJSON {
    prettyPrintedJSON(json, maxOutputBytes: maxFormattedBytes)
  }
}

/// Card in the value's place while it loads. Its spinner fades in after 150 ms, so a fast load
/// never flashes it.
private struct CellValueLoadingCard: View {
  @State private var showsSpinner = false

  var body: some View {
    ProgressView()
      .controlSize(.small)
      .tint(.accent)
      .opacity(showsSpinner ? 1 : 0)
      .animation(.easeIn(duration: 0.15), value: showsSpinner)
      // Opt out of the app-wide animation kill switch, only for the fade
      .transaction(value: showsSpinner) { $0.disablesAnimations = false }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.tableHeaderBackground)
      .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
      .task {
        try? await Task.sleep(for: .milliseconds(150))
        showsSpinner = true
      }
  }
}

// MARK: - Geometry and vector viewers

/// What the Cell Value viewers show. Chosen by the column type (PostGIS geometry / geography,
/// MySQL GEOMETRY, pgvector vector / halfvec / sparsevec), or by a value that parses as one.
/// Text is read as a vector only for a vector column or one of unknown type, so a JSON array
/// in a TEXT column stays text.
enum CellValuePreview: Sendable {
  case geometry(GeometrySketch)
  case vector(VectorValue)

  /// What `make` reads: a new value or column type parses again.
  struct Source: Equatable {
    let value: CellValue
    let columnType: String
  }

  /// nil when the value is neither. `@concurrent` leaves the main actor: a geometry can hold a
  /// million points.
  @concurrent nonisolated static func make(
    value: CellValue, columnType: String
  ) async
    -> CellValuePreview?
  {
    let type = columnType.uppercased()
    let isSpatialType = type.contains("GEOMETRY") || type.contains("GEOGRAPHY")
    let isVectorType = ["VECTOR", "HALFVEC", "SPARSEVEC"].contains { type.hasPrefix($0) }
    let mayBeVector =
      isVectorType || type.isEmpty || type.hasPrefix("USER-DEFINED") || type.hasPrefix("UNKNOWN")
    switch value {
    case .data(let data):
      guard isSpatialType || mayBeWKB(data), let parsed = try? GeometryWKB.parse(data) else {
        return nil
      }
      return .geometry(GeometrySketch(parsed))
    case .string(let text):
      let first = text.first(where: { !$0.isWhitespace })
      if mayBeVector, first == "[" || first == "{", let vector = VectorValue(text: text) {
        return .vector(vector)
      }
      guard !isVectorType, isSpatialType || mayBeWKBHex(text),
        let parsed = try? GeometryWKB.parse(hex: text)
      else { return nil }
      return .geometry(GeometrySketch(parsed))
    case .int, .double, .bool, .null, .json, .date:
      return nil
    }
  }

  /// A WKB header (byte order, known type code) first, or after MySQL's 4-byte SRID, so an
  /// unrelated blob is never copied for a parse.
  private nonisolated static func mayBeWKB(_ data: Data) -> Bool {
    let bytes = [UInt8](data.prefix(9))
    return hasWKBHeader(bytes, at: 0) || hasWKBHeader(bytes, at: 4)
  }

  private nonisolated static func hasWKBHeader(_ bytes: [UInt8], at offset: Int) -> Bool {
    guard bytes.count >= offset + 5, bytes[offset] <= 1 else { return false }
    let word = bytes[(offset + 1)...(offset + 4)].enumerated().reduce(UInt32(0)) {
      $0 | UInt32($1.element) << (bytes[offset] == 1 ? 8 * $1.offset : 8 * (3 - $1.offset))
    }
    let code = word & 0x1FFF_FFFF
    return code / 1000 <= 3 && (1...7).contains(code % 1000)
  }

  /// Hex of a WKB value: the byte order `00` / `01` first.
  private nonisolated static func mayBeWKBHex(_ text: String) -> Bool {
    text.utf8.count >= 42 && (text.hasPrefix("00") || text.hasPrefix("01"))
  }
}

// MARK: - Previews

#Preview("Boolean Value - True") {
  @Previewable @State var viewModel = NotebookViewModel()
  viewModel.rightSidebarContent = .cellInfo(
    columnName: "is_active",
    columnType: "boolean",
    value: .bool(true),
    tableName: "users",
    rowData: ["user_id": .int(1), "is_active": .bool(true)],
    primaryKeyColumns: ["user_id"],
    cellId: nil
  )

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("String Value") {
  @Previewable @State var viewModel = NotebookViewModel()
  viewModel.rightSidebarContent = .cellInfo(
    columnName: "email",
    columnType: "varchar(255)",
    value: .string("user@example.com"),
    tableName: "users",
    rowData: ["user_id": .int(1), "email": .string("user@example.com")],
    primaryKeyColumns: ["user_id"],
    cellId: nil
  )

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Integer Value") {
  @Previewable @State var viewModel = NotebookViewModel()
  viewModel.rightSidebarContent = .cellInfo(
    columnName: "user_id",
    columnType: "integer",
    value: .int(42),
    tableName: "users",
    rowData: ["user_id": .int(42), "email": .string("user@example.com")],
    primaryKeyColumns: ["user_id"],
    cellId: nil
  )

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Date Value") {
  @Previewable @State var viewModel = NotebookViewModel()
  let dateFormatter = ISO8601DateFormatter()
  let date = dateFormatter.date(from: "2024-01-15T10:30:00Z") ?? Date()

  viewModel.rightSidebarContent = .cellInfo(
    columnName: "created_at",
    columnType: "timestamp",
    value: .date(date),
    tableName: "posts",
    rowData: ["post_id": .int(1), "created_at": .date(date)],
    primaryKeyColumns: ["post_id"],
    cellId: nil
  )

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Long Text Value") {
  @Previewable @State var viewModel = NotebookViewModel()
  let longText = """
    Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.

    Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.
    """

  viewModel.rightSidebarContent = .cellInfo(
    columnName: "description",
    columnType: "text",
    value: .string(longText),
    tableName: "articles",
    rowData: ["article_id": .int(1), "description": .string(longText)],
    primaryKeyColumns: ["article_id"],
    cellId: nil
  )

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("JSON String Value") {
  @Previewable @State var viewModel = NotebookViewModel()
  let jsonString = """
    {"user":{"id":123,"name":"John Doe","email":"john@example.com","profile":{"bio":"Software developer","location":"San Francisco"},"tags":["developer","swift","ios"]}}
    """

  viewModel.rightSidebarContent = .cellInfo(
    columnName: "metadata",
    columnType: "varchar",
    value: .string(jsonString),
    tableName: "users",
    rowData: ["user_id": .int(1), "metadata": .string(jsonString)],
    primaryKeyColumns: ["user_id"],
    cellId: nil
  )

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}
