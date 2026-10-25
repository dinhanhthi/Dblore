// PluginLoaderBundleTests.swift
// Plugin bundle checks: verifyBundle returns the executable only for a bundle signed by the pinned
// Team ID with the pinned cdhash and intact resources.

import Darwin
import Foundation
import Testing

@testable import Dblore

@Suite(.serialized) struct PluginLoaderBundleTests {
  private static let teamID = PluginLoader.teamIdentifier
  private static let wrongCDHash = String(repeating: "0", count: 40)

  private struct TestFailure: Error, CustomStringConvertible { let description: String }

  private static func tempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("plugin-bundle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  // MARK: - Refused bundles (no plugin needed)

  @Test func unsignedBundleIsRefused() throws {
    let dir = try Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let bundle = dir.appendingPathComponent("X.bundle", isDirectory: true)
    let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let plist: [String: Any] = [
      "CFBundleExecutable": "X", "CFBundleIdentifier": "ace.thi.Dblore.test.X",
      "CFBundlePackageType": "BNDL",
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    let executable = macOS.appendingPathComponent("X")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    #expect(throws: PluginLoaderError.teamIDMismatch(expected: Self.teamID, actual: nil)) {
      _ = try PluginLoader.verifyBundle(
        at: bundle, expectedTeamID: Self.teamID, expectedCDHash: Self.wrongCDHash)
    }
  }

  @Test func appleSignedBundleWithoutTeamIsRefused() throws {
    let app = URL(fileURLWithPath: "/System/Applications/Calculator.app", isDirectory: true)
    #expect {
      _ = try PluginLoader.verifyBundle(
        at: app, expectedTeamID: Self.teamID, expectedCDHash: Self.wrongCDHash)
    } throws: { error in
      guard case PluginLoaderError.teamIDMismatch(let expected, let actual) = error else {
        return false
      }
      return expected == Self.teamID && actual != Self.teamID
    }
  }

  // MARK: - Gated: the dev plugin in .plugin-dev/local-ai/

  private struct DevCatalog: Decodable {
    let cdhash: String
    let bundleName: String
    let notarized: Bool
  }

  private static let pluginDev = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent(".plugin-dev/local-ai", isDirectory: true)

  private static func devCatalog() throws -> DevCatalog {
    let data = try Data(contentsOf: pluginDev.appendingPathComponent("dev-catalog.json"))
    let catalog = try JSONDecoder().decode(DevCatalog.self, from: data)
    // A non-notarized bundle is never loaded: Gatekeeper would refuse it.
    guard catalog.notarized else { throw TestFailure(description: "dev plugin not notarized") }
    return catalog
  }

  /// Unpacks `zipName` from .plugin-dev/local-ai/ into `dir` with ditto and returns the bundle.
  /// Prints (does not assert) whether the unpacked files carry com.apple.quarantine.
  private static func unpack(_ zipName: String, into dir: URL, bundleName: String) throws -> URL {
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-x", "-k", pluginDev.appendingPathComponent(zipName).path, dir.path]
    try ditto.run()
    ditto.waitUntilExit()
    guard ditto.terminationStatus == 0 else {
      throw TestFailure(description: "ditto exited \(ditto.terminationStatus) for \(zipName)")
    }
    let bundle = dir.appendingPathComponent(bundleName, isDirectory: true)
    let executable = bundle.appendingPathComponent("Contents/MacOS/DbloreLocalAI")
    print(
      "PluginLoaderBundleTests quarantine after unpacking \(zipName): bundle \(quarantine(of: bundle)), executable \(quarantine(of: executable))"
    )
    return bundle
  }

  private static func quarantine(of url: URL) -> String {
    var buffer = [UInt8](repeating: 0, count: 256)
    let length = getxattr(url.path, "com.apple.quarantine", &buffer, buffer.count, 0, 0)
    if length < 0 {
      let code = errno
      return code == ENOATTR ? "absent" : "getxattr failed: \(String(cString: strerror(code)))"
    }
    return "present (\(String(decoding: buffer[..<length], as: UTF8.self)))"
  }

  @Test(.requiresLocalAIPlugin)
  func notarizedBundleIsAccepted() throws {
    let catalog = try Self.devCatalog()
    let dir = try Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let bundle = try Self.unpack("DbloreLocalAI.zip", into: dir, bundleName: catalog.bundleName)
    let executable = try PluginLoader.verifyBundle(
      at: bundle, expectedTeamID: Self.teamID, expectedCDHash: catalog.cdhash)
    #expect(
      executable.resolvingSymlinksInPath().path
        == bundle.appendingPathComponent("Contents/MacOS/DbloreLocalAI")
        .resolvingSymlinksInPath().path)
  }

  @Test(.requiresLocalAIPlugin)
  func adHocTamperedSymlinkedAndMispinnedBundlesAreRefused() throws {
    let catalog = try Self.devCatalog()
    let dir = try Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let notarized = try Self.unpack(
      "DbloreLocalAI.zip", into: dir.appendingPathComponent("notarized"),
      bundleName: catalog.bundleName)
    let adHoc = try Self.unpack(
      "DbloreLocalAI-adhoc.zip", into: dir.appendingPathComponent("adhoc"),
      bundleName: catalog.bundleName)
    let tampered = dir.appendingPathComponent("tampered/\(catalog.bundleName)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: tampered.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: notarized, to: tampered)
    let resource = try FileHandle(
      forUpdating: tampered.appendingPathComponent(
        "Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"))
    let first = try #require(try resource.read(upToCount: 1)?.first)
    try resource.seek(toOffset: 0)
    try resource.write(contentsOf: Data([~first]))
    try resource.close()
    let link = dir.appendingPathComponent("link.bundle")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: notarized)

    #expect(throws: PluginLoaderError.teamIDMismatch(expected: Self.teamID, actual: nil)) {
      _ = try PluginLoader.verifyBundle(
        at: adHoc, expectedTeamID: Self.teamID, expectedCDHash: catalog.cdhash)
    }
    #expect(throws: PluginLoaderError.integrityMismatch) {
      _ = try PluginLoader.verifyBundle(
        at: tampered, expectedTeamID: Self.teamID, expectedCDHash: catalog.cdhash)
    }
    #expect(throws: PluginLoaderError.integrityMismatch) {
      _ = try PluginLoader.verifyBundle(
        at: notarized, expectedTeamID: Self.teamID, expectedCDHash: Self.wrongCDHash)
    }
    #expect(
      throws: PluginLoaderError.teamIDMismatch(expected: "ABCDE12345", actual: Self.teamID)
    ) {
      _ = try PluginLoader.verifyBundle(
        at: notarized, expectedTeamID: "ABCDE12345", expectedCDHash: catalog.cdhash)
    }
    // A quote in the pin must not reach the code requirement string.
    #expect(throws: PluginLoaderError.integrityMismatch) {
      _ = try PluginLoader.verifyBundle(
        at: notarized, expectedTeamID: Self.teamID,
        expectedCDHash: String(repeating: "0", count: 39) + "\"")
    }
    #expect(throws: PluginLoaderError.loadFailed("\(link.path): not a directory")) {
      _ = try PluginLoader.verifyBundle(
        at: link, expectedTeamID: Self.teamID, expectedCDHash: catalog.cdhash)
    }
  }
}
