// DropdownTitleTests.swift
// Dropdown and menu titles stay on one line when the source string has a line break.

import Testing

@testable import Dblore

@Suite("Dropdown title")
struct DropdownTitleTests {
  @Test("A connection name with a line break stays one line")
  func connectionName() {
    #expect(
      DropdownTitle.singleLine("docker ps):\ndblore-postgres-test")
        == "docker ps): dblore-postgres-test")
  }

}
