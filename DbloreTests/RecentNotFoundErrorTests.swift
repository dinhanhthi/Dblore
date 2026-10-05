// RecentNotFoundErrorTests.swift
// Cocoa errors that mean a workspace file is gone

import Foundation
import Testing

@testable import Dblore

@Suite("RecentNotFoundErrorTests")
struct RecentNotFoundErrorTests {

  @Test("NSCocoaErrorDomain 4 is a missing file")
  func fileNoSuchFileIsNotFound() {
    let error = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
    #expect(RecentManager.isFileNotFound(error))
  }

  @Test("NSCocoaErrorDomain 260 is a missing file")
  func fileReadNoSuchFileIsNotFound() {
    let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
    #expect(RecentManager.isFileNotFound(error))
  }

  @Test("NSCocoaErrorDomain 259 is not a missing file")
  func fileReadCorruptFileIsNotNotFound() {
    let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError)
    #expect(!RecentManager.isFileNotFound(error))
  }

  @Test("The same code outside NSCocoaErrorDomain is not a missing file")
  func nonCocoaDomainIsNotNotFound() {
    let error = NSError(domain: "TestDomain", code: NSFileReadNoSuchFileError)
    #expect(!RecentManager.isFileNotFound(error))
  }
}
