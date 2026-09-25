import Foundation
import Network
import Testing

@testable import BSideKit

@MainActor
@Suite("SubagentEventServer")
struct SubagentEventServerTests {
    @Test("Binds to an ephemeral loopback port and round-trips an event over a real socket")
    func roundTripsOverRealSocket() async throws {
        let store = SubagentFeedStore()
        let server = try SubagentEventServer(store: store, paneStore: SubagentPaneStore(), taskExists: { _ in true })
        try await server.start()
        defer { server.stop() }

        let port = try #require(server.port)

        try await post(path: "/subagents/1/c1/begin", body: #"{"agent":"explorer","taskLabel":"Map cache callers"}"#, port: port)
        let messageEndLine = #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"toolCall","id":"1","name":"bash","arguments":{"command":"ls"}}]}}"#
        try await post(path: "/subagents/1/c1/events", body: messageEndLine + "\n", port: port)
        try await post(path: "/subagents/1/c1/events", body: #"{"type":"tool_execution_end","toolCallId":"1","toolName":"bash"}"# + "\n", port: port)
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
        let server = try SubagentEventServer(store: store, paneStore: SubagentPaneStore(), taskExists: { _ in true })
        try await server.start()
        defer { server.stop() }
        let port = try #require(server.port)

        let responseBody = try await postAndReadBody(path: "/subagents/1/c1/begin", body: #"{"agent":"x","taskLabel":"y"}"#, port: port)
        #expect(responseBody.isEmpty)
    }

    private func fakeHostFactory(cwd: URL, command: String, onExit: @escaping (Bool) -> Void) -> TerminalSurfaceHost {
        TerminalSurfaceHost.makeInMemoryForTesting()
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("subagent-server-spawn-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Spawn creates a pane and returns 204 for a known task")
    func spawnCreatesPaneAndReturns204() async throws {
        let store = SubagentFeedStore()
        let paneStore = SubagentPaneStore(makeHost: fakeHostFactory)
        let server = try SubagentEventServer(store: store, paneStore: paneStore, taskExists: { _ in true })
        try await server.start()
        defer { server.stop() }
        let port = try #require(server.port)

        let body = #"{"label":"explorer: map callers","cwd":"\#(tempDir().path)","command":"/bin/sh"}"#
        let status = try await postAndReadStatus(path: "/subagents/1/c1/spawn", body: body, port: port)

        #expect(status == 204)
        try await waitUntil { paneStore.panes(forTask: 1).map(\.id) == ["c1"] }
    }

    @Test("Spawn for an unknown task returns 404 and registers no pane")
    func spawnUnknownTaskReturns404() async throws {
        let store = SubagentFeedStore()
        let paneStore = SubagentPaneStore(makeHost: fakeHostFactory)
        let server = try SubagentEventServer(store: store, paneStore: paneStore, taskExists: { _ in false })
        try await server.start()
        defer { server.stop() }
        let port = try #require(server.port)

        let body = #"{"label":"explorer","cwd":"\#(tempDir().path)","command":"/bin/sh"}"#
        let status = try await postAndReadStatus(path: "/subagents/1/c1/spawn", body: body, port: port)

        #expect(status == 404)
        #expect(paneStore.panes(forTask: 1).isEmpty)
    }

    @Test("Spawn past the pane cap returns 429")
    func spawnOverCapReturns429() async throws {
        let store = SubagentFeedStore()
        let paneStore = SubagentPaneStore(makeHost: fakeHostFactory)
        for index in 0..<SubagentPaneStore.maxPanesPerTask {
            paneStore.spawn(taskId: 1, childId: "existing\(index)", label: "x", cwd: tempDir(), command: "/bin/sh")
        }
        let server = try SubagentEventServer(store: store, paneStore: paneStore, taskExists: { _ in true })
        try await server.start()
        defer { server.stop() }
        let port = try #require(server.port)

        let body = #"{"label":"one too many","cwd":"\#(tempDir().path)","command":"/bin/sh"}"#
        let status = try await postAndReadStatus(path: "/subagents/1/over-cap/spawn", body: body, port: port)

        #expect(status == 429)
        #expect(!paneStore.panes(forTask: 1).contains { $0.id == "over-cap" })
    }

    @Test("Spawn with a malformed body returns 400")
    func spawnMalformedBodyReturns400() async throws {
        let store = SubagentFeedStore()
        let paneStore = SubagentPaneStore(makeHost: fakeHostFactory)
        let server = try SubagentEventServer(store: store, paneStore: paneStore, taskExists: { _ in true })
        try await server.start()
        defer { server.stop() }
        let port = try #require(server.port)

        let status = try await postAndReadStatus(path: "/subagents/1/c1/spawn", body: #"{"label":"missing fields"}"#, port: port)

        #expect(status == 400)
        #expect(paneStore.panes(forTask: 1).isEmpty)
    }

    @Test("Close always returns 204, including for a pane that was never spawned")
    func closeIsIdempotent() async throws {
        let store = SubagentFeedStore()
        let paneStore = SubagentPaneStore()
        paneStore.spawn(taskId: 1, childId: "c1", label: "x", cwd: tempDir(), command: "/bin/sh")
        let server = try SubagentEventServer(store: store, paneStore: paneStore, taskExists: { _ in true })
        try await server.start()
        defer { server.stop() }
        let port = try #require(server.port)

        let firstClose = try await postAndReadStatus(path: "/subagents/1/c1/close", body: "", port: port)
        #expect(firstClose == 204)
        try await waitUntil { paneStore.panes(forTask: 1).isEmpty }

        let secondClose = try await postAndReadStatus(path: "/subagents/1/c1/close", body: "", port: port)
        #expect(secondClose == 204)

        let neverSpawnedClose = try await postAndReadStatus(path: "/subagents/1/never-spawned/close", body: "", port: port)
        #expect(neverSpawnedClose == 204)
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

    private func postAndReadStatus(path: String, body: String, port: UInt16) async throws -> Int {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "test-client-status")
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

        guard let text = String(data: responseData, encoding: .utf8),
              let statusLine = text.components(separatedBy: "\r\n").first
        else { return -1 }
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let status = Int(parts[1]) else { return -1 }
        return status
    }
}
