//
//  ConnectionSafetyMenus.swift
//  Dblore
//
//  Hot change of a live connection's protection level and security level.
//  Lowering under a password Safe Mode waits for the unlock; nothing changes before that.
//

import SwiftUI

/// What the unlock sheet is holding. Applied only after verification succeeds.
private enum PendingSafetyChange: Equatable {
  case protection(ConnectionProtectionLevel)
  case commitStyle(CommitStyle)
}

/// Protection and security menus for the connected database.
/// `prominent` is the settings row. The footer uses short badges that sit inside the bar.
struct ConnectionSafetyMenus: View {
  @Bindable var viewModel: NotebookViewModel
  var showsProtection = true
  var showsSecurity = true
  var prominent = false

  @State private var pending: PendingSafetyChange?

  private var protection: ConnectionProtectionLevel {
    viewModel.notebook.connectionConfig?.protectionLevel ?? .none
  }

  /// Checkmark follows the resolved style. Opening the menu does not apply it.
  private var resolvedStyle: CommitStyle {
    let fallback = AppSettings.shared.commitStyle
    return viewModel.notebook.connectionConfig?.resolvedCommitStyle(fallback: fallback) ?? fallback
  }

  var body: some View {
    if viewModel.connectionState.isConnected {
      menus
        .sheet(
          isPresented: Binding(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
          )
        ) {
          SafeModeUnlockSheet(
            message: unlockMessage,
            biometricReason: unlockReason,
            storedDatabasePassword: viewModel.notebook.connectionConfig?.password,
            onUnlock: applyPending,
            onCancel: { pending = nil })
        }
    } else if prominent {
      Text("Connect to a database to change its protection level and security level.")
        .font(.bodyText)
        .foregroundColor(.foregroundSubtle)
    }
  }

  @ViewBuilder
  private var menus: some View {
    if prominent {
      VStack(alignment: .leading, spacing: Spacing.md) {
        if showsProtection { protectionRow }
        if showsSecurity { securityRow }
      }
    } else {
      HStack(spacing: Spacing.sm) {
        if showsProtection { protectionMenu }
        if showsSecurity { securityMenu }
      }
    }
  }

  private var protectionRow: some View {
    labeledRow(title: "Protection level", detail: protection.description) {
      protectionMenu
    }
  }

  private var securityRow: some View {
    labeledRow(title: "Commit style", detail: resolvedStyle.summary) {
      securityMenu
    }
  }

