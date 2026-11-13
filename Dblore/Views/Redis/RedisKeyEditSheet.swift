//
//  RedisKeyEditSheet.swift
//  Dblore
//
//  Edits of a Redis key (`RedisKeyEditor`, `RedisKeyWrite`): a sheet with the form of one edit
//  (a string value, the TTL, a rename, a hash field, a list element, a set or sorted-set member,
//  a stream entry, a new key), whose Save checks the input, then asks per the connection's commit
//  style in the same sheet (the Safe Mode panel) or sends at once (Immediate). Values are typed
//  as text (UTF-8); a binary value or field is never typed, an existing one is addressed by its
//  exact bytes. Old values are read again when the sheet opens (a row shows them escaped and
//  cut). `RedisWriteConfirmSheet` asks for a removal started from the key tab (a row's trash
//  icon, Delete). Everything shown from the server is escaped plain text.
//

import AppKit
import SwiftUI

/// What the edit sheet edits
enum RedisKeyEditRequest: Equatable {
  /// A string's whole value (`old`: complete, at most 1 MiB, valid UTF-8)
  case stringValue(RedisKeyRef, old: Data)
  case ttl(RedisKeyRef, hasExpiry: Bool)
  case rename(RedisKeyRef)
  /// A new field (nil) or the value of a field, by its exact bytes
  case hashField(RedisKeyRef, field: Data?)
  case pushElement(RedisKeyRef)
  case listElement(RedisKeyRef, index: Int)
  case setMember(RedisKeyRef)
  /// A new member (nil) or the score of a member, by its exact bytes
  case sortedSetMember(RedisKeyRef, member: Data?)
  case streamEntry(RedisKeyRef)
  case newKey(db: Int, type: RedisKeyViewerModel.KeyType)
}

/// One presentation of the edit sheet
struct RedisKeyEditTarget: Identifiable {
  let id = UUID()
  let request: RedisKeyEditRequest
  /// The connection epoch the key (or the key list) was read under, taken at the click: the
  /// pre-fill and the write use it, never one a reload while the sheet is open read later
  let epoch: UInt64?
}

struct RedisKeyEditSheet: View {
  let request: RedisKeyEditRequest
  /// The connection epoch the key (or the key list) was read under; nil refuses every write
  let epoch: UInt64?
  /// For the Safe Mode "Forgot Password?" fallback
  let databasePassword: String?
  let isConnected: Bool
  /// A write that reached the server; the sheet closes after it
  let onDone: (RedisKeyWrite, RedisKeyEditor.Outcome) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var editor: RedisKeyEditor
  @State private var prefill: Prefill = .loading
  /// The old value read for the pre-fill (a list element's: what the check compares)
  @State private var old: Data?
  @State private var oldScore: String?
  /// The value, element or member typed
  @State private var value = ""
  /// The field, member or key name typed
  @State private var name = ""
  @State private var score = ""
  @State private var seconds = ""
  @State private var end: ListEnd = .tail
  @State private var pairs: [FieldPair] = [FieldPair()]
  /// Why the input was not accepted (too large, not a number)
  @State private var inputError: String?

  private enum Prefill: Equatable {
    case loading
    case ready
    case failed(String)
  }

  private enum ListEnd: Hashable {
    case head, tail

    var title: String { self == .head ? "Head" : "Tail" }
  }

  private struct FieldPair: Identifiable {
    let id = UUID()
    var field = ""
    var value = ""
  }

  private static let width: CGFloat = 520

