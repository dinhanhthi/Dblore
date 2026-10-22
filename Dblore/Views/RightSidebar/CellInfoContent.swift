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
  @State private var isWordWrapEnabled = true
  /// Off-main Format JSON of a large value; nil when idle
  @State private var formatTask: Task<Void, Never>?
  /// Geometry or vector viewer for the value, parsed off the main actor; nil for other values
  @State private var preview: CellValuePreview?
  @FocusState private var isTextEditorFocused: Bool

  /// Values above this many UTF-8 bytes are never beautified or highlighted on the main actor:
  /// they show raw in a LargeTextView, and Format JSON pretty-prints them off the main actor
  static let maxHighlightedBytes = 256 * 1024

  @Environment(NotebookViewModel.self) private var viewModel

  var body: some View {
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
                action: isBeautified
                  ? showOriginal : isLargeValue ? formatLargeJSON : { beautifyJSON() }
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
        } else if isLargeValue {
          // Too large for a SwiftUI Text: lazily laid-out text view, never highlighted
          LargeTextView(
            text: isBeautified ? beautifiedJSON : value.fullString,
            wrapsLines: isWordWrapEnabled
          )
          .frame(maxHeight: .infinity, alignment: .top)
          .background(Color.tableHeaderBackground)
          .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
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
              Text(value.fullString)
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
                Text(value.fullString)
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
      beautifyJSON(silent: true)
    }
    .onDisappear(perform: cancelFormat)
    .task(id: CellValuePreview.Source(value: value, columnType: columnType)) {
      preview = nil
      let parsed = await CellValuePreview.make(value: value, columnType: columnType)
      guard !Task.isCancelled else { return }
      preview = parsed
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
      beautifyJSON(silent: true)
    }
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

  private var isStringValue: Bool {
    if case .string = value {
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
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value.fullString, forType: .string)

    // Show checkmark feedback
    isCopied = true

    // Reset back to copy icon after 500ms
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      isCopied = false
    }
  }

  // MARK: - Validation

  private func validateInput(_ input: String) {
    // Use CellValueValidator helper
    let result = CellValueValidator.validate(input, for: value, columnType: columnType)
    validationError = result.errorMessage
  }

  // MARK: - JSON Beautification

  /// `silent` is used for automatic beautification: no toasts, and only for JSON objects/arrays.
  private func beautifyJSON(silent: Bool = false) {
    guard case .string(let stringValue) = value, !isLargeValue else { return }

    if silent {
      let first = stringValue.first(where: { !$0.isWhitespace })
      guard first == "{" || first == "[" else { return }
    }

    // Try to parse the string as JSON
    guard let data = stringValue.data(using: .utf8) else {
      if !silent { viewModel.showToast("Cannot convert string to data.", type: .error) }
      return
    }

    // Try to parse and validate that entire string is consumed
    let parsedObject: Any

    do {
      parsedObject = try JSONSerialization.jsonObject(
        with: data,
        options: .allowFragments
      )

      // Check if entire data was consumed by trying to parse again from start
      // If there's trailing data, JSONSerialization will only parse the first valid object
      let serializedData = try JSONSerialization.data(
        withJSONObject: parsedObject, options: .fragmentsAllowed)

      // Compare original data length with serialized length
      // If original is significantly longer, there's likely trailing invalid JSON
      if data.count > Int(Double(serializedData.count) * 1.5) {
        if silent { return }
        viewModel.showToast(
          "Warning: Only the first valid JSON object was beautified. The input contains multiple objects or invalid trailing data.",
          type: .warning
        )
      }

      // Generate pretty printed version
      let prettyData = try JSONSerialization.data(
        withJSONObject: parsedObject,
        options: [.prettyPrinted, .fragmentsAllowed]
      )

      guard let prettyString = String(data: prettyData, encoding: .utf8) else {
        if !silent {
          viewModel.showToast("Cannot convert beautified data to string.", type: .error)
        }
        return
      }

      // Set beautified state
      beautifiedJSON = prettyString
      isBeautified = true

    } catch {
      // Show error toast if not valid JSON
      if !silent { viewModel.showToast("Invalid JSON format. Cannot beautify.", type: .error) }
      return
    }
  }

  private func showOriginal() {
    isBeautified = false
    beautifiedJSON = ""
  }

  /// Format JSON for a large value: pretty-prints off the main actor, shown raw (no highlight)
  private func formatLargeJSON() {
    guard case .string(let stringValue) = value, formatTask == nil else { return }
    formatTask = Task {
      let pretty = await Self.prettyPrintedJSON(stringValue)
      guard !Task.isCancelled else { return }
      formatTask = nil
      guard let pretty else {
        viewModel.showToast("Invalid JSON format. Cannot beautify.", type: .error)
        return
      }
      beautifiedJSON = pretty
      isBeautified = true
    }
  }

  private func cancelFormat() {
    formatTask?.cancel()
    formatTask = nil
  }

  /// Pretty-printed `json`, or nil when it is not valid JSON. `@concurrent` leaves the main actor.
  @concurrent nonisolated private static func prettyPrintedJSON(_ json: String) async -> String? {
    guard let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data, options: .allowFragments),
      let pretty = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .fragmentsAllowed])
    else { return nil }
    return String(data: pretty, encoding: .utf8)
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
