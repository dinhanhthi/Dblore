// AppSettingsTools.swift
// The AI chat's app settings tools: list_settings reads the settings the AI may change, and
// change_setting changes one at once through its AppSettings setter. They touch no database.
// Only the allowlist below can change, each to a bool, a number in range or a listed value;
// security, data-exposure, result-guard and session-brake settings are refused with their place.

import Foundation

/// Tool layer of the settings tools. Names, specs and `decode` are pure; the catalog reads and
/// writes `AppSettings`, so it lives on the main actor.
nonisolated enum AppSettingsTools {
  static let listSettings = "list_settings"
  static let changeSetting = "change_setting"

  /// A decoded change_setting call: the model's text, not yet checked against the catalog
  struct Change: Equatable, Sendable {
    let key: String
    let value: String
  }

  enum Call: Equatable, Sendable {
    case listSettings
    case changeSetting(Change)
  }

  /// A change that left the setting as it was
  enum NoOp: Equatable, Sendable {
    /// The setting already holds the value
    case alreadySet
    /// Notification permission was refused, so notifications stayed off
    case stayedOff
  }

  /// Result of `apply`. Old and new are canonical values, re-read after the write.
  enum Outcome: Equatable, Sendable {
    case applied(old: String, new: String)
    case noOp(NoOp)
    case refused(AITools.ToolError)
  }

  enum UndoOutcome: Equatable, Sendable {
    case undone
    /// The live value is no longer the new one; nothing was written
    case changedSince
    /// The revert turns notifications on and permission was refused
    case stayedOff
    /// The saved change is not in the catalog
    case refused
  }

  /// One allowed value of a choice and the text the Settings control shows for it
  struct Option: Equatable, Sendable {
    let raw: String
    let title: String
  }

  /// The values a setting takes, as canonical strings
  enum Kind: Equatable, Sendable {
    /// "true" or "false"; `onOnly`: change_setting may only turn it on
    case bool(onOnly: Bool)
    /// A whole number in `range`, on a multiple of `step` from its lower bound
    case int(ClosedRange<Int>, step: Int)
    /// A number in `range`
    case double(ClosedRange<Double>)
    case choice([Option])

    /// The canonical form of `text` when it is a value of this kind, else nil. `onOnly` is not
    /// checked here: it restricts only change_setting.
    func canonical(_ text: String) -> String? {
      switch self {
      case .bool:
        return ["true", "false"].contains(text) ? text : nil
      case .int(let range, let step):
        guard let value = Int(text), range.contains(value),
          (value - range.lowerBound) % step == 0
        else { return nil }
        return String(value)
      case .double(let range):
        guard let value = Double(text), value.isFinite, range.contains(value) else { return nil }
        return AppSettingsTools.canonical(value)
      case .choice(let options):
        return options.contains { $0.raw == text } ? text : nil
      }
    }

    /// The allowed values, for the model
    var allowed: String {
      switch self {
      case .bool(let onOnly):
        return onOnly ? "true (only the user turns it off)" : "true or false"
      case .int(let range, let step):
        return "a whole number from \(range.lowerBound) to \(range.upperBound)"
          + (step > 1 ? " in steps of \(step)" : "")
      case .double(let range):
        return "a number from \(canonical(range.lowerBound)) to \(canonical(range.upperBound))"
      case .choice(let options):
        return "one of "
          + options.map { $0.raw == $0.title ? $0.raw : "\($0.raw) (\($0.title))" }
          .joined(separator: ", ")
      }
    }

    private func canonical(_ value: Double) -> String {
      AppSettingsTools.canonical(value)
    }
  }

  /// A Double as a canonical string: whole numbers without a fraction ("10"), others in
  /// Swift's shortest round-trip form ("10.5")
  static func canonical(_ value: Double) -> String {
    value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
  }

  /// A setting the AI may change. `key` is the AppSettings property name; `title` and `tab`
  /// are what Settings shows.
  struct Entry {
    let key: String
    let title: String
    let tab: String
    let kind: Kind
    /// Text after a number ("pt", "seconds")
    var unit = ""
    /// The live value, canonical
    let read: @MainActor (AppSettings) -> String
    /// Writes a canonical value of `kind` through the setter
    let write: @MainActor (AppSettings, String) -> Void

    /// The text the user sees for a canonical value
    func display(_ value: String) -> String {
      switch kind {
      case .bool: return value == "true" ? "On" : "Off"
      case .choice(let options): return options.first { $0.raw == value }?.title ?? value
      case .int, .double: return unit.isEmpty ? value : "\(value) \(unit)"
      }
    }
  }

  /// A setting or area the AI may not change, and where the user changes it (nil: nowhere in
  /// Settings)
  struct Excluded: Sendable {
    let keys: [String]
    let title: String
    let place: String?
  }

  // MARK: - Specs

  /// The two tools, in a fixed order
  static let specs = [
    AIToolSpec(
      name: listSettings,
      description:
        "List the Dblore app settings you can change, with their current values, allowed "
        + "values and Settings tab, and the settings you cannot change. Reads no database.",
      parameters: schema([:], required: [])),
    AIToolSpec(
      name: changeSetting,
      description:
        "Change one Dblore app setting at once; the user sees the change with Undo. Use it "
        + "only when the user's own message asks for that change. Call list_settings first "
        + "for the keys and allowed values.",
      parameters: schema(
        [
          "key": text("The setting's key from list_settings"),
          "value": text("One allowed value, written exactly as list_settings shows it"),
        ], required: ["key", "value"])),
  ]

  private static func text(_ description: String) -> JSONValue {
    .object(["type": .string("string"), "description": .string(description)])
  }

  private static func schema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
    .object([
      "type": .string("object"), "properties": .object(properties),
      "required": .array(required.map { .string($0) }), "additionalProperties": .bool(false),
    ])
  }

  // MARK: - Decoding

  /// The call's arguments, strictly: a JSON object holding only the tool's keys, each a string
  /// with non-blank text of at most `AITools.maxNameCharacters`.
  static func decode(_ call: AIToolCall) throws -> Call {
    let known: [String]
    switch call.name {
    case listSettings: known = []
    case changeSetting: known = ["key", "value"]
    default: throw AITools.ToolError.unknownTool
    }
    guard
      case .object(let arguments)? = try? JSONDecoder().decode(
        JSONValue.self, from: Data(call.inputJSON.utf8))
    else { throw AITools.ToolError.invalidArguments }
    guard arguments.keys.allSatisfy(known.contains) else {
      throw AITools.ToolError.unknownArgument
    }
    guard call.name == changeSetting else { return .listSettings }
    return .changeSetting(
      Change(
        key: try string(arguments["key"], "key"), value: try string(arguments["value"], "value")))
  }

  private static func string(_ value: JSONValue?, _ key: String) throws -> String {
    guard case .string(let text)? = value,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw AITools.ToolError.missing(key) }
    guard text.count <= AITools.maxNameCharacters else {
      throw AITools.ToolError.tooLong(key, limit: AITools.maxNameCharacters)
    }
    return text
  }

  // MARK: - Catalog

  /// The settings the AI may change, in Settings order. Ranges and values follow the Settings
  /// controls, which are stricter than some setters (Max Height 200...1000 in steps of 50).
  @MainActor static let entries: [Entry] = [
    toggle(
      "confirmBeforeQuit", "Confirm before quitting with Cmd+Q", "General", \.confirmBeforeQuit),
    toggle("openWindowsAsTabs", "Open new windows as tabs", "General", \.openWindowsAsTabs),
    choice(
      "defaultNewTabType", "Default file for new tab (Cmd+T)", "General", \.defaultNewTabType,
      title: \.title),
    toggle(
      "notifyLongQueries", "Notify when a long query finishes", "General", \.notifyLongQueries),
    Entry(
      key: "longQueryThresholdSeconds", title: "Longer than (seconds)", tab: "General",
      kind: .double(AppSettings.longQueryThresholdRange), unit: "seconds",
      read: { canonical($0.longQueryThresholdSeconds) },
      write: { settings, value in Double(value).map { settings.longQueryThresholdSeconds = $0 } }),
    toggle(
      "notifyOnlyWhenInactive", "Only when Dblore is in the background", "General",
      \.notifyOnlyWhenInactive),
    choice("themePreference", "Theme", "Appearance", \.themePreference),
    choice("accentColor", "Accent color", "Appearance", \.accentColor),
    choice("animationPreference", "Animations", "Appearance", \.animationPreference),
    toggle("isAutoCompleteEnabled", "Enable Autocomplete", "Editor", \.isAutoCompleteEnabled),
    toggle("showLineNumbers", "Show Line Numbers", "Editor", \.showLineNumbers),
    toggle("wordWrapEnabled", "Word Wrap", "Editor", \.wordWrapEnabled),
    toggle(
      "syntaxHighlightingEnabled", "Enable Syntax Highlighting", "Editor",
      \.syntaxHighlightingEnabled),
    points("editorFontSize", "Font Size", "Editor", fontSizes, step: 1, \.editorFontSize),
    toggle("editorSideBySideDefault", "Side-by-Side Layout", "Editor", \.editorSideBySideDefault),
    toggle("editorSimpleMode", "Simple Mode", "Editor", \.editorSimpleMode),
    choice("formatterIndent", "Indent", "Editor", \.formatterIndent, title: \.title),
    choice(
      "formatterKeywordCase", "Keyword case", "Editor", \.formatterKeywordCase, title: \.title),
    choice(
      "formatterFunctionCase", "Function case", "Editor", \.formatterFunctionCase, title: \.title),
    choice(
      "formatterCommaPosition", "Comma position", "Editor", \.formatterCommaPosition,
      title: \.title),
    Entry(
      key: "formatterLineWidth", title: "Line width", tab: "Editor",
      kind: .choice(
        AppSettings.formatterLineWidths.map {
          Option(raw: String($0), title: $0 == 0 ? "Off" : String($0))
        }),
      read: { String($0.formatterLineWidth) },
      write: { settings, value in Int(value).map { settings.formatterLineWidth = $0 } }),
    choice("aiPanelOpenMode", "AI Assistant panel", "AI", \.aiPanelOpenMode, title: \.title),
    points("resultFontSize", "Font Size", "Results", fontSizes, step: 1, \.resultFontSize),
    toggle("colorValuesByType", "Color Values by Type", "Results", \.colorValuesByType),
    toggle("hideColumnTypes", "Hide Column Types", "Results", \.hideColumnTypes),
    toggle(
      "hideRunWithQuerySection", "Hide Run with Query Section", "Results",
      \.hideRunWithQuerySection),
    choice("copyRowsFormat", "Copy rows as", "Results", \.copyRowsFormat, title: \.title),
    points("maxResultHeight", "Max Height", "Results", 200...1000, step: 50, \.maxResultHeight),
    toggle("historyEnabled", "Record query history", "Data", onOnly: true, \.historyEnabled),
    toggle("rewindEnabled", "Record Data Rewind", "Data", onOnly: true, \.rewindEnabled),
    toggle(
      "showExperimentalEngines", "Show experimental engines", "Developer",
      \.showExperimentalEngines),
  ]

  /// Settings and areas the AI may not change: security, keys, outside access, data exposure,
  /// result guards, session brakes, retention that purges at once, and layout state
  static let excluded = [
    Excluded(
      keys: [], title: "AI provider, models, API keys, privacy and inline suggestions",
      place: "Settings > AI"),
    Excluded(keys: [], title: "AI access of a connection", place: "the connection form"),
    Excluded(
      keys: [
        "mcpEnabled", "mcpPort", "mcpAllowedConnectionIDs", "mcpRowCap", "mcpWriteToolsEnabled",
        "mcpWriteScopes",
      ], title: "The MCP server and outside MCP servers", place: "Settings > MCP"),
    Excluded(
      keys: ["shortcutsEnabled", "shortcutsAllowedConnectionIDs"],
      title: "Shortcuts app access", place: "Settings > Shortcuts"),
    Excluded(keys: ["safeMode"], title: "Protection level", place: "Settings > Security"),
    Excluded(keys: ["commitStyle"], title: "Commit style", place: "Settings > Security"),
    Excluded(
      keys: ["lockIdleTimeout"], title: "Lock again after idle", place: "Settings > Security"),
    Excluded(
      keys: [], title: "Safe Mode and Lock passwords, Touch ID", place: "Settings > Security"),
    Excluded(
      keys: ["bypassDestructiveQueryConfirmation"], title: "Run All write confirmation",
      place: nil),
    Excluded(keys: ["launchBehavior"], title: "When Dblore starts", place: "Settings > General"),
    Excluded(keys: [], title: "Automatically Check for Updates", place: "Settings > General"),
    Excluded(
      keys: ["historyRetentionDays", "historyMaxEntries"],
      title: "Query history Keep for and Max entries", place: "Settings > Data"),
    Excluded(
      keys: ["rewindRetentionDays"], title: "Data Rewind Keep for", place: "Settings > Data"),
    Excluded(
      keys: ["neutralizesCopiedFormulas"], title: "Neutralize Copied Formulas",
      place: "Settings > Results"),
    Excluded(
      keys: ["showsInvisibleCharacters"], title: "Show Invisible Characters",
      place: "Settings > Results"),
    Excluded(
      keys: ["resultRowCap", "statementTimeout", "lockTimeout", "idleTimeout"],
      title: "Result row cap and the statement, lock and idle in transaction timeouts",
      place: "Settings > Results"),
    Excluded(
      keys: ["includeResultsOnSave"], title: "Include Results When Saving",
      place: "Settings > Save"),
    Excluded(
      keys: ["mongoPreviewDocumentCount"], title: "Documents an aggregation stage preview shows",
      place: "the MongoDB aggregation options"),
    Excluded(
      keys: [
        "isLeftSidebarVisible", "leftSidebarWidth", "aiSidebarWidth", "aiBubblePosition",
        "aiBubbleCardWidth", "aiBubbleCardHeight",
      ], title: "Sidebar and AI bubble layout", place: nil),
  ]

  @MainActor private static let fontSizes =
    Int(AppSettings.fontSizeRange.lowerBound)...Int(AppSettings.fontSizeRange.upperBound)

  @MainActor
  private static func toggle(
    _ key: String, _ title: String, _ tab: String, onOnly: Bool = false,
    _ path: ReferenceWritableKeyPath<AppSettings, Bool>
  ) -> Entry {
    Entry(
      key: key, title: title, tab: tab, kind: .bool(onOnly: onOnly),
      read: { $0[keyPath: path] ? "true" : "false" },
      write: { settings, value in settings[keyPath: path] = value == "true" })
  }

  @MainActor
  private static func choice<Value: RawRepresentable & CaseIterable>(
    _ key: String, _ title: String, _ tab: String,
    _ path: ReferenceWritableKeyPath<AppSettings, Value>,
    title optionTitle: (Value) -> String = { $0.rawValue }
  ) -> Entry where Value.RawValue == String {
    Entry(
      key: key, title: title, tab: tab,
      kind: .choice(Value.allCases.map { Option(raw: $0.rawValue, title: optionTitle($0)) }),
      read: { $0[keyPath: path].rawValue },
      write: { settings, value in Value(rawValue: value).map { settings[keyPath: path] = $0 } })
  }

  /// A size in points, read and written as whole numbers
  @MainActor
  private static func points(
    _ key: String, _ title: String, _ tab: String, _ range: ClosedRange<Int>, step: Int,
    _ path: ReferenceWritableKeyPath<AppSettings, CGFloat>
  ) -> Entry {
    Entry(
      key: key, title: title, tab: tab, kind: .int(range, step: step), unit: "pt",
      read: { String(Int($0[keyPath: path].rounded())) },
      write: { settings, value in Int(value).map { settings[keyPath: path] = CGFloat($0) } })
  }

  @MainActor
  static func entry(_ key: String) -> Entry? {
    entries.first { $0.key == key }
  }

  // MARK: - list_settings

  /// The allowed settings with their current value, allowed values and tab, then the excluded
  /// settings by place, without values
  @MainActor
  static func listText(settings: AppSettings) -> String {
    var lines = [
      "Settings you can change with change_setting (key: current value; allowed values; "
        + "Settings tab > title):"
    ]
    for entry in entries {
      lines.append(
        "- \(entry.key): \(entry.read(settings)); \(entry.kind.allowed); "
          + "\(entry.tab) > \(entry.title)")
    }
    lines.append("")
    lines.append("You cannot change these; tell the user where to change them:")
    for item in excluded {
      lines.append("- \(item.title): \(item.place ?? "not changeable from the AI chat")")
    }
    return lines.joined(separator: "\n")
  }

  // MARK: - change_setting

  /// Checks the change against the catalog, writes it through the setter and re-reads it.
  /// Turning notifications on goes through `enableLongQueryNotifications` with `authorize`.
  @MainActor
  static func apply(
    _ change: Change, settings: AppSettings, authorize: () async -> Bool
  ) async -> Outcome {
    guard let entry = entry(change.key) else { return .refused(refusal(change.key)) }
    guard let value = entry.kind.canonical(change.value) else {
      return .refused(
        AITools.ToolError(
          message: "That value is not allowed for \(entry.title). Allowed: "
            + "\(entry.kind.allowed)."))
    }
    if case .bool(onOnly: true) = entry.kind, value == "false" {
      return .refused(
        AITools.ToolError(
          message: "Only the user turns \(entry.title) off, in Settings > \(entry.tab): entries "
            + "missed while it is off cannot come back."))
    }
    let old = entry.read(settings)
    guard old != value else { return .noOp(.alreadySet) }
    await write(entry, value, settings: settings, authorize: authorize)
    let new = entry.read(settings)
    guard new != old else { return .noOp(.stayedOff) }
    return .applied(old: old, new: new)
  }

  /// Why a key outside the allowlist is refused, naming where the user changes it. The key
  /// itself is never echoed.
  @MainActor
  private static func refusal(_ key: String) -> AITools.ToolError {
    guard let item = excluded.first(where: { $0.keys.contains(key) }) else {
      return AITools.ToolError(
        message: "That is not a setting you can change. Call list_settings for the keys you "
          + "can change and where the others are.")
    }
    guard let place = item.place else {
      return AITools.ToolError(
        message: "\(item.title) is not a setting you can change from the AI chat.")
    }
    return AITools.ToolError(
      message: "\(item.title) is not a setting you can change. The user changes it in \(place).")
  }

  @MainActor
  private static func write(
    _ entry: Entry, _ value: String, settings: AppSettings, authorize: () async -> Bool
  ) async {
    if entry.key == "notifyLongQueries", value == "true" {
      await settings.enableLongQueryNotifications(authorize: authorize)
    } else {
      entry.write(settings, value)
    }
  }

  // MARK: - Undo

  /// True when a saved change (untrusted JSON) names an allowed setting and both values are
  /// canonical values of its kind. `onOnly` is ignored: it restricts only change_setting.
  @MainActor
  static func validateUndo(key: String, oldValue: String, newValue: String) -> Bool {
    guard let kind = entry(key)?.kind else { return false }
    return kind.canonical(oldValue) == oldValue && kind.canonical(newValue) == newValue
  }

  /// Writes `oldValue` back only while the live value is still `newValue`
  @MainActor
  static func undo(
    key: String, oldValue: String, newValue: String, settings: AppSettings,
    authorize: () async -> Bool
  ) async -> UndoOutcome {
    guard validateUndo(key: key, oldValue: oldValue, newValue: newValue),
      let entry = entry(key)
    else { return .refused }
    guard entry.read(settings) == newValue else { return .changedSince }
    await write(entry, oldValue, settings: settings, authorize: authorize)
    return entry.read(settings) == oldValue ? .undone : .stayedOff
  }
}