  init(
    request: RedisKeyEditRequest, context: RedisKeyWriteContext, epoch: UInt64?,
    databasePassword: String?, isConnected: Bool,
    onDone: @escaping (RedisKeyWrite, RedisKeyEditor.Outcome) -> Void
  ) {
    self.request = request
    self.epoch = epoch
    self.databasePassword = databasePassword
    self.isConnected = isConnected
    self.onDone = onDone
    _editor = State(initialValue: RedisKeyEditor(context: context))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      // A form never removes, so it never asks plainly; any confirmation shows here
      if let pending = editor.pending {
        SafeModeConfirmationPanel(
          requiresPassword: pending.requiresPassword, confirmTitle: pending.write.confirmTitle,
          biometricReason: "Authorize the Redis change in Safe Mode",
          databasePassword: databasePassword, isConnected: isConnected,
          isPending: { [editor] in editor.pending?.id == pending.id },
          // Back to the form: nothing is sent
          onCancel: { editor.cancel() },
          onConfirm: { [editor] in
            if let outcome = await editor.confirm(pending) { finish(pending.write, outcome) }
          },
          details: { RedisWriteDetails(write: pending.write) })
      } else {
        form
      }
    }
    .frame(width: Self.width)
    .background(Color.appBackground)
    .interactiveDismissDisabled(editor.phase == .sending)
    .task { await loadPrefill() }
    // Closed any other way: nothing more is asked or sent
    .onDisappear { editor.cancel() }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      Text(verbatim: title)
        .font(.subheading)
        .foregroundColor(.foreground)
      Spacer()
      Button(action: close) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .keyboardShortcut(.cancelAction)
      .disabled(editor.phase == .sending)
      .help("Close")
    }
    .modalBarPadding(vertical: Spacing.sm)
  }

  private var title: String {
    switch request {
    case .stringValue: "Edit Value"
    case .ttl: "Set TTL"
    case .rename: "Rename Key"
    case .hashField(_, let field): field == nil ? "Add Field" : "Edit Field"
    case .pushElement: "Add Element"
    case .listElement(_, let index): "Edit Element \(index)"
    case .setMember: "Add Member"
    case .sortedSetMember(_, let member): member == nil ? "Add Member" : "Edit Score"
    case .streamEntry: "Add Entry"
    case .newKey(let db, let type): "New \(type.title) Key in db \(db)"
    }
  }

  /// The key the request is about; nil for a new key
  private var key: RedisKeyRef? {
    switch request {
    case .stringValue(let key, _), .ttl(let key, _), .rename(let key), .hashField(let key, _),
      .pushElement(let key), .listElement(let key, _), .setMember(let key),
      .sortedSetMember(let key, _), .streamEntry(let key):
      key
    case .newKey: nil
    }
  }

  // MARK: - Form

  private var form: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if let key {
        caption("Key \(RedisKeyBrowserModel.label(key.bytes)) in db \(key.db)")
      }
      switch prefill {
      case .loading:
        HStack {
          Spacer()
          DelayedSpinner()
          Spacer()
        }
        .frame(minHeight: 80)
      case .failed(let message):
        errorLine(message)
      case .ready:
        fields
      }
      if prefill == .ready {
        status
        buttons
      } else {
        HStack {
          Spacer()
          Button("Close", action: close)
            .buttonStyle(SecondaryButtonStyle())
        }
      }
    }
    .padding(Spacing.md)
    .disabled(editor.isBusy)
  }

  @ViewBuilder
  private var fields: some View {
    switch request {
    case .stringValue:
      input("Value", text: $value, singleLine: false)
    case .ttl(_, let hasExpiry):
      labeled("Seconds") {
        TextField("", text: $seconds, prompt: Text("e.g. 3600"))
          .textFieldStyle(.plain)
          .font(.monoMedium)
          .padding(.horizontal, Spacing.sm)
          .frame(height: 26)
          .background(Color.inputBackground)
          .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
          .overlay(HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.sm)))
          .onSubmit(save)
      }
      caption(hasExpiry ? "The key expires; a new TTL replaces it." : "The key has no expiry.")
    case .rename:
      input("New name", text: $name, singleLine: true)
    case .hashField(_, let field):
      if let field {
        caption("Field " + RedisKeyViewerModel.cell(field, limit: 200))
      } else {
        input("Field", text: $name, singleLine: true)
      }
      input("Value", text: $value, singleLine: false)
    case .pushElement:
      CapsuleTabPicker(selection: $end, tabs: [.head, .tail], height: 28) { tab in
        CapsuleTabLabel(text: tab.title, isSelected: end == tab)
      }
      .fitsContent()
      .accessibilityLabel("Where to add")
      .help("Head: before the first element (LPUSH). Tail: after the last one (RPUSH).")
      input("Element", text: $value, singleLine: false)
    case .listElement:
      input("Element", text: $value, singleLine: false)
    case .setMember:
      input("Member", text: $name, singleLine: true)
    case .sortedSetMember(_, let member):
      if let member {
        caption("Member " + RedisKeyViewerModel.cell(member, limit: 200))
      } else {
        input("Member", text: $name, singleLine: true)
      }
      scoreField
    case .streamEntry:
      streamFields
    case .newKey(_, let type):
      input("Key name", text: $name, singleLine: true)
      newKeyFields(type)
    }
  }

  @ViewBuilder
  private func newKeyFields(_ type: RedisKeyViewerModel.KeyType) -> some View {
    switch type {
    case .hash:
      pairRow($pairs[0], fieldTitle: "Field", removable: false)
    case .stream:
      pairRow($pairs[0], fieldTitle: "Field", removable: false)
      caption("The server picks the entry ID.")
    case .sortedSet:
      input("Member", text: $value, singleLine: true)
      scoreField
    case .set:
      input("Member", text: $value, singleLine: true)
    case .list:
      input("Element", text: $value, singleLine: false)
    case .string, .other:
      input("Value", text: $value, singleLine: false)
    }
  }

  private var scoreField: some View {
    labeled("Score") {
      TextField("", text: $score, prompt: Text("e.g. 1.5"))
        .textFieldStyle(.plain)
        .font(.monoMedium)
        .padding(.horizontal, Spacing.sm)
        .frame(height: 26)
        .background(Color.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
        .overlay(HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.sm)))
    }
  }

  private var streamFields: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      // By each pair's id: a removed pair never leaves a binding to a gone index
      ForEach($pairs) { $pair in
        pairRow($pair, fieldTitle: "Field", removable: pairs.count > 1)
      }
      HStack {
        Button {
          pairs.append(FieldPair())
        } label: {
          Label("Add Field", systemImage: "plus")
        }
        .buttonStyle(SecondaryButtonStyle(vPadding: Spacing.xs))
        .disabled(pairs.count >= 64)
        Spacer()
      }
      caption("The server picks the entry ID.")
    }
  }

  private func pairRow(
    _ pair: Binding<FieldPair>, fieldTitle: String, removable: Bool
  ) -> some View {
    HStack(alignment: .bottom, spacing: Spacing.sm) {
      input(fieldTitle, text: pair.field, singleLine: true)
      input("Value", text: pair.value, singleLine: true)
      if removable {
        let id = pair.wrappedValue.id
        Button {
          pairs.removeAll { $0.id == id }
        } label: {
          Image(systemName: "minus.circle")
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .help("Remove this field")
        .padding(.bottom, 2)
      }
    }
  }

  @ViewBuilder
  private var status: some View {
    if let inputError {
      errorLine(inputError)
    } else if case .failed(let message) = editor.phase {
      errorLine(message)
    } else if editor.isBusy {
      HStack(spacing: Spacing.sm) {
        DelayedSpinner()
        Text(editor.phase == .checking ? "Checking..." : "Saving...")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
    }
  }

  private var buttons: some View {
    HStack(spacing: Spacing.sm) {
      if case .ttl(let key, true) = request {
        Button("Remove Expiry") { submit(.persist(key)) }
          .buttonStyle(SecondaryButtonStyle())
          .help("PERSIST: the key no longer expires")
      }
      Spacer()
      Button("Cancel", action: close)
        .buttonStyle(SecondaryButtonStyle())
      Button(saveTitle, action: save)
        .buttonStyle(PrimaryButtonStyle())
        .keyboardShortcut(.defaultAction)
    }
  }

  private var saveTitle: String {
    switch request {
    case .rename: "Rename"
    case .newKey: "Create"
    case .pushElement, .setMember, .streamEntry: "Add"
    case .hashField(_, let field): field == nil ? "Add" : "Save"
    case .sortedSetMember(_, let member): member == nil ? "Add" : "Save"
    default: "Save"
    }
  }

  // MARK: - Pieces

  private func input(_ title: String, text: Binding<String>, singleLine: Bool) -> some View {
    labeled(title) {
      RedisTextInput(text: text, isSingleLine: singleLine, onSubmit: save)
        .frame(height: singleLine ? 26 : 140)
        .background(Color.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
        .overlay(HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.sm)))
        .accessibilityLabel(title)
    }
  }

  private func labeled<Content: View>(
    _ title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text(title)
        .font(.small.weight(.medium))
        .foregroundColor(.foregroundMuted)
      content()
    }
  }

  private func caption(_ text: String) -> some View {
    Text(verbatim: text)
      .font(.small)
      .foregroundColor(.foregroundMuted)
      .lineLimit(2)
      .truncationMode(.tail)
      .textSelection(.enabled)
  }

  private func errorLine(_ text: String) -> some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.destructive)
        .accessibilityHidden(true)
      Text(verbatim: text)
        .font(.small)
        .foregroundColor(.foreground)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Actions

  private func close() {
    editor.cancel()
    dismiss()
  }

  private func finish(_ write: RedisKeyWrite, _ outcome: RedisKeyEditor.Outcome) {
    onDone(write, outcome)
    dismiss()
  }

  private func save() {
    guard prefill == .ready, !editor.isBusy else { return }
    do {
      submit(try write())
    } catch {
      inputError = (error as? RedisKeyEditError)?.message ?? error.localizedDescription
    }
  }

  private func submit(_ write: RedisKeyWrite) {
    inputError = nil
    Task {
      if let outcome = await editor.request(write, epoch: epoch) { finish(write, outcome) }
    }
  }

  /// The write the form describes; throws when the input is not accepted
  private func write() throws -> RedisKeyWrite {
    let typed = Data(value.utf8)
    switch request {
    case .stringValue(let key, let old):
      return try .stringValue(key, value: typed, old: old)
    case .ttl(let key, _):
      return try .expire(key, seconds: RedisKeyWrite.seconds(seconds))
    case .rename(let key):
      return try .rename(key, to: Data(name.utf8))
    case .hashField(let key, let field):
      return try .hashField(key, field: field ?? Data(name.utf8), value: typed, old: old)
    case .pushElement(let key):
      return try .pushElement(key, value: typed, atHead: end == .head)
    case .listElement(let key, let index):
      guard let old else { throw RedisKeyEditError(message: "The element was not read.") }
      return try .listElement(key, index: index, value: typed, old: old)
    case .setMember(let key):
      return try .addSetMember(key, member: Data(name.utf8))
    case .sortedSetMember(let key, let member):
      return try .sortedSetMember(
        key, member: member ?? Data(name.utf8), score: RedisKeyWrite.score(score),
        oldScore: oldScore)
    case .streamEntry(let key):
      return try .addStreamEntry(
        key, fields: pairs.map { (Data($0.field.utf8), Data($0.value.utf8)) })
    case .newKey(let db, let type):
      let key = RedisKeyRef(db: db, bytes: Data(name.utf8))
      let first = pairs.first ?? FieldPair()
      let content: RedisKeyWrite.NewKeyContent
      switch type {
      case .hash: content = .hash(field: Data(first.field.utf8), value: Data(first.value.utf8))
      case .stream:
        content = .stream(field: Data(first.field.utf8), value: Data(first.value.utf8))
      case .list: content = .list(typed)
      case .set: content = .set(typed)
      case .sortedSet: content = .sortedSet(member: typed, score: try RedisKeyWrite.score(score))
      case .string, .other: content = .string(typed)
      }
      return try .create(key, content: content)
    }
  }

  /// Reads the old value the form starts from (off the main thread, under the key's epoch): a
  /// string's loaded bytes, a hash field's value, a list element, a member's score. A binary
  /// old value cannot be typed, one over 1 MiB is not read into the form: the form says so.
  private func loadPrefill() async {
    guard prefill == .loading else { return }
    let source: RedisKeyEditor.PrefillSource
    let gone: String
    switch request {
    case .stringValue(_, let bytes):
      (source, gone) = (.loaded(bytes), "The value no longer exists")
    case .rename(let key):
      // Server key names are not size-capped: a name over 1 MiB starts empty, and the decode
      // runs off the main thread
      let bytes = key.bytes
      if bytes.count <= RedisKeyWrite.maxInputBytes {
        name = await Self.editableName(bytes) ?? ""
      }
      prefill = .ready
      return
    case .hashField(let key, let field?):
      (source, gone) = (.hashField(key, field: field), "The field no longer exists")
    case .listElement(let key, let index):
      (source, gone) = (
        .listElement(key, index: index), "The list has no element at index \(index) any more"
      )
    case .sortedSetMember(let key, let member?):
      (source, gone) = (.score(key, member: member), "The member no longer exists")
    default:
      prefill = .ready
      return
    }
    switch await editor.prefill(source, epoch: epoch) {
    case .value(let bytes, let text):
      old = bytes
      value = text
      prefill = .ready
    case .score(let written):
      oldScore = written
      score = written
      prefill = .ready
    case .gone:
      prefill = .failed(gone + "; reload the key.")
    case .failed(let message):
      prefill = .failed(message)
    }
  }

  /// The key name as text to edit (nil for a binary name), decoded off the main thread
  @concurrent private nonisolated static func editableName(_ bytes: Data) async -> String? {
    RedisKeyWrite.editableText(bytes)
  }
}

