// ConnectionImportSheetTests.swift
// Unit tests for the import sheet's per-source picker rules and footer text.

import Foundation
import Testing

@testable import Dblore

@Suite("Connection import sheet")
struct ConnectionImportSheetTests {

  @Test("DBeaver and DataGrip pick folders, .pgpass and TablePlus pick files, URI is typed")
  func pickerKinds() {
    #expect(ImportSource.uri.picker == .textOnly)
    #expect(ImportSource.pgpass.picker == .file)
    #expect(ImportSource.tablePlus.picker == .file)
    #expect(ImportSource.dbeaver.picker == .folder)
    #expect(ImportSource.dataGrip.picker == .folder)
  }

  @Test("Only URI and .pgpass accept pasted text")
  func acceptsText() {
    #expect(ImportSource.sheetOrder.filter(\.acceptsText) == [.uri, .pgpass])
  }

  @Test("Footer counts selected rows and free slots")
  func footer() {
    #expect(ConnectionImportText.footer(selected: 1, freeSlots: 1) == "1 selected · 1 free slot")
    #expect(ConnectionImportText.footer(selected: 3, freeSlots: 47) == "3 selected · 47 free slots")
  }

  @Test("Badges: password state, SSH, missing key, duplicate reason")
  func badges() {
    let plain = ImportRow(
      id: 0, name: "a", address: "h:5432/d", user: "u", engine: "PostgreSQL", hasPassword: false,
      hasSSH: false, sshNeedsKey: false, duplicateReason: nil, warnings: [], isSelected: true)
    #expect(ConnectionImportText.badges(for: plain) == [.noPassword])
    let full = ImportRow(
      id: 1, name: "b", address: "h:5432/d", user: "u", engine: "PostgreSQL", hasPassword: true,
      hasSSH: true, sshNeedsKey: true, duplicateReason: .alreadySaved, warnings: [],
      isSelected: false)
    #expect(
      ConnectionImportText.badges(for: full) == [.password, .ssh, .sshKeyNeeded, .alreadySaved])
    let repeated = ImportRow(
      id: 2, name: "c", address: "h:5432/d", user: "u", engine: "PostgreSQL", hasPassword: false,
      hasSSH: false, sshNeedsKey: false, duplicateReason: .duplicateInFile, warnings: [],
      isSelected: false)
    #expect(ConnectionImportText.badges(for: repeated) == [.noPassword, .duplicateInFile])
    #expect(ImportBadge.duplicateInFile.title == "Duplicate in file")
  }

  @Test("Over-limit warning names the free slots")
  func overLimit() {
    #expect(
      ConnectionImportText.overLimit(freeSlots: 2)
        == "Only 2 more connections can be saved; the rest will be skipped.")
    #expect(
      ConnectionImportText.overLimit(freeSlots: 0)
        == "No more connections can be saved; the selected ones will be skipped.")
  }
}
