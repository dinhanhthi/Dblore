//
//  CellValueValidator.swift
//  Dblore
//
//  Validation logic for cell values based on their type.
//  Extracted from CellInfoContent for testability.
//

import Foundation

/// Result of validation for a cell value
enum ValidationResult: Equatable, Sendable {
  case valid
  case invalid(String)

  nonisolated var isValid: Bool {
    if case .valid = self {
      return true
    }
    return false
  }

  nonisolated var errorMessage: String? {
    if case .invalid(let message) = self {
      return message
    }
    return nil
  }
}

/// Validates user input for cell values based on the target type
struct CellValueValidator: Sendable {

  /// Validates input string for a given cell value type
  /// - Parameters:
  ///   - input: The input string to validate
  ///   - valueType: The target CellValue type
  /// - Returns: ValidationResult indicating if input is valid or error message
  nonisolated static func validate(_ input: String, for valueType: CellValue) -> ValidationResult {
    // String type accepts anything
    if case .string = valueType {
      return .valid
    }

    // Validate based on the target value type
    switch valueType {
    case .int:
      return validateInteger(input)

    case .double:
      return validateDouble(input)

    case .null:
      return validateNull(input)

    case .json:
      return validateJSON(input)

    case .date:
      return validateDate(input)

    case .bool:
      return validateBoolean(input)

    case .data:
      return validateBinaryData(input)

    case .string:
      return .valid
    }
  }

  // MARK: - Type-specific Validators

  nonisolated private static func validateInteger(_ input: String) -> ValidationResult {
    if input.isEmpty {
      return .invalid("Value cannot be empty")
    }

    if Int(input) == nil {
      return .invalid("Invalid integer format")
    }

    return .valid
  }

  nonisolated private static func validateDouble(_ input: String) -> ValidationResult {
    if input.isEmpty {
      return .invalid("Value cannot be empty")
    }

    if Double(input) == nil {
      return .invalid("Invalid number format")
    }

    return .valid
  }

  nonisolated private static func validateNull(_ input: String) -> ValidationResult {
    // NULL accepts empty string or "null"
    if !input.isEmpty && input.lowercased() != "null" {
      return .invalid("Use empty or 'null' for NULL values")
    }

    return .valid
  }

  nonisolated private static func validateJSON(_ input: String) -> ValidationResult {
    if input.isEmpty {
      return .invalid("JSON cannot be empty")
    }

    // Try to parse the input as JSON
    guard let data = input.data(using: .utf8),
      (try? JSONSerialization.jsonObject(with: data, options: [.allowFragments])) != nil
    else {
      return .invalid("Invalid JSON syntax")
    }

    return .valid
  }

  nonisolated private static func validateDate(_ input: String) -> ValidationResult {
    if input.isEmpty {
      return .invalid("Date cannot be empty")
    }

    let iso8601Formatter = ISO8601DateFormatter()
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

    // Try ISO8601 format first
    if let parsedDate = iso8601Formatter.date(from: input) {
      // Verify the formatted date matches the input EXACTLY (to catch extra characters)
      let formatted = iso8601Formatter.string(from: parsedDate)
      if formatted == input {
        return .valid
      } else {
        return .invalid("Invalid date format (use ISO8601 or yyyy-MM-dd HH:mm:ss)")
      }
    }

    // Try PostgreSQL timestamp format
    if let parsedDate = dateFormatter.date(from: input) {
      // Verify the formatted date matches the input EXACTLY (to catch extra characters)
      let formatted = dateFormatter.string(from: parsedDate)
      if formatted == input {
        return .valid
      } else {
        return .invalid("Invalid date format (use ISO8601 or yyyy-MM-dd HH:mm:ss)")
      }
    }

    return .invalid("Invalid date format (use ISO8601 or yyyy-MM-dd HH:mm:ss)")
  }

  nonisolated private static func validateBoolean(_ input: String) -> ValidationResult {
    let lowercased = input.lowercased()
    let validBooleans = ["true", "false", "1", "0", "t", "f", "yes", "no", "y", "n"]

    if !validBooleans.contains(lowercased) {
      return .invalid("Invalid boolean value (use true/false)")
    }

    return .valid
  }

  nonisolated private static func validateBinaryData(_ input: String) -> ValidationResult {
    if input.isEmpty {
      return .invalid("Binary data cannot be empty")
    }

    // Accept any non-empty string (could be hex string or base64)
    return .valid
  }
}
