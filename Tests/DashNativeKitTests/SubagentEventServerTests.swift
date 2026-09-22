import Foundation
import Network
import Testing

@testable import DashNativeKit

@MainActor
@Suite("SubagentEventServer")
struct SubagentEventServerTests {
    @Test("Binds to an ephemeral loopback port and round-trips an event over a real socket")
    func roundTripsOverRealSocket() async throws {
        let store = SubagentFeedStore()
        let server = try SubagentEventServer(store: store)
        try await server.start()
        defer { server.stop() }

        let port = try #require(server.port)

        try await post(path: "/subagents/1/c1/begin", body: #"{"agent":"explorer","taskLabel":"Map cache callers"}"#, port: port)
        try await post(path: "/subagents/1/c1/events", body: #"{"type":"tool_execution_end","toolCallId":"1","toolName":"bash","result":{"command":"ls"}}"# + "\n", port: port)
        try await post(path: "/subagents/1/c1/done", body: #"{"exitCode":0,"stopReason":"stop"}"#, port: port)

        try await waitUntil {
            store.runs(forTask: 1).first?.state == .completed
        }

        let run = store.runs(forTask: 1).first
        #expect(run?.agent == "explorer")
        #expect(run?.toolLines == ["$ ls"])
    }

    @Test("Hook responses have an empty body")
    func responsesHaveEmptyBody() async throws {
        let store = SubagentFeedStore()
        let server = try SubagentEventServer(store: store)
        try await server.start()
        defer { server.stop() }
        let port = try #require(server.port)

        let responseBody = try await postAndReadBody(path: "/subagents/1/c1/begin", body: #"{"agent":"x","taskLabel":"y"}"#, port: port)
        #expect(responseBody.isEmpty)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func post(path: String, body: String, port: UInt16) async throws {
        _ = try await postAndReadBody(path: path, body: body, port: port)
    }

    private func postAndReadBody(path: String, body: String, port: UInt16) async throws -> Data {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "test-client")
        connection.start(queue: queue)

        let request = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }

        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
        connection.cancel()

        guard let headerEnd = responseData.range(of: Data("\r\n\r\n".utf8)) else { return Data() }
        return responseData[headerEnd.upperBound...]
    }
}