  private func labeledRow<Control: View>(
    title: String, detail: String, @ViewBuilder control: () -> Control
  ) -> some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.bodyText)
        Text(detail)
          .font(.bodyText)
          .foregroundColor(.foregroundSubtle)
      }
      Spacer()
      control()
    }
  }

  private var protectionMenu: some View {
    SafetyOptionMenu(arrowEdge: prominent ? .top : .bottom, rows: protectionRows) {
      menuLabel(
        protection.displayName, icon: protection.iconName,
        iconColor: SafetyOptionStyle.color(for: protection))
    }
    .help(protection.description)
  }

  private var protectionRows: [SafetyOptionRow] {
    ConnectionProtectionLevel.allCases.map { level in
      SafetyOptionRow(
        id: level.rawValue,
        title: level.displayName,
        systemImage: level.iconName,
        color: SafetyOptionStyle.color(for: level),
        selected: level == protection
      ) {
        selectProtection(level)
      }
    }
  }

  private var securityMenu: some View {
    SafetyOptionMenu(
      arrowEdge: prominent ? .top : .bottom, rows: securityRows, showsCommitStyleHelp: true
    ) {
      menuLabel(
        resolvedStyle.title,
        icon: SafetyOptionStyle.iconName(for: resolvedStyle),
        iconColor: SafetyOptionStyle.color(for: resolvedStyle))
    }
    .help(resolvedStyle.summary)
  }

  private var securityRows: [SafetyOptionRow] {
    SafetyOptionRow.commitStyles(idPrefix: "footer", selected: resolvedStyle) { style in
      selectCommitStyle(style)
    }
  }

  private func menuLabel(_ title: String, icon: String, iconColor: Color) -> some View {
    HStack(spacing: prominent ? Spacing.xs : Spacing.xxs) {
      Image(systemName: icon)
        .font(prominent ? .caption : .system(size: 9, weight: .semibold))
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(iconColor)
      Text(title)
        .font(prominent ? .body : .smallest)
        .foregroundStyle(prominent ? iconColor : Color.foregroundMuted)
        .lineLimit(1)
      Image(systemName: "chevron.up.chevron.down")
        .font(prominent ? .caption : .system(size: 7, weight: .semibold))
        .foregroundStyle(Color.foregroundMuted)
    }
    .modifier(SafetyMenuSurface(prominent: prominent))
  }

  private func selectProtection(_ level: ConnectionProtectionLevel) {
    guard level != protection else { return }
    if viewModel.requestProtectionLevelChange(to: level) { return }
    pending = .protection(level)
  }

  /// A click always asks, including a click on the style that is already resolved.
  /// Building the menu does not.
  private func selectCommitStyle(_ style: CommitStyle) {
    if viewModel.requestConnectionCommitStyle(style) { return }
    pending = .commitStyle(style)
  }

  private func applyPending() {
    switch pending {
    case .protection(let level):
      viewModel.applyProtectionLevel(level)
    case .commitStyle(let style):
      viewModel.applyConnectionCommitStyle(style)
    case nil:
      break
    }
    pending = nil
  }

  private var unlockMessage: String {
    switch pending {
    case .protection(let level):
      return
        "Safe Mode requires verification to lower this connection's protection to \"\(level.displayName)\"."
    case .commitStyle(let style):
      return
        "Safe Mode requires verification to lower this connection's commit style to \"\(style.title)\"."
    case nil:
      return ""
    }
  }

  private var unlockReason: String {
    switch pending {
    case .protection:
      return "Lower the connection protection level"
    case .commitStyle:
      return "Lower this connection's commit style"
    case nil:
      return "Change connection safety"
    }
  }
}

/// AppKit menus and pickers drop SwiftUI tints, so these rows are a SwiftUI popover.
struct SafetyOptionRow: Identifiable {
  let id: String
  let title: String
  let subtitle: String?
  let systemImage: String
  let color: Color
  let selected: Bool
  let action: () -> Void

  init(
    id: String,
    title: String,
    subtitle: String? = nil,
    systemImage: String,
    color: Color,
    selected: Bool,
    action: @escaping () -> Void
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.systemImage = systemImage
    self.color = color
    self.selected = selected
    self.action = action
  }

  /// Immediate, Confirm, Review, Password. No Use Global row.
  static func commitStyles(
    idPrefix: String,
    selected: CommitStyle,
    onSelect: @escaping (CommitStyle) -> Void
  ) -> [SafetyOptionRow] {
    CommitStyle.allCases.map { style in
      SafetyOptionRow(
        id: "\(idPrefix)-\(style.rawValue)",
        title: style.title,
        subtitle: style.summary,
        systemImage: SafetyOptionStyle.iconName(for: style),
        color: SafetyOptionStyle.color(for: style),
        selected: style == selected,
        action: { onSelect(style) }
      )
    }
  }
}

enum SafetyOptionStyle {
  static func color(for level: ConnectionProtectionLevel) -> Color {
    switch level {
    case .none: return .foregroundMuted
    case .schemaOnly: return .syntaxFunction
    case .readOnly: return .warning
    }
  }

  static func color(for style: CommitStyle) -> Color {
    switch style {
    case .immediate: return immediateTint
    case .confirm: return .warning
    case .review: return .syntaxFunction
    case .password: return .success
    }
  }