// MARK: - Removal confirmation

/// The Safe Mode panel (password or Touch ID, as the commit style asks) for a removal started in
/// the key tab. A late Touch ID answer after the sheet closed sends nothing (`isPending`).
struct RedisWriteConfirmSheet: View {
  let editor: RedisKeyEditor
  let confirmation: RedisKeyEditor.Confirmation
  /// For the Safe Mode "Forgot Password?" fallback
  let databasePassword: String?
  let isConnected: Bool
  let onDone: (RedisKeyWrite, RedisKeyEditor.Outcome) -> Void

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Spacing.sm) {
        Text(verbatim: confirmation.write.title)
          .font(.subheading)
          .foregroundColor(.foreground)
        Spacer()
        Button(action: close) {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .keyboardShortcut(.cancelAction)
        .help("Close")
      }
      .modalBarPadding(vertical: Spacing.sm)
      Divider()
      SafeModeConfirmationPanel(
        requiresPassword: confirmation.requiresPassword,
        confirmTitle: confirmation.write.confirmTitle,
        biometricReason: "Authorize the Redis change in Safe Mode",
        databasePassword: databasePassword, isConnected: isConnected,
        isPending: { [editor, confirmation] in editor.pending?.id == confirmation.id },
        onCancel: close,
        onConfirm: { [editor, confirmation, onDone] in
          if let outcome = await editor.confirm(confirmation) {
            onDone(confirmation.write, outcome)
          }
        },
        details: { RedisWriteDetails(write: confirmation.write) })
    }
    .frame(width: 520)
    .background(Color.appBackground)
    // Closed any other way: nothing is sent
    .onDisappear {
      if editor.pending?.id == confirmation.id { editor.cancel() }
    }
  }

  private func close() {
    editor.cancel()
    dismiss()
  }
}

