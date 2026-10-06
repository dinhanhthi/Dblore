// DropdownTitleTests.swift
// Dropdown and menu titles stay on one line when the source string has a line break.

import Testing

@testable import Dblore

@Suite("Dropdown title")
struct DropdownTitleTests {
  @Test("A string with no line break is unchanged")
  func unchanged() {
    #expect(DropdownTitle.singleLine("docker ps): dblore") == "docker ps): dblore")
  }

  @Test("A line feed becomes a space")
  func lineFeed() {
    #expect(DropdownTitle.singleLine("a\nb") == "a b")
  }

  @Test("A carriage return and line feed become one space")
  func carriageReturnLineFeed() {
    #expect(DropdownTitle.singleLine("a\r\nb") == "a b")
  }

  @Test("A carriage return becomes a space")
  func carriageReturn() {
    #expect(DropdownTitle.singleLine("a\rb") == "a b")
  }

  @Test("A connection name with a line break stays one line")
  func connectionName() {
    #expect(
      DropdownTitle.singleLine("docker ps):\ndblore-postgres-test")
        == "docker ps): dblore-postgres-test")
  }

  @Test("A Unicode line separator becomes a space")
  func unicodeLineSeparator() {
    #expect(
      DropdownTitle.singleLine("docker ps):\u{2028}dblore-postgres-test")
        == "docker ps): dblore-postgres-test")
  }

  @Test("A run of line breaks becomes one space")
  func lineBreakRun() {
    #expect(
      DropdownTitle.singleLine("dblore-postgres-test\n\n\n\n\n\ndblore-postgres-test")
        == "dblore-postgres-test dblore-postgres-test")
  }
}
