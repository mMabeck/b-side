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
/// - `POST /subagents/{taskId}/{childId}/spawn` — body `{"label","cwd","command"}`;
///   creates a child surface (hidden until swapped in) running `command`
///   (an absolute path to an executable launch script, run directly — not
///   wrapped in a login shell) in `cwd`. `204` once the surface is created;
///   `404` if `taskId` is unknown; `429` if the task is already at
///   `SubagentPaneStore.maxPanesPerTask` (the caller should fall back to
///   headless); `400` for a malformed body.
/// - `POST /subagents/{taskId}/{childId}/close` — empty body; tears down
///   that child's pane. Always `204`, idempotent.
/// - `POST /agent/{taskId}/busy` — empty body; the parent Pi agent loop
///   started working. `204` on success, `404` for an unknown task id.
/// - `POST /agent/{taskId}/idle` — empty body; the parent Pi agent loop
///   ended, with no sound (unlike `alert`). `204`/`404` as above.
/// - `POST /agent/{taskId}/alert` — body
///   `{"kind":"finished"|"question","title":string,"body":string}`; routed
///   into the same path as terminal alerts (sound, native notification,
///   needs-attention for `question`, debounced). `204`/`404` as above;
///   `400` for a malformed body or unrecognised `kind`. Every route may
///   arrive in any order and be repeated.
///
/// `spawn`/`close` hop to the main actor to touch `SubagentPaneStore` (and,
/// for `spawn`, to create a `TerminalSurfaceHost`) before responding, unlike
/// `begin`/`events`/`done`, which respond immediately and mutate `store`
/// asynchronously — the caller needs to know a `spawn` actually produced a
/// surface (or why not) before it decides whether to fall back to headless.

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
    private static let logger = Logger(subsystem: "dev.mabeck.bside", category: "subagent-server")

    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.mabeck.bside.subagent-server")
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

    private let paneStore: SubagentPaneStore
    private let taskExists: @MainActor (Int64) -> Bool
    private let onAgentBusy: @MainActor (Int64) -> Void
    private let onAgentIdle: @MainActor (Int64) -> Void
    private let onAgentAlert: @MainActor (Int64, TaskAlertKind, String, String) -> Void

    public init(
        store: SubagentFeedStore,
        paneStore: SubagentPaneStore,
        taskExists: @escaping @MainActor (Int64) -> Bool,
        onAgentBusy: @escaping @MainActor (Int64) -> Void = { _ in },
        onAgentIdle: @escaping @MainActor (Int64) -> Void = { _ in },
        onAgentAlert: @escaping @MainActor (Int64, TaskAlertKind, String, String) -> Void = { _, _, _, _ in }
    ) throws {
        self.store = store
        self.paneStore = paneStore
        self.taskExists = taskExists
        self.onAgentBusy = onAgentBusy
        self.onAgentIdle = onAgentIdle
        self.onAgentAlert = onAgentAlert
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

        if components.count == 3, components[0] == "agent", let taskId = Int64(components[1]) {
            handleAgentStatus(taskId: taskId, action: components[2], body: request.body, on: connection)
            return
        }

        guard components.count == 4, components[0] == "subagents",
              let taskId = Int64(components[1])
        else {
            Self.logger.notice("Ignoring request to unrecognised path \(request.path, privacy: .public)")
            respond(status: 204, on: connection)
            return
        }
        let childId = components[2]
        let action = components[3]

        switch action {
        case "begin":
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: request.body),
                  let object = value.objectValue
            else {
                respond(status: 204, on: connection)
                return
            }
            let agent = object["agent"]?.stringValue ?? "agent"
            let taskLabel = object["taskLabel"]?.stringValue ?? ""
            let openingLine = object["openingLine"]?.stringValue
            Task { @MainActor [store] in
                store.beginRun(taskId: taskId, childId: childId, agent: agent, taskLabel: taskLabel, openingLine: openingLine)
            }
            respond(status: 204, on: connection)
        case "events":
            let key = "\(taskId):\(childId)"
            var parser = lineParsers[key] ?? SubagentEventLineParser()
            let events = parser.consume(request.body)
            lineParsers[key] = parser
            if !events.isEmpty {
                Task { @MainActor [store] in
                    for event in events {
                        store.ingest(taskId: taskId, childId: childId, event: event)
                    }
                }
            }
            respond(status: 204, on: connection)
        case "done":
            if let payload = SubagentDonePayload.decode(from: request.body) {
                lineParsers.removeValue(forKey: "\(taskId):\(childId)")
                Task { @MainActor [store] in
                    store.markDone(taskId: taskId, childId: childId, payload: payload)
                }
            }
            respond(status: 204, on: connection)
        case "spawn":
            handleSpawn(taskId: taskId, childId: childId, body: request.body, on: connection)
        case "close":
            handleClose(taskId: taskId, childId: childId, on: connection)
        default:
            Self.logger.notice("Ignoring unrecognised action \(action, privacy: .public)")
            respond(status: 204, on: connection)
        }
    }

    /// Decodes `{"label","cwd","command"}`, then hops to the main actor to
    /// check the task exists and ask `SubagentPaneStore` to create the
    /// surface, responding only once that's resolved — the caller needs the
    /// real outcome (in particular `429`, cap reached) before deciding
    /// whether to fall back to headless.
    private func handleSpawn(taskId: Int64, childId: String, body: Data, on connection: NWConnection) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: body),
              let object = value.objectValue,
              let label = object["label"]?.stringValue,
              let cwd = object["cwd"]?.stringValue,
              let command = object["command"]?.stringValue,
              !label.isEmpty, !cwd.isEmpty, !command.isEmpty
        else {
            respond(status: 400, on: connection)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                connection.cancel()
                return
            }
            guard self.taskExists(taskId) else {
                self.respond(status: 404, on: connection)
                return
            }
            let created = self.paneStore.spawn(
                taskId: taskId,
                childId: childId,
                label: label,
                cwd: URL(fileURLWithPath: cwd),
                command: command
            )
            self.respond(status: created ? 204 : 429, on: connection)
        }
    }

    /// Tears down `childId`'s pane, if any. Always `204` — a close for an
    /// already-gone (or never-spawned) pane is not an error.
    private func handleClose(taskId: Int64, childId: String, on connection: NWConnection) {
        Task { @MainActor [weak self] in
            guard let self else {
                connection.cancel()
                return
            }
            self.paneStore.close(taskId: taskId, childId: childId)
            self.respond(status: 204, on: connection)
        }
    }

    /// `busy`/`idle`/`alert` for a task's own parent Pi agent loop, distinct
    /// from the per-child `subagents/...` routes above. `busy`/`idle` just
    /// flip `ProjectsStore.busyTaskIDs`; `alert` decodes its JSON body first
    /// (`400` if that fails or `kind` isn't recognised) before hopping to the
    /// main actor to check the task exists (`404` if not) and dispatch.
    private func handleAgentStatus(taskId: Int64, action: String, body: Data, on connection: NWConnection) {
        switch action {
        case "busy":
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                guard self.taskExists(taskId) else { self.respond(status: 404, on: connection); return }
                self.onAgentBusy(taskId)
                self.respond(status: 204, on: connection)
            }
        case "idle":
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                guard self.taskExists(taskId) else { self.respond(status: 404, on: connection); return }
                self.onAgentIdle(taskId)
                self.respond(status: 204, on: connection)
            }
        case "alert":
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: body),
                  let object = value.objectValue,
                  let kindString = object["kind"]?.stringValue,
                  let kind = Self.alertKind(fromWireValue: kindString),
                  let title = object["title"]?.stringValue,
                  let alertBody = object["body"]?.stringValue
            else {
                respond(status: 400, on: connection)
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                guard self.taskExists(taskId) else { self.respond(status: 404, on: connection); return }
                self.onAgentAlert(taskId, kind, title, alertBody)
                self.respond(status: 204, on: connection)
            }
        default:
            Self.logger.notice("Ignoring unrecognised agent action \(action, privacy: .public)")
            respond(status: 204, on: connection)
        }
    }

    /// Maps the wire contract's `"finished"`/`"question"` strings to
    /// `TaskAlertKind` — `nil` for anything else, which `handleAgentStatus`
    /// turns into a `400`.
    private static func alertKind(fromWireValue value: String) -> TaskAlertKind? {
        switch value {
        case "finished": return .finished
        case "question": return .question
        default: return nil
        }
    }

    private static let statusText: [Int: String] = [
        204: "No Content",
        400: "Bad Request",
        404: "Not Found",
        429: "Too Many Requests",
    ]

    /// Every response keeps an empty body — anything returned is liable to
    /// be injected into the agent's context (see the file doc comment) — so
    /// only the status line varies.
    private func respond(status: Int, on connection: NWConnection) {
        let reason = Self.statusText[status] ?? "Unknown"
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
