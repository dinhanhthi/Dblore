//
//  SettingsComponents.swift
//  Dblore
//
//  Reusable components for settings UI
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings group card

/// The settings-page card. The title sits on its own row, separated from the body by a rule.
struct SettingsGroupCard<Content: View, Accessory: View>: View {
  let title: String
  @ViewBuilder var accessory: () -> Accessory
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: Spacing.sm) {
        Text(title)
          .font(.bodyText)
          .fontWeight(.medium)
          .foregroundColor(.foreground)
        Spacer(minLength: Spacing.sm)
        accessory()
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)

      Rectangle()
        .fill(Color.border)
        .frame(height: 1)

      content()
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.cardHeaderBackground, in: RoundedRectangle(cornerRadius: CornerRadius.lg))
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg))
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.lg)
        .stroke(Color.border, lineWidth: 1)
    )
  }
}

extension SettingsGroupCard where Accessory == EmptyView {
  init(title: String, @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.accessory = { EmptyView() }
    self.content = content
  }
}

// MARK: - Settings Section Container

/// A reusable section container for settings with title and icon
struct SettingsSection<Content: View>: View {
  let title: String
  let icon: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: icon)
          .font(.system(size: 16, weight: .semibold))
          .foregroundColor(.foreground)

        Text(title)
          .font(.heading)
          .foregroundColor(.foreground)
      }

      content()
    }
  }
}

// MARK: - Settings Toggle Component

/// On/off setting. The switch sits on the label row; the description is the line below.
struct SettingsToggle<DescriptionContent: View>: View {
  let title: String
  @Binding var isOn: Bool
  var isDisabled: Bool = false
  @ViewBuilder let descriptionContent: () -> DescriptionContent

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(alignment: .center, spacing: Spacing.sm) {
        Text(title)
          .font(.bodyText)
          .foregroundColor(.foreground)
          .accessibilityHidden(true)

        Spacer(minLength: Spacing.sm)

        CompactSwitch(title: title, isOn: $isOn)
      }

      descriptionContent()
    }
    .disabled(isDisabled)
  }
}

/// The system switch, drawn smaller than the default without going down to half size.
/// `scaleEffect` does not change layout, so the slot uses the measured native size.
private struct CompactSwitch: View {
  let title: String
  @Binding var isOn: Bool
  @State private var nativeSize = CGSize(width: 38, height: 22)

  private let scale: CGFloat = 0.75

  var body: some View {
    Color.clear
      .frame(width: nativeSize.width * scale, height: nativeSize.height * scale)
      .overlay {
        Toggle(title, isOn: $isOn)
          .toggleStyle(.switch)
          .labelsHidden()
          .tint(.accent)
          .fixedSize()
          .background {
            GeometryReader { geo in
              Color.clear.preference(key: SwitchSizeKey.self, value: geo.size)
            }
          }
          .scaleEffect(scale)
      }
      .clipped()
      .onPreferenceChange(SwitchSizeKey.self) { size in
        guard size.width > 1, size.height > 1 else { return }
        guard abs(size.width - nativeSize.width) > 0.5 || abs(size.height - nativeSize.height) > 0.5
        else { return }
        nativeSize = size
      }
  }
}

private struct SwitchSizeKey: PreferenceKey {
  static var defaultValue: CGSize = .zero
  static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
    let next = nextValue()
    if next != .zero { value = next }
  }
}

extension SettingsToggle where DescriptionContent == Text {
  /// Convenience initializer for simple text description
  init(
    title: String,
    description: String,
    isOn: Binding<Bool>,
    isDisabled: Bool = false
  ) {
    self.title = title
    self._isOn = isOn
    self.isDisabled = isDisabled
    self.descriptionContent = {
      Text(description)
        .font(.bodyText)
        .foregroundColor(.foregroundSubtle)
    }
  }
}

extension SettingsToggle where DescriptionContent == SettingsToggleDescription {
  /// Convenience initializer for description with optional warning
  init(
    title: String,
    description: String,
    warning: String?,
    isOn: Binding<Bool>,
    isDisabled: Bool = false
  ) {
    self.title = title
    self._isOn = isOn
    self.isDisabled = isDisabled
    self.descriptionContent = {
      SettingsToggleDescription(description: description, warning: warning)
    }
  }
}

