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
  case security(SafeMode?)
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

  private var security: SafeMode? {
    viewModel.notebook.connectionConfig?.safeMode
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
    labeledRow(title: "Security level", detail: securityDetail) {
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
    SafetyOptionMenu(arrowEdge: prominent ? .top : .bottom, rows: securityRows) {
      menuLabel(
        security?.displayName ?? "Global", icon: "shield",
        iconColor: SafetyOptionStyle.color(for: security))
    }
    .help(securityDetail)
  }

  private var securityRows: [SafetyOptionRow] {
    var rows = [
      SafetyOptionRow(
        id: "global",
        title: "Use Global",
        systemImage: "shield",
        color: SafetyOptionStyle.color(for: nil),
        selected: security == nil
      ) {
        selectSecurity(nil)
      }
    ]
    rows += SafeMode.allCases.map { mode in
      SafetyOptionRow(
        id: "mode-\(mode.rawValue)",
        title: mode.displayName,
        systemImage: SafetyOptionStyle.iconName(for: mode),
        color: SafetyOptionStyle.color(for: mode),
        selected: security == mode
      ) {
        selectSecurity(mode)
      }
    }
    return rows
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

  private var securityDetail: String {
    if let security {
      return security.shortDescription
    }
    return "Use global setting (\(AppSettings.shared.safeMode.displayName))"
  }

  private func selectProtection(_ level: ConnectionProtectionLevel) {
    guard level != protection else { return }
    if viewModel.requestProtectionLevelChange(to: level) { return }
    pending = .protection(level)
  }

  private func selectSecurity(_ mode: SafeMode?) {
    guard mode != security else { return }
    if viewModel.requestConnectionSafeModeChange(to: mode) { return }
    pending = .security(mode)
  }

  private func applyPending() {
    switch pending {
    case .protection(let level):
      viewModel.applyProtectionLevel(level)
    case .security(let mode):
      viewModel.applyConnectionSafeMode(mode)
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
    case .security(nil):
      return
        "Safe Mode requires verification to use the global security level for this connection."
    case .security(.some(let mode)):
      return
        "Safe Mode requires verification to lower this connection's security level to \"\(mode.displayName)\"."
    case nil:
      return ""
    }
  }

  private var unlockReason: String {
    switch pending {
    case .protection:
      return "Lower the connection protection level"
    case .security:
      return "Lower this connection's security level"
    case nil:
      return "Change connection safety"
    }
  }
}

/// AppKit menus and pickers drop SwiftUI tints, so these rows are a SwiftUI popover.
struct SafetyOptionRow: Identifiable {
  let id: String
  let title: String
  let systemImage: String
  let color: Color
  let selected: Bool
  let action: () -> Void
}

enum SafetyOptionStyle {
  static func color(for level: ConnectionProtectionLevel) -> Color {
    switch level {
    case .none: return .foregroundMuted
    case .schemaOnly: return .syntaxFunction
    case .readOnly: return .warning
    }
  }

  static func color(for mode: SafeMode?) -> Color {
    switch mode {
    case nil: return .foregroundMuted
    case .silent: return silentTint
    case .alertRead: return .warning
    case .alertAll: return .destructive
    case .safeRead: return .syntaxFunction
    case .safeAll: return .success
    }
  }

  static func iconName(for mode: SafeMode) -> String {
    switch mode {
    case .silent: return "bolt.fill"
    case .alertRead, .alertAll: return "exclamationmark.triangle.fill"
    case .safeRead, .safeAll: return "lock.shield.fill"
    }
  }

  /// Violet, so Silent stays distinct from the gray Global row and from the sky Safe (Read) row.
  private static let silentTint = Color(
    light: Color(hex: "7c3aed"),
    dark: Color(hex: "a78bfa"))
}

struct SafetyOptionMenu<Label: View>: View {
  var arrowEdge: Edge = .bottom
  let rows: [SafetyOptionRow]
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
      SafetyOptionList(rows: rows) { isOpen = false }
    }
  }
}

private struct SafetyOptionList: View {
  let rows: [SafetyOptionRow]
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(rows) { row in
        SafetyOptionListRow(row: row, dismiss: dismiss)
      }
    }
    .padding(Spacing.xs)
    .frame(minWidth: 188)
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
      HStack(spacing: Spacing.sm) {
        Image(systemName: row.selected ? "checkmark" : row.systemImage)
          .font(.system(size: 12, weight: .semibold))
          .symbolRenderingMode(.monochrome)
          .foregroundStyle(row.color)
          .frame(width: 16)
        Text(row.title)
          .font(.body)
          .foregroundStyle(row.color)
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
