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

  @Test(
    "A new value for a NULL cell is checked as the column's type",
    arguments: [
      ("2", "INTEGER", true), ("2.5", "INTEGER", false), ("-3.5", "DOUBLE PRECISION", true),
      ("abc", "NUMERIC", false), ("true", "BOOLEAN", true), ("maybe", "BOOLEAN", false),
      ("{\"a\": 1}", "JSONB", true), ("{bad", "JSON", false), ("hello", "TEXT", true),
      ("anything", "UUID", true), ("null1", "VARCHAR", true), ("-12.50", "numeric(10,2)", true),
      ("1e-07", "NUMERIC", true), ("1e1001", "NUMERIC", false), ("nan", "DECIMAL(65,30)", false),
    ])
  func nullCellTakesColumnType(input: String, columnType: String, isValid: Bool) {
    let result = CellValueValidator.validate(input, for: .null, columnType: columnType)
    #expect(result.isValid == isValid, "'\(input)' as \(columnType)")
  }

  /// Security: decimal text may be written bare into SQL, so only plain decimals and
  /// PostgreSQL's NaN / Infinity / -Infinity pass
  @Test("A decimal takes plain digits with an optional minus and fraction, NaN or Infinity")
  func decimalValidation() {
    for input in [
      "0", "-12.50", "007", "12345678901234567890.123456789", "NaN", "-Infinity", "1e-07",
      "2.5E+3",
    ] {
      #expect(CellValueValidator.validate(input, for: .decimal("1")).isValid, "\(input)")
    }
    for input in [
      "", "1e1001", "1e", "1e5.5", "nan", "inf", " 1", "1 ", "+1", ".5", "1.", "--1", "1;x",
    ] {
      #expect(!CellValueValidator.validate(input, for: .decimal("1")).isValid, "\(input)")
    }
  }

  @Test("A new row's NUMERIC field stages exact decimal text, exponents as plain digits")
  func newRowDecimalField() {
    var field = NewRowField(name: "price", type: "NUMERIC(10,2)")
    field.text = "12.50"
    #expect(field.validationError == nil)
    #expect(field.value(dialect: .postgresql) == .decimal("12.50"))
    field.text = "1e-07"
    #expect(field.validationError == nil)
    #expect(field.value(dialect: .postgresql) == .decimal("0.0000001"))
    field.text = "1e1001"
    #expect(field.validationError != nil)
    var double = NewRowField(name: "ratio", type: "DOUBLE PRECISION")
    double.text = "1e-7"
    #expect(double.validationError == nil)
    #expect(double.value(dialect: .postgresql) == .string("1e-7"))
  }

  @Test("Empty or 'null' keeps a NULL cell NULL whatever the column type")
  func nullCellKeepsNull() {
    for input in ["", "null", "NULL"] {
      #expect(CellValueValidator.validate(input, for: .null, columnType: "INTEGER").isValid)
    }
  }

  @Test("A NULL DATE cell accepts a plain date and still refuses invalid text")
  func nullDateCellTakesPlainDate() {
    #expect(CellValueValidator.validate("2026-10-28", for: .null, columnType: "DATE").isValid)
    for input in ["2026-13-01", "2026-02-30", "28/10/2026", "2026-10-28 extra"] {
      let result = CellValueValidator.validate(input, for: .null, columnType: "DATE")
      #expect(!result.isValid, "'\(input)' should be refused")
    }
    #expect(!CellValueValidator.validate("", for: .date(Date())).isValid)
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

  /// 2026-10-15 12:00:00 UTC plus `micros`, built as the parser builds an instant
  private static func noon(micros: Int64 = 0) -> Date {
    Date(timeIntervalSince1970: Double(1_792_065_600 * 1_000_000 + micros) / 1_000_000)
  }

  /// Regression A5: the editor shows `displayString(wallClock:)` and must read it back as the
  /// same instant, whatever the zone the app shows dates in
  @Test(
    "Displayed timestamp text parses back to the same value under any zone",
    arguments: ["UTC", "Asia/Ho_Chi_Minh", "America/St_Johns", "America/Los_Angeles"])
  func displayedTimestampRoundTrips(zone: String) {
    CellValue.$displayZone.withValue(TimeZone(identifier: zone)!) {
      for date in [Self.noon(), Self.noon(micros: 123_456), Self.noon(micros: 500)] {
        for wallClock in [true, false] {
          let text = CellValue.date(date).displayString(wallClock: wallClock)
          #expect(CellValueValidator.validate(text, for: .date(date)).isValid, "\(text)")
          #expect(
            NotebookViewModel.editedCellValue(text, original: .date(date), wallClock: wallClock)
              == .date(date), "\(text) in \(zone)")
        }
      }
    }
  }

  @Test("Zoned text reads its offset or Z, and no zone as the display zone; naive text as UTC")
  func timestampZones() {
    CellValue.$displayZone.withValue(TimeZone(identifier: "Asia/Ho_Chi_Minh")!) {
      let noon = CellValue.date(Self.noon())
      let cases: [(String, Bool)] = [
        ("2026-10-15 09:30:00-02:30", false), ("2026-10-15 19:00:00+0700", false),
        ("2026-10-15 19:00:00+07", false), ("2026-10-15 12:00:00Z", false),
        ("2026-10-15T12:00:00Z", false), ("2026-10-15 19:00:00", false),
        ("2026-10-15 12:00:00", true),
      ]
      for (text, wallClock) in cases {
        #expect(CellValueValidator.validate(text, for: noon).isValid, "\(text)")
        #expect(
          NotebookViewModel.editedCellValue(text, original: noon, wallClock: wallClock) == noon,
          "\(text)")
      }
      #expect(!CellValueValidator.validate("2026-10-15 12:00:00.1234567", for: noon).isValid)
    }
  }

  /// Regression A5: PostgreSQL decodes a timestamp as seconds since 2000-01-01, a Double that
  /// differs from the parser's for many microseconds; the value's own text is that value
  @Test("A PostgreSQL-decoded timestamp read from its own text is the stored value")
  func postgresDecodedTimestampReadsAsItself() {
    let since2000 = Date(timeIntervalSince1970: 946_684_800)
    CellValue.$displayZone.withValue(TimeZone(identifier: "Asia/Ho_Chi_Minh")!) {
      var differs = false
      for micros: Int64 in [2, 3, 7, 123_456, 999_999] {
        // The decode formula of the PostgreSQL driver
        let decoded = Date(
          timeInterval: Double(845_380_800_000_000 + micros) / 1_000_000, since: since2000)
        differs = differs || decoded != Self.noon(micros: micros)
        for wallClock in [true, false] {
          let text = CellValue.date(decoded).displayString(wallClock: wallClock)
          #expect(
            NotebookViewModel.editedCellValue(text, original: .date(decoded), wallClock: wallClock)
              == .date(decoded), "\(text)")
        }
      }
      #expect(differs)
    }
  }

  /// Regression A5: a wall clock the zone skips (spring forward) is no time at all
  @Test("A zone-less zoned time in a DST gap is refused; naive text is not")
  func dstGapRefused() {
    CellValue.$displayZone.withValue(TimeZone(identifier: "America/Los_Angeles")!) {
      let text = "2026-03-08 02:30:00"
      #expect(CellValueValidator.date(from: text, wallClock: false) == nil)
      #expect(!CellValueValidator.validate(text, for: .date(Self.noon())).isValid)
      #expect(CellValueValidator.date(from: text, wallClock: true) != nil)
      // A naive column has no gap: every new-row path accepts its wall clock
      #expect(CellValueValidator.validate(text, for: .date(Self.noon()), wallClock: true).isValid)
      #expect(
        CellValueValidator.validate(text, for: .null, columnType: "TIMESTAMP", wallClock: true)
          .isValid)
      var field = NewRowField(name: "at", type: "TIMESTAMP", wallClock: true)
      field.text = text
      #expect(field.validationError == nil)
      field = NewRowField(name: "at", type: "TIMESTAMPTZ")
      field.text = text
      #expect(field.validationError != nil)
      #expect(
        (try? PastedRows.cellValue(
          .init(text: text, quoted: true), columnType: "TIMESTAMP", wallClock: true,
          dialect: .postgresql)) != nil)
      // The repeated hour of fall back keeps its wall clock: accepted
      #expect(CellValueValidator.date(from: "2026-11-01 01:30:00", wallClock: false) != nil)
    }
  }

  /// Regression A5 (round 5): the common minute-only form reads with zero seconds
  @Test("A minute-only time reads with zero seconds; a fraction needs seconds")
  func minuteOnlyTime() {
    CellValue.$displayZone.withValue(TimeZone(identifier: "Asia/Ho_Chi_Minh")!) {
      let noon = Date(timeIntervalSince1970: 1_792_065_600)
      #expect(CellValueValidator.date(from: "2026-10-15 19:00", wallClock: false) == noon)
      #expect(CellValueValidator.date(from: "2026-10-15T19:00+07:00", wallClock: false) == noon)
      #expect(CellValueValidator.date(from: "2026-10-15 12:00Z", wallClock: false) == noon)
      #expect(CellValueValidator.date(from: "2026-10-15 12:00", wallClock: true) == noon)
      #expect(CellValueValidator.validate("2026-10-15 19:00", for: .date(noon)).isValid)
      #expect(CellValueValidator.date(from: "2026-10-15 19:00.5", wallClock: false) == nil)
      #expect(!CellValueValidator.validate("2026-10-15 19:00.5", for: .date(noon)).isValid)
    }
  }

  @Test("Digits other than ASCII 0-9 are refused in a timestamp")
  func nonASCIIDigitsRefused() {
    for text in [
      "2026-10-15 12:00:00.\u{0661}\u{0662}", "2026-10-15 12:00:00+\u{0660}\u{0667}:00",
      "\u{0662}026-10-15 12:00:00", "2026-10-15 12:00:00+\u{FF10}\u{FF17}",
    ] {
      #expect(CellValueValidator.date(from: text, wallClock: true) == nil, "\(text)")
    }
  }

  /// Regression A5: text typed for a date with no stored value reads as a stored value's text
  /// does (zone-less zoned text in the display zone), except on SQLite, whose dates are text
  @Test(
    "New zoned date text reads in the display zone; SQLite keeps it as typed",
    arguments: [SQLDialect.postgresql, .mysql, .duckdb, .sqlite])
  func newZonedDateText(dialect: SQLDialect) {
    CellValue.$displayZone.withValue(TimeZone(identifier: "Asia/Ho_Chi_Minh")!) {
      let text = "2026-10-15 19:00:00"
      let expected: CellValue = dialect == .sqlite ? .string(text) : .date(Self.noon())
      #expect(
        NotebookViewModel.editedNewDate(
          text, columnType: "TIMESTAMPTZ", wallClock: false, dialect: dialect) == expected)
      #expect(
        NotebookViewModel.editedCellValue(
          text, original: .null, columnType: "TIMESTAMPTZ", dialect: dialect) == expected)
      #expect(
        (try? PastedRows.cellValue(
          .init(text: text, quoted: true), columnType: "TIMESTAMPTZ", dialect: dialect))
          == expected)
      // A naive column reads its wall clock as UTC; a DATE stays text
      #expect(
        NotebookViewModel.editedNewDate(
          "2026-10-15 12:00:00", columnType: "TIMESTAMP", wallClock: true, dialect: dialect)
          == (dialect == .sqlite ? .string("2026-10-15 12:00:00") : .date(Self.noon())))
      #expect(
        NotebookViewModel.editedNewDate(
          "2026-10-15", columnType: "DATE", wallClock: false, dialect: dialect)
          == .string("2026-10-15"))
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
      #expect(
        result.errorMessage
          == "Invalid date format (use yyyy-MM-dd, yyyy-MM-dd HH:mm:ss or ISO8601)")
    }
  }

  @Test("Date validation with invalid date formats")
  func dateInvalidFormats() {
    let invalidDates = [
      ("", "Date cannot be empty"),
      ("14:15:00", "Invalid date format (use yyyy-MM-dd, yyyy-MM-dd HH:mm:ss or ISO8601)"),  // Only time
      // Wrong separator
      (
        "2024/02/20 14:15:00",
        "Invalid date format (use yyyy-MM-dd, yyyy-MM-dd HH:mm:ss or ISO8601)"
      ),
      // Wrong order
      (
        "20-02-2024 14:15:00",
        "Invalid date format (use yyyy-MM-dd, yyyy-MM-dd HH:mm:ss or ISO8601)"
      ),
      ("Feb 20, 2024", "Invalid date format (use yyyy-MM-dd, yyyy-MM-dd HH:mm:ss or ISO8601)"),
      // Invalid month
      (
        "2024-13-01 00:00:00",
        "Invalid date format (use yyyy-MM-dd, yyyy-MM-dd HH:mm:ss or ISO8601)"
      ),
      // Invalid day
      (
        "2024-02-30 14:15:00",
        "Invalid date format (use yyyy-MM-dd, yyyy-MM-dd HH:mm:ss or ISO8601)"
      ),
      ("abc", "Invalid date format (use yyyy-MM-dd, yyyy-MM-dd HH:mm:ss or ISO8601)"),
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

  @Test("Binary data validation with invalid inputs")
  func binaryDataInvalidInputs() {
    let result = CellValueValidator.validate("", for: .data(Data()))
    #expect(!result.isValid, "Empty string should be invalid binary data")
    #expect(result.errorMessage == "Binary data cannot be empty")
    #expect(!CellValueValidator.validate("not base64!", for: .data(Data())).isValid)
    #expect(CellValueValidator.validate("3q2+7w==", for: .data(Data())).isValid)
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

    // A NULL integer cell should reject whitespace (checked as the column's type)
    for input in whitespaceInputs {
      let result = CellValueValidator.validate(input, for: .null, columnType: "INTEGER")
      #expect(!result.isValid, "NULL integer should reject whitespace-only: '\(input)'")
    }
  }

}
