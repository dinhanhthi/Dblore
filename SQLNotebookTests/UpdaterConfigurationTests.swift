//
//  UpdaterConfigurationTests.swift
//  SQLNotebookTests
//

import Foundation
import Testing

struct UpdaterConfigurationTests {

  private let info = Bundle.main.infoDictionary ?? [:]

  @Test("SUFeedURL points to the GitHub Pages appcast over https")
  func testFeedURL() throws {
    let raw = try #require(info["SUFeedURL"] as? String)
    let url = try #require(URL(string: raw))
    #expect(url.scheme == "https")
    #expect(url.host == "dinhanhthi.github.io")
    #expect(url.path == "/SQLNotebook/appcast.xml")
  }

  @Test("SUPublicEDKey is a base64 Ed25519 public key")
  func testPublicEDKey() throws {
    let raw = try #require(info["SUPublicEDKey"] as? String)
    let data = try #require(Data(base64Encoded: raw))
    #expect(data.count == 32)
  }

  @Test("Installer launcher service is enabled for the sandbox")
  func testInstallerLauncherServiceEnabled() {
    #expect(info["SUEnableInstallerLauncherService"] as? Bool == true)
  }

  @Test("Automatic update checks are enabled")
  func testAutomaticChecksEnabled() {
    #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
  }
}
