import Foundation
import Testing

@testable import Dblore

struct OAuthLoopbackServerTests {
  private func get(_ port: Int, _ path: String) async throws -> Int {
    let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
    let (_, response) = try await URLSession.shared.data(from: url)
    return (response as? HTTPURLResponse)?.statusCode ?? 0
  }

  @Test func returnsCodeAndIgnoresOtherPaths() async throws {
    let server = OAuthLoopbackServer(ports: [0])
    let port = try await server.start()
    async let code = server.waitForCallback(expectedState: "s1", timeout: 10)
    #expect(try await get(port, "/nope") == 404)
    #expect(try await get(port, "/auth/callback?code=x&state=bad") == 400)
    #expect(try await get(port, "/auth/callback?code=abc&state=s1") == 200)
    #expect(try await code == "abc")
  }

  @Test func cancellationFreesWait() async throws {
    let server = OAuthLoopbackServer(ports: [0])
    _ = try await server.start()
    let task = Task { try await server.waitForCallback(expectedState: "s", timeout: 30) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
  }
}