/// Helper view for toggle description with optional warning
struct SettingsToggleDescription: View {
  let description: String
  let warning: String?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(description)
        .font(.bodyText)
        .foregroundColor(.foregroundSubtle)

      if let warning = warning {
        HStack(alignment: .top, spacing: Spacing.xs) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.bodyText)
          Text(warning)
        }
        .font(.bodyText)
        .foregroundColor(.warning)
      }
    }
  }
}

// MARK: - Settings Slider Component

/// A reusable slider component for settings with title, value display, and description
struct SettingsSlider<DescriptionContent: View>: View {
  let title: String
  let valueText: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double
  @ViewBuilder let descriptionContent: () -> DescriptionContent

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack {
        Text(title)
          .font(.bodyText)
          .foregroundColor(.foreground)

        Spacer()

        Text(valueText)
          .font(.mono)
          .foregroundColor(.foregroundMuted)
      }

      Slider(value: $value, in: range, step: step)
        .tint(.accent)

      descriptionContent()
    }
  }
}

extension SettingsSlider where DescriptionContent == Text {
  /// Convenience initializer for simple text description
  init(
    title: String,
    valueText: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    step: Double,
    description: String
  ) {
    self.title = title
    self.valueText = valueText
    self._value = value
    self.range = range
    self.step = step
    self.descriptionContent = {
      Text(description)
        .font(.bodyText)
        .foregroundColor(.foregroundSubtle)
    }
  }
}

// MARK: - Capsule Dropdown

/// Capsule pull-down. A menu-style `Picker` draws over the control; this `Menu`
/// opens under the button and keeps it visible. Padding matches a regular button.
struct CapsuleDropdown<Option: Hashable>: View {
  let title: String
  var width: CGFloat? = nil
  var accessibilityLabel: String? = nil
  let options: [Option]
  let optionTitle: (Option) -> String
  let isSelected: (Option) -> Bool
  let onSelect: (Option) -> Void

  var body: some View {
    Menu {
      ForEach(options, id: \.self) { option in
        Button {
          onSelect(option)
        } label: {
          if isSelected(option) {
            Label(optionTitle(option), systemImage: "checkmark")
          } else {
            Text(optionTitle(option))
          }
        }
      }
    } label: {
      HStack(spacing: Spacing.xs) {
        Text(title)
          .lineLimit(1)
        if width != nil {
          Spacer(minLength: Spacing.xs)
        }
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .semibold))
          .foregroundColor(.foregroundMuted)
      }
      .font(ButtonMetrics.regularFont)
      .foregroundColor(.foreground)
      .padding(.horizontal, ButtonMetrics.regularHorizontalPadding)
      .padding(.vertical, ButtonMetrics.regularVerticalPadding)
      .frame(maxWidth: width == nil ? nil : .infinity, alignment: .leading)
      .background(Capsule().fill(Color.inputBackground))
      .overlay(Capsule().stroke(Color.border, lineWidth: 1))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .linkPointer()
    .fixedSize(horizontal: width == nil, vertical: true)
    .frame(width: width, alignment: .leading)
    .accessibilityLabel(accessibilityLabel ?? title)
  }
}

// MARK: - Keyboard Shortcut Row

/// A row displaying an action and its keyboard shortcut
struct ShortcutRow: View {
  let action: String
  let shortcut: String

  var body: some View {
    HStack {
      Text(action)
        .font(.bodyText)
        .foregroundColor(.foregroundMuted)

      Spacer()

      Text(shortcut)
        .font(.monoSmall)
        .foregroundColor(.foregroundSubtle)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Color.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
    }
  }
}

// MARK: - Log Document for Export

struct LogDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.plainText] }

  init() {}

  init(configuration: ReadConfiguration) throws {}

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    // Get logs from file (synchronous operation)
    let logContent = AppLogger.shared.getAllLogsText()
    let data = logContent.data(using: .utf8) ?? Data()
    return FileWrapper(regularFileWithContents: data)
  }
}
