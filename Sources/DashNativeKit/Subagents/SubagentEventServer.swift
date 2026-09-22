import Foundation
import Network
import OSLog

/// The local HTTP endpoint agent processes POST lifecycle and subagent
/// events to (§5, §6). Loopback-only, ephemeral port. Every response has an
/// empty body — anything returned is liable to be injected into the agent's
/// context.
///
/// Routes (this app's own convention; see the builder's final report for
/// what the Pi-side subagent backend would need to call):
/// - `POST /subagents/{taskId}/{childId}/begin` — body `{"agent","taskLabel","openingLine"?}`
/// - `POST /subagents/{taskId}/{childId}/events` — body one or more `\n`-terminated JSON event lines
/// - `POST /subagents/{taskId}/{childId}/done` — body the `done.json` payload
/// Guards a resume-once flag shared between the listener's state-update
/// closure and the enclosing continuation, since NWListener may deliver
/// state updates from an arbitrary queue.
private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        return true
    }
}

public final class SubagentEventServer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "ai.syv.dash-native", category: "subagent-server")

    private let listener: NWListener
    private let queue = DispatchQueue(label: "ai.syv.dash-native.subagent-server")
    private let store: SubagentFeedStore

    /// Per-child incremental parser, since a child's events may arrive split
    /// across multiple HTTP requests.
    private var lineParsers: [String: SubagentEventLineParser] = [:]

    public private(set) var port: UInt16?

    /// The address to hand to spawned agent processes, once `start()`'s
    /// continuation resolves.
    public var address: String? {
        port.map { "127.0.0.1:\($0)" }
    }

    public init(store: SubagentFeedStore) throws {
        self.store = store
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Starts listening and returns once the port is bound.
    public func start() async throws {
        let resumeBox = ResumeBox()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = self?.listener.port?.rawValue
                    if resumeBox.resume() {
                        continuation.resume()
                    }
                case let .failed(error):
                    if resumeBox.resume() {
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data, !data.isEmpty {
                buffer.append(data)
            }

            if let (request, consumed) = HTTPRequestParser.parse(buffer) {
                buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: consumed))
                self.handle(request, on: connection)
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: buffer)
        }
    }

    private func handle(_ request: ParsedHTTPRequest, on connection: NWConnection) {
        let components = request.path.split(separator: "/").map(String.init)
        defer { respondEmpty(on: connection) }

        guard components.count == 4, components[0] == "subagents",
              let taskId = Int64(components[1])
        else {
            Self.logger.notice("Ignoring request to unrecognised path \(request.path, privacy: .public)")
            return
        }
        let childId = components[2]
        let action = components[3]

        switch action {
        case "begin":
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: request.body),
                  let object = value.objectValue
            else { return }
            let agent = object["agent"]?.stringValue ?? "agent"
            let taskLabel = object["taskLabel"]?.stringValue ?? ""
            let openingLine = object["openingLine"]?.stringValue
            Task { @MainActor [store] in
                store.beginRun(taskId: taskId, childId: childId, agent: agent, taskLabel: taskLabel, openingLine: openingLine)
            }
        case "events":
            let key = "\(taskId):\(childId)"
            var parser = lineParsers[key] ?? SubagentEventLineParser()
            let events = parser.consume(request.body)
            lineParsers[key] = parser
            guard !events.isEmpty else { return }
            Task { @MainActor [store] in
                for event in events {
                    store.ingest(taskId: taskId, childId: childId, event: event)
                }
            }
        case "done":
            guard let payload = SubagentDonePayload.decode(from: request.body) else { return }
            lineParsers.removeValue(forKey: "\(taskId):\(childId)")
            Task { @MainActor [store] in
                store.markDone(taskId: taskId, childId: childId, payload: payload)
            }
        default:
            Self.logger.notice("Ignoring unrecognised action \(action, privacy: .public)")
        }
    }

    private func respondEmpty(on connection: NWConnection) {
        let response = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
