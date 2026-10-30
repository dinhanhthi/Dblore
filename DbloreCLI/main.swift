// main.swift
// The dblore command-line tool, shipped in Dblore.app/Contents/Helpers. Parses the command
// (`CLICommand`), talks to the running app (`CLIClient`), prints data on stdout and everything
// else on stderr, and exits with a `CLIExitCode`. See `CLICommand.helpText` for the contract.

import Foundation

/// The enclosing app's version: the tool runs from Contents/Helpers (a symlink in a PATH folder
/// resolves to it), so Contents/Info.plist is two folders up.
func appVersion() -> String {
  guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return "" }
  let plist = executable.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Info.plist")
  let info = NSDictionary(contentsOf: plist)
  return info?["CFBundleShortVersionString"] as? String ?? ""
}

func printError(_ message: String) {
  FileHandle.standardError.write(Data("dblore: \(CLIOutput.terminalSafe(message))\n".utf8))
}

func printData(_ text: String) {
  FileHandle.standardOutput.write(Data(text.utf8))
}

/// The pairing code typed on the terminal with echo off, or the first line of stdin when stdin
/// is not a terminal (`pbpaste | dblore pair --port N`). Never on argv, so not in `ps`.
func readPairingCode() throws -> String {
  var line: String?
  if isatty(STDIN_FILENO) == 1 {
    var buffer = [CChar](repeating: 0, count: 128)
    if readpassphrase("Pairing code from Dblore: ", &buffer, buffer.count, RPP_REQUIRE_TTY) != nil {
      line = String(
        decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    buffer.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
  } else {
    line = readLine(strippingNewline: true)
  }
  guard let code = line?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
    throw CLIFailure(exitCode: .usage, message: "No pairing code was given.")
  }
  return code
}

/// The statement in `path`, refused past 1 MB
func readStatement(_ path: String) throws -> String {
  let limit = 1_048_576
  guard let handle = FileHandle(forReadingAtPath: path),
    let data = try? handle.read(upToCount: limit + 1)
  else { throw CLIFailure(exitCode: .usage, message: "\(path) cannot be read.") }
  guard data.count <= limit else {
    throw CLIFailure(
      exitCode: .usage, message: "\(path) is over 1 MB; a statement is at most 1 MB.")
  }
  guard let text = String(data: data, encoding: .utf8) else {
    throw CLIFailure(exitCode: .usage, message: "\(path) cannot be read as UTF-8 text.")
  }
  return text
}

/// The saved pairing, with `override` as the port when given
func savedPairing(_ store: CLICredentialStore, override: Int?) throws -> (CLICredentials, Int) {
  guard let loaded = try store.load() else {
    throw CLIFailure(
      exitCode: .refused,
      message: "This tool is not paired with Dblore. In Dblore, open Settings > MCP, start a "
        + "pairing and run the command it shows.")
  }
  if loaded.fixedPermissions {
    printError(
      "\(store.fileURL.path) or its folder was open to other users; it is private again. "
        + "If someone else could have read it, revoke this tool in Dblore (Settings > MCP) and "
        + "pair again.")
  }
  return (loaded.credentials, override ?? loaded.credentials.port)
}

func run(_ command: CLICommand, version: String) async throws {
  let client = CLIClient(
    transport: CLIURLSessionTransport(), userAgent: version.isEmpty ? "dblore" : "dblore/\(version)"
  )
  let store = CLICredentialStore()
  switch command {
  case .help:
    printData(CLICommand.helpText + "\n")
  case .version:
    printData("dblore \(version.isEmpty ? "(version unknown)" : version)\n")
  case .pair(let code, let port):
    let credentials = try await client.pair(code: code ?? readPairingCode(), port: port)
    try store.save(credentials)
    printError("Paired with Dblore on port \(port). Try: dblore connections")
  case .connections(let port):
    let (credentials, port) = try savedPairing(store, override: port)
    let text = try await client.callTool(
      "list_connections", arguments: [:], credentials: credentials, port: port)
    guard let connections = try? CLIOutput.decodeConnections(text) else {
      throw CLIClient.unreadableAnswer
    }
    printData(CLIOutput.renderConnections(connections))
    if connections.isEmpty {
      printError(
        "No connection is available to this tool. In Dblore, allow connections in "
          + "Settings > MCP.")
    }
  case .query(let query):
    let sql: String
    switch query.sql {
    case .text(let text): sql = text
    case .file(let path): sql = try readStatement(path)
    }
    let (credentials, port) = try savedPairing(store, override: query.port)
    var arguments: [String: CLIArgument] = [
      "connection_id": .string(query.connection), "sql": .string(sql),
    ]
    if let maxRows = query.maxRows { arguments["max_rows"] = .int(maxRows) }
    let text = try await client.callTool(
      "run_query", arguments: arguments, credentials: credentials, port: port)
    guard let result = try? CLIOutput.decodeRows(text) else { throw CLIClient.unreadableAnswer }
    printData(
      CLIOutput.render(result, format: query.format, isTerminal: isatty(STDOUT_FILENO) == 1))
    CLIOutput.notes(for: result).forEach(printError)
  }
}

let command: CLICommand
do {
  command = try CLICommand.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
  printError("\(error.message) Run dblore --help for usage.")
  exit(CLIExitCode.usage.rawValue)
}
do {
  try await run(command, version: appVersion())
  exit(CLIExitCode.ok.rawValue)
} catch let failure as CLIFailure {
  printError(failure.message)
  exit(failure.exitCode.rawValue)
} catch {
  printError(error.localizedDescription)
  exit(CLIExitCode.queryFailed.rawValue)
}
