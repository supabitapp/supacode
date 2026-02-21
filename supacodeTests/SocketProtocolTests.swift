import Foundation
import Testing

@testable import supacode

struct SocketProtocolTests {
  @Test func requestRoundTripsWithNestedValues() throws {
    let request = SocketRequest(
      id: "abc123",
      method: "tab.create",
      params: [
        "worktree_id": .string("/tmp/repo/wt-1"),
        "retries": .int(2),
        "enabled": .bool(true),
        "meta": .object([
          "labels": .array([
            .string("agent"),
            .string("socket"),
          ]),
          "extra": .null,
        ]),
      ]
    )

    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(SocketRequest.self, from: data)

    #expect(decoded == request)
  }

  @Test func successResponseRoundTrips() throws {
    let response = SocketResponse.success(
      id: "42",
      result: .object([
        "tab_id": .string("11111111-2222-3333-4444-555555555555"),
        "did_close": .bool(false),
      ])
    )

    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(SocketResponse.self, from: data)

    #expect(decoded == response)
  }

  @Test func errorResponseRoundTrips() throws {
    let response = SocketResponse.failure(
      id: "43",
      code: .invalidParams,
      message: "Missing required param: worktree_id"
    )

    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(SocketResponse.self, from: data)

    #expect(decoded == response)
  }
}