/// A write's confirmation lines: key, db, field / index / member, old and new value (escaped)
struct RedisWriteDetails: View {
  let write: RedisKeyWrite

  var body: some View {
    Text(verbatim: write.details.joined(separator: "\n"))
      .font(.mono)
      .foregroundColor(.foreground)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
  }
}

// MARK: - Text input

/// Editable plain text for a value, field, member or key name: no rich text, and no smart
/// quotes, dashes, text replacement, spelling correction or data detection, so the bytes sent
/// are the characters typed (UTF-8)
/// One line (`isSingleLine`: a name, field or member): Return submits instead of typing a line
/// break, Tab moves to the next field instead of typing a tab.
struct RedisTextInput: NSViewRepresentable {
  @Binding var text: String
  var isSingleLine = false
  var onSubmit: () -> Void = {}

  final class Coordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>
    var isSingleLine: Bool
    var onSubmit: () -> Void

    init(text: Binding<String>, isSingleLine: Bool, onSubmit: @escaping () -> Void) {
      self.text = text
      self.isSingleLine = isSingleLine
      self.onSubmit = onSubmit
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      text.wrappedValue = textView.string
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      guard isSingleLine else { return false }
      switch selector {
      case #selector(NSResponder.insertNewline(_:)):
        onSubmit()
      case #selector(NSResponder.insertTab(_:)):
        textView.window?.selectNextKeyView(nil)
      case #selector(NSResponder.insertBacktab(_:)):
        textView.window?.selectPreviousKeyView(nil)
      default:
        return false
      }
      return true
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, isSingleLine: isSingleLine, onSubmit: onSubmit)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    scrollView.drawsBackground = false
    scrollView.autohidesScrollers = true
    guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.isGrammarCheckingEnabled = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.isAutomaticDataDetectionEnabled = false
    textView.smartInsertDeleteEnabled = false
    textView.drawsBackground = false
    textView.font = ResultGridCoordinator.font
    textView.textColor = NSColor(Color.foreground)
    textView.insertionPointColor = NSColor(Color.foreground)
    textView.textContainerInset = NSSize(width: Spacing.xs, height: Spacing.xs)
    textView.string = text
    textView.delegate = context.coordinator
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.text = $text
    context.coordinator.isSingleLine = isSingleLine
    context.coordinator.onSubmit = onSubmit
    guard let textView = scrollView.documentView as? NSTextView else { return }
    // By bytes: `String ==` takes NFC and NFD for equal, which would keep the other form shown
    if !textView.string.utf8.elementsEqual(text.utf8) {
      textView.string = text
    }
  }
}
