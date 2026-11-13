// RedisBrakesTests.swift
// The brakes of a Redis connection, without a server: what the `settings` request keeps and
// refuses, and the commands of the second connection that stops a busy script.

import Foundation
import Testing

private func settings(statement: Int, lock: Int = 0, idle: Int = 0) -> EngineRequest.Settings {
  EngineRequest.Settings(
    statementTimeoutSeconds: statement, lockTimeoutSeconds: lock, idleTimeoutSeconds: idle)
}

struct RedisBrakesTests {
  @Test("The statement timeout is kept, 0 or less turns it off, nothing is refused")
  func keepsStatementTimeout() {
    for (asked, kept) in [(2, 2), (0, 0), (-5, 0)] {
      let (seconds, refusal) = RedisBrakes.apply(settings(statement: asked))
      #expect(seconds == kept)
      #expect(refusal == nil)
    }
  }

  @Test(
    "A lock or idle timeout is refused as unsupported, with the statement timeout still kept",
    arguments: [(5, 0), (0, 30), (5, 30)])
  func refusesLockAndIdle(lock: Int, idle: Int) {
    let (seconds, refusal) = RedisBrakes.apply(settings(statement: 2, lock: lock, idle: idle))
    #expect(seconds == 2)
    #expect(refusal?.code == .unsupported)
  }

  @Test("The timeout failure is a query error naming the timeout")
  func timeoutFailure() {
    let failure = RedisBrakes.timeoutFailure(seconds: 2)
    #expect(failure.code == .query)
    #expect(failure.message == "The command was stopped by the 2 s statement timeout.")
    #expect(failure.serverCode == nil)
  }

  @Test("RESP3: HELLO 3 AUTH with the user (default when unset), then the two kills")
  func killCommandsRESP3() {
    #expect(
      RedisBrakes.killCommands(username: "qa_user", password: "pw", protocolVersion: 3) == [
        ["HELLO", "3", "AUTH", "qa_user", "pw"], ["SCRIPT", "KILL"], ["FUNCTION", "KILL"],
      ])
    #expect(
      RedisBrakes.killCommands(username: "", password: "pw", protocolVersion: 3) == [
        ["HELLO", "3", "AUTH", "default", "pw"], ["SCRIPT", "KILL"], ["FUNCTION", "KILL"],
      ])
  }

  @Test("RESP2: AUTH [user] password, then the two kills")
  func killCommandsRESP2() {
    #expect(
      RedisBrakes.killCommands(username: "qa_user", password: "pw", protocolVersion: 2) == [
        ["AUTH", "qa_user", "pw"], ["SCRIPT", "KILL"], ["FUNCTION", "KILL"],
      ])
    #expect(
      RedisBrakes.killCommands(username: "", password: "pw", protocolVersion: 2) == [
        ["AUTH", "pw"], ["SCRIPT", "KILL"], ["FUNCTION", "KILL"],
      ])
    // A user without a password still authenticates as itself
    #expect(
      RedisBrakes.killCommands(username: "nopass_user", password: "", protocolVersion: 2) == [
        ["AUTH", "nopass_user", ""], ["SCRIPT", "KILL"], ["FUNCTION", "KILL"],
      ])
  }

  @Test("Without a user or a password only the two kills go, in either protocol")
  func killCommandsWithoutCredentials() {
    for version in [2, 3] {
      #expect(
        RedisBrakes.killCommands(username: "", password: "", protocolVersion: version) == [
          ["SCRIPT", "KILL"], ["FUNCTION", "KILL"],
        ])
    }
  }

  @Test("The kill connection never sends SELECT or INFO (a busy server answers BUSY to them)")
  func killCommandsNeverSelectOrInfo() {
    for version in [2, 3] {
      for (user, password) in [("u", "p"), ("", "p"), ("u", ""), ("", "")] {
        let names = RedisBrakes.killCommands(
          username: user, password: password, protocolVersion: version
        ).map { $0[0].uppercased() }
        #expect(!names.contains("SELECT"))
        #expect(!names.contains("INFO"))
        #expect(names.suffix(2) == ["SCRIPT", "FUNCTION"])
      }
    }
  }
}