  static func iconName(for style: CommitStyle) -> String {
    switch style {
    case .immediate: return "bolt.fill"
    case .confirm: return "exclamationmark.triangle.fill"
    case .review: return "clock.badge.checkmark"
    case .password: return "lock.shield.fill"
    }
  }

  /// Violet, so Immediate stays distinct from the muted None row and from Review.
  private static let immediateTint = Color(
    light: Color(hex: "7c3aed"),
    dark: Color(hex: "a78bfa"))
}

struct SafetyOptionMenu<Label: View>: View {
  var arrowEdge: Edge = .bottom
  let rows: [SafetyOptionRow]
  /// Header "?" on the commit-style popover. Opening it does not select a style.
  var showsCommitStyleHelp = false
  @ViewBuilder var label: () -> Label
  @State private var isOpen = false

  var body: some View {
    Button {
      isOpen.toggle()
    } label: {
      label()
    }
    .buttonStyle(.plain)
    .fixedSize(horizontal: true, vertical: true)
    .linkPointer()
    .popover(isPresented: $isOpen, arrowEdge: arrowEdge) {
      SafetyOptionList(rows: rows, showsCommitStyleHelp: showsCommitStyleHelp) {
        isOpen = false
      }
    }
  }
}

private struct SafetyOptionList: View {
  let rows: [SafetyOptionRow]
  var showsCommitStyleHelp = false
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if showsCommitStyleHelp {
        CommitStyleMenuHeader()
      }
      ForEach(rows) { row in
        SafetyOptionListRow(row: row, dismiss: dismiss)
      }
    }
    .padding(Spacing.xs)
    .frame(minWidth: rows.contains { $0.subtitle != nil } ? 320 : 188)
  }
}

/// Header of the commit-style popover. The "?" only opens help.
private struct CommitStyleMenuHeader: View {
  @State private var showsHelp = false

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(spacing: Spacing.sm) {
        Text("Commit style")
          .font(.small)
          .foregroundStyle(Color.foregroundSubtle)
        Spacer(minLength: Spacing.sm)
        Button {
          showsHelp = true
        } label: {
          Image(systemName: "questionmark.circle")
            .font(.body)
            .foregroundStyle(Color.foregroundMuted)
        }
        .buttonStyle(.plain)
        .linkPointer()
        .help("How writes are handled")
        .popover(isPresented: $showsHelp, arrowEdge: .trailing) {
          CommitStyleHelpView()
        }
      }
      Rectangle()
        .fill(Color.border)
        .frame(height: 1)
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.top, Spacing.xxs)
  }
}

private struct SafetyOptionListRow: View {
  let row: SafetyOptionRow
  let dismiss: () -> Void
  @State private var hovering = false

  var body: some View {
    Button {
      dismiss()
      row.action()
    } label: {
      HStack(alignment: .top, spacing: Spacing.sm) {
        Image(systemName: row.selected ? "checkmark" : row.systemImage)
          .font(.system(size: 12, weight: .semibold))
          .symbolRenderingMode(.monochrome)
          .foregroundStyle(row.color)
          .frame(width: 16, height: 16)
          .padding(.top, 2)
        VStack(alignment: .leading, spacing: 1) {
          Text(row.title)
            .font(.body)
            .foregroundStyle(row.color)
          if let subtitle = row.subtitle {
            Text(subtitle)
              .font(.small)
              .foregroundStyle(Color.foregroundSubtle)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, 5)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.sm)
          .fill(hovering ? Color.cellBackgroundHover : Color.clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .linkPointer()
    .onHover { hovering = $0 }
  }
}

private struct SafetyMenuSurface: ViewModifier {
  let prominent: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if prominent {
      content.dropdownCapsuleStyle()
    } else {
      // Hug the label. A borderless menu otherwise stretches to the 28pt footer.
      content
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 2)
        .frame(height: 18)
        .fixedSize(horizontal: true, vertical: true)
        .tintedCapsuleGlass(.secondary)
    }
  }
}
