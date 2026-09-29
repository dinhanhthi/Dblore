//
//  SettingsComponents.swift
//  Dblore
//
//  Reusable components for settings UI
//

import SwiftUI
import UniformTypeIdentifiers

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

/// A reusable toggle component for settings with title and description
struct SettingsToggle<DescriptionContent: View>: View {
  let title: String
  @Binding var isOn: Bool
  var isDisabled: Bool = false
  @ViewBuilder let descriptionContent: () -> DescriptionContent

  // Checkbox width + spacing to align description with label text
  private let checkboxIndent: CGFloat = 20

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Toggle(title, isOn: $isOn)
        .font(.bodyText)
        .foregroundColor(.foreground)
        .tint(.accent)
        .disabled(isDisabled)

      descriptionContent()
        .padding(.leading, checkboxIndent)
    }
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
        .font(.small)
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
        .font(.small)
        .foregroundColor(.foregroundSubtle)

      if let warning = warning {
        HStack(alignment: .top, spacing: Spacing.xs) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.small)
          Text(warning)
        }
        .font(.small)
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
          .font(.subheading)
          .foregroundColor(.foreground)

        Spacer()

        Text(valueText)
          .font(.monoSmall)
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
        .font(.small)
        .foregroundColor(.foregroundSubtle)
    }
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
