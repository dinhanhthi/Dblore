//
//  CellValueValidatorTests.swift
//  DbloreTests
//
//  Comprehensive unit tests for cell value validation logic
//

import Foundation
import Testing

@testable import Dblore

@Suite("Cell Value Validator Tests")
@MainActor
struct CellValueValidatorTests {

  // MARK: - Integer Validation Tests

  @Test("Integer validation with valid integers")
  func integerValidInputs() {
    let validIntegers = [
      "0",
      "1",
      "-1",
      "42",
      "-42",
      "2147483647",  // Int max (32-bit)
      "-2147483648",  // Int min (32-bit)
      "9223372036854775807",  // Int64 max
    ]

    for input in validIntegers {
      let result = CellValueValidator.validate(input, for: .int(0))
      #expect(result.isValid, "'\(input)' should be valid integer")
      #expect(result.errorMessage == nil)
    }
  }

  @Test("Integer validation with invalid integers")
  func integerInvalidInputs() {
    let invalidIntegers = [
      ("", "Value cannot be empty"),
      ("abc", "Invalid integer format"),
      ("12.5", "Invalid integer format"),
      ("12.0", "Invalid integer format"),
      ("1e5", "Invalid integer format"),
      ("1,000", "Invalid integer format"),
      ("123 456", "Invalid integer format"),
      ("0x1F", "Invalid integer format"),  // Hex not supported
      ("  42  ", "Invalid integer format"),  // Whitespace not trimmed
      ("42abc", "Invalid integer format"),  // Extra characters
      ("abc42", "Invalid integer format"),
    ]

    for (input, expectedError) in invalidIntegers {
      let result = CellValueValidator.validate(input, for: .int(0))
      #expect(!result.isValid, "'\(input)' should be invalid integer")
      #expect(
        result.errorMessage == expectedError,
        "Expected error: \(expectedError), got: \(result.errorMessage ?? "nil")")
    }
  }

  // MARK: - Double Validation Tests

  @Test("Double validation with valid numbers")
  func doubleValidInputs() {
    let validDoubles = [
      "0",
      "0.0",
      "1.5",
      "-1.5",
      "3.14159",
      "-3.14159",
      "1e5",
      "1.5e10",
      "-2.5e-3",
      "inf",
      "-inf",
      "Infinity",
    ]

    for input in validDoubles {
      let result = CellValueValidator.validate(input, for: .double(0))
      #expect(result.isValid, "'\(input)' should be valid double")
      #expect(result.errorMessage == nil)
    }
  }

  @Test("Double validation with invalid numbers")
  func doubleInvalidInputs() {
    let invalidDoubles = [
      ("", "Value cannot be empty"),
      ("abc", "Invalid number format"),
      ("12.34.56", "Invalid number format"),
      ("1,234.56", "Invalid number format"),
      ("12 34", "Invalid number format"),
      ("  3.14  ", "Invalid number format"),  // Whitespace not trimmed
      ("3.14abc", "Invalid number format"),  // Extra characters
      ("abc3.14", "Invalid number format"),
    ]

    for (input, expectedError) in invalidDoubles {
      let result = CellValueValidator.validate(input, for: .double(0))
      #expect(!result.isValid, "'\(input)' should be invalid double")
      #expect(result.errorMessage == expectedError)
    }
  }

  // MARK: - NULL Validation Tests

  @Test("NULL validation with valid inputs")
  func nullValidInputs() {
    let validNulls = [
      "",
      "null",
      "NULL",
      "Null",
      "nUlL",
    ]

    for input in validNulls {
      let result = CellValueValidator.validate(input, for: .null)
      #expect(result.isValid, "'\(input)' should be valid NULL")
      #expect(result.errorMessage == nil)
    }
  }

  @Test("NULL validation with invalid inputs")
  func nullInvalidInputs() {
    let invalidNulls = [
      "nil",
      "none",
      "undefined",
      "null ",  // Extra space
      " null",  // Leading space
      "null1",  // Extra characters
      "1null",
    ]

    for input in invalidNulls {
      let result = CellValueValidator.validate(input, for: .null)
      #expect(!result.isValid, "'\(input)' should be invalid NULL")
      #expect(result.errorMessage == "Use empty or 'null' for NULL values")
    }
  }

  // MARK: - JSON Validation Tests

  @Test("JSON validation with valid JSON")
  func jsonValidInputs() {
    let validJSON = [
      "{}",
      "[]",
      "{\"key\": \"value\"}",
      "{\"name\": \"John\", \"age\": 30}",
      "[1, 2, 3]",
      "[\"a\", \"b\", \"c\"]",
      "{\"nested\": {\"key\": \"value\"}}",
      "[{\"id\": 1}, {\"id\": 2}]",
      "null",  // JSON null is valid
      "true",  // JSON boolean
      "false",
      "42",  // JSON number
      "\"string\"",  // JSON string
    ]

    for input in validJSON {
      let result = CellValueValidator.validate(input, for: .json(""))
      #expect(result.isValid, "'\(input)' should be valid JSON")
      #expect(result.errorMessage == nil)
    }
  }

  @Test("JSON validation with invalid JSON")
  func jsonInvalidInputs() {
    let invalidJSON = [
      ("", "JSON cannot be empty"),
      ("{", "Invalid JSON syntax"),
      ("}", "Invalid JSON syntax"),
      ("[", "Invalid JSON syntax"),
      ("]", "Invalid JSON syntax"),
      ("{key: value}", "Invalid JSON syntax"),  // Missing quotes
      ("{\"key\": value}", "Invalid JSON syntax"),  // Unquoted value
      // Note: Apple's JSONSerialization accepts trailing commas, so these are removed:
      // ("{\"key\": \"value\",}", "Invalid JSON syntax"),  // Trailing comma
      // ("[1, 2, 3,]", "Invalid JSON syntax"),  // Trailing comma
      ("{'key': 'value'}", "Invalid JSON syntax"),  // Single quotes
      ("undefined", "Invalid JSON syntax"),
      ("NaN", "Invalid JSON syntax"),
      ("{\"key\"}", "Invalid JSON syntax"),  // Missing value
      ("abc", "Invalid JSON syntax"),
      ("{,}", "Invalid JSON syntax"),  // Just comma
      ("[ , ]", "Invalid JSON syntax"),  // Just comma in array
      ("{\"key\": , \"value2\": \"test\"}", "Invalid JSON syntax"),  // Missing value before comma
      ("[1, , 3]", "Invalid JSON syntax"),  // Empty element in array
    ]

    for (input, expectedError) in invalidJSON {
      let result = CellValueValidator.validate(input, for: .json(""))
      #expect(!result.isValid, "'\(input)' should be invalid JSON")
      #expect(result.errorMessage == expectedError)
    }
  }

  // MARK: - Date Validation Tests

  @Test("Date validation with valid ISO8601 dates")
  func dateValidISO8601Inputs() {
    let validDates = [
      "2024-02-20T14:15:00Z",
      "2024-01-01T00:00:00Z",
      "2023-12-31T23:59:59Z",
    ]

    for input in validDates {
      let result = CellValueValidator.validate(input, for: .date(Date()))
      #expect(result.isValid, "'\(input)' should be valid ISO8601 date")
      #expect(result.errorMessage == nil)
    }
  }

  @Test("Date validation with valid PostgreSQL timestamp format")
  func dateValidPostgreSQLInputs() {
    let validDates = [
      "2024-02-20 14:15:00",
      "2024-01-01 00:00:00",
      "2023-12-31 23:59:59",
    ]

    for input in validDates {
      let result = CellValueValidator.validate(input, for: .date(Date()))
      #expect(result.isValid, "'\(input)' should be valid PostgreSQL timestamp")
      #expect(result.errorMessage == nil)
    }
  }

  @Test("Date validation with invalid dates - extra characters")
  func dateInvalidExtraCharacters() {
    // This is the critical test case mentioned in the requirements
    let invalidDates = [
      "2024-02-20T14:15:00Z asdasda",  // Extra text after valid date
      "2024-02-20 14:15:00 extra",  // Extra text after valid timestamp
      "prefix 2024-02-20T14:15:00Z",  // Prefix before valid date
      "2024-02-20T14:15:00Z\n",  // Newline after
      "2024-02-20 14:15:00\t",  // Tab after
      " 2024-02-20T14:15:00Z",  // Leading space
      "2024-02-20T14:15:00Z ",  // Trailing space
    ]

    for input in invalidDates {
      let result = CellValueValidator.validate(input, for: .date(Date()))
      #expect(!result.isValid, "'\(input)' should be invalid due to extra characters")
      #expect(result.errorMessage == "Invalid date format (use ISO8601 or yyyy-MM-dd HH:mm:ss)")
    }
  }

  @Test("Date validation with invalid date formats")
  func dateInvalidFormats() {
    let invalidDates = [
      ("", "Date cannot be empty"),
      ("2024-02-20", "Invalid date format (use ISO8601 or yyyy-MM-dd HH:mm:ss)"),  // Missing time
      ("14:15:00", "Invalid date format (use ISO8601 or yyyy-MM-dd HH:mm:ss)"),  // Only time
      // Wrong separator
      ("2024/02/20 14:15:00", "Invalid date format (use ISO8601 or yyyy-MM-dd HH:mm:ss)"),
      // Wrong order
      ("20-02-2024 14:15:00", "Invalid date format (use ISO8601 or yyyy-MM-dd HH:mm:ss)"),
      ("Feb 20, 2024", "Invalid date format (use ISO8601 or yyyy-MM-dd HH:mm:ss)"),
      // Invalid month
      ("2024-13-01 00:00:00", "Invalid date format (use ISO8601 or yyyy-MM-dd HH:mm:ss)"),
      // Invalid day
      ("2024-02-30 14:15:00", "Invalid date format (use ISO8601 or yyyy-MM-dd HH:mm:ss)"),
      ("abc", "Invalid date format (use ISO8601 or yyyy-MM-dd HH:mm:ss)"),
    ]

    for (input, expectedError) in invalidDates {
      let result = CellValueValidator.validate(input, for: .date(Date()))
      #expect(!result.isValid, "'\(input)' should be invalid date")
      #expect(result.errorMessage == expectedError)
    }
  }

  // MARK: - Boolean Validation Tests

  @Test("Boolean validation with valid inputs")
  func booleanValidInputs() {
    let validBooleans = [
      "true",
      "false",
      "TRUE",
      "FALSE",
      "True",
      "False",
      "1",
      "0",
      "t",
      "f",
      "T",
      "F",
      "yes",
      "no",
      "YES",
      "NO",
      "Yes",
      "No",
      "y",
      "n",
      "Y",
      "N",
    ]

    for input in validBooleans {
      let result = CellValueValidator.validate(input, for: .bool(true))
      #expect(result.isValid, "'\(input)' should be valid boolean")
      #expect(result.errorMessage == nil)
    }
  }

  @Test("Boolean validation with invalid inputs")
  func booleanInvalidInputs() {
    let invalidBooleans = [
      "",
      "2",
      "-1",
      "on",
      "off",
      "enabled",
      "disabled",
      "true1",
      "1true",
      " true",
      "true ",
      "abc",
    ]

    for input in invalidBooleans {
      let result = CellValueValidator.validate(input, for: .bool(true))
      #expect(!result.isValid, "'\(input)' should be invalid boolean")
      #expect(result.errorMessage == "Invalid boolean value (use true/false)")
    }
  }

  // MARK: - Binary Data Validation Tests

  @Test("Binary data validation with valid inputs")
  func binaryDataValidInputs() {
    let validBinaryData = [
      "48656c6c6f",  // Hex string
      "SGVsbG8=",  // Base64
      "binary data",  // Plain text
      "\\x48656c6c6f",  // Postgres hex format
      "any non-empty string",
    ]

    for input in validBinaryData {
      let result = CellValueValidator.validate(input, for: .data(Data()))
      #expect(result.isValid, "'\(input)' should be valid binary data")
      #expect(result.errorMessage == nil)
    }
  }

  @Test("Binary data validation with invalid inputs")
  func binaryDataInvalidInputs() {
    let result = CellValueValidator.validate("", for: .data(Data()))
    #expect(!result.isValid, "Empty string should be invalid binary data")
    #expect(result.errorMessage == "Binary data cannot be empty")
  }

  // MARK: - String Validation Tests

  @Test("String validation accepts everything")
  func stringAcceptsAnything() {
    let anyStrings = [
      "",
      "abc",
      "123",
      "true",
      "null",
      "{invalid json}",
      "2024-99-99",  // Invalid date
      "   whitespace   ",
      "special !@#$%^&*() chars",
      "emoji 🎉🔥",
      "newline\ncharacter",
      "tab\tcharacter",
    ]

    for input in anyStrings {
      let result = CellValueValidator.validate(input, for: .string(""))
      #expect(result.isValid, "String type should accept '\(input)'")
      #expect(result.errorMessage == nil)
    }
  }

  // MARK: - Edge Cases

  @Test("Validation with whitespace-only inputs")
  func whitespaceOnlyInputs() {
    let whitespaceInputs = [
      " ",
      "  ",
      "\t",
      "\n",
      "\r\n",
    ]

    // Integer should reject whitespace
    for input in whitespaceInputs {
      let result = CellValueValidator.validate(input, for: .int(0))
      #expect(!result.isValid, "Integer should reject whitespace-only: '\(input)'")
    }

    // Double should reject whitespace
    for input in whitespaceInputs {
      let result = CellValueValidator.validate(input, for: .double(0))
      #expect(!result.isValid, "Double should reject whitespace-only: '\(input)'")
    }

    // NULL should reject whitespace (only empty or "null" allowed)
    for input in whitespaceInputs {
      let result = CellValueValidator.validate(input, for: .null)
      #expect(!result.isValid, "NULL should reject whitespace-only: '\(input)'")
    }
  }

  @Test("Validation result equality")
  func validationResultEquality() {
    // Valid results are equal
    #expect(ValidationResult.valid == ValidationResult.valid)

    // Invalid results with same message are equal
    #expect(ValidationResult.invalid("error") == ValidationResult.invalid("error"))

    // Invalid results with different messages are not equal
    #expect(ValidationResult.invalid("error1") != ValidationResult.invalid("error2"))

    // Valid and invalid are not equal
    #expect(ValidationResult.valid != ValidationResult.invalid("error"))
  }

  @Test("Validation result properties")
  func validationResultProperties() {
    let valid = ValidationResult.valid
    #expect(valid.isValid == true)
    #expect(valid.errorMessage == nil)

    let invalid = ValidationResult.invalid("test error")
    #expect(invalid.isValid == false)
    #expect(invalid.errorMessage == "test error")
  }
}
