// [INPUT]: Native requests and the bundled worker's JSON lines.
// [OUTPUT]: Typed results, complete device snapshots, events and worker errors.
// [POS]: Process and request lifecycle at the native IPC boundary.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import Foundation

actor EngineClient {
    private struct SnapshotRequest {
        let continuation: CheckedContinuation<Data, Error>
        var data = Data()
        var nextIndex = 0
    }

    let events: AsyncStream<EngineEnvelope>
    private let eventSink: AsyncStream<EngineEnvelope>.Continuation
    private var process: Process?
    private var input: FileHandle?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var pendingSnapshots: [String: SnapshotRequest] = [:]
    private var generation = UUID()
    private var lastDiagnostic = ""
    private let helper: URL
    private let directory: URL

    init(helper: URL, directory: URL) {
        self.helper = helper; self.directory = directory
        (events, eventSink) = AsyncStream.makeStream()
    }

    func start() throws {
        if process?.isRunning == true { return }
        let token = UUID(); generation = token; lastDiagnostic = ""
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw EngineError(code: "missingHelper", message: L("error.missing_helper")) }
        let child = Process(); let stdin = Pipe(); let stdout = Pipe(); let stderr = Pipe()
        child.executableURL = helper
        child.arguments = ["--data-dir", directory.path, "worker", "--stdio"]
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        child.terminationHandler = { [weak self] child in Task { await self?.terminated(status: child.terminationStatus, generation: token) } }
        let (chunks, sink) = AsyncStream<Data>.makeStream()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; sink.finish() } else { sink.yield(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { Task { await self?.diagnostic(data, generation: token) } }
        }
        try child.run()
        process = child; input = stdin.fileHandleForWriting; outputPipe = stdout; errorPipe = stderr
        Task { [weak self] in
            var framer = JSONLineFramer()
            do {
                for await chunk in chunks {
                    for line in try framer.append(chunk) { await self?.receive(line, generation: token) }
                }
            } catch { await self?.protocolFailed(error.localizedDescription, generation: token) }
        }
    }

    func request(_ operation: String, payload: JSONValue = .object([:])) async throws -> JSONValue {
        let request = EngineRequest(id: UUID().uuidString, operation: operation, payload: payload)
        return try await withCheckedThrowingContinuation { continuation in
            pending[request.id] = continuation
            do { try send(request) }
            catch { pending.removeValue(forKey: request.id)?.resume(throwing: error) }
        }
    }

    func request<Result: Decodable & Sendable>(_ operation: String, payload: JSONValue = .object([:]), as type: Result.Type) async throws -> Result {
        try await request(operation, payload: payload).decode(type)
    }

    nonisolated func deviceUsageSnapshot() async throws -> DeviceUsageSnapshot {
        let data = try await requestSnapshotData()
        return try JSONDecoder().decode(DeviceUsageSnapshot.self, from: data)
    }

    private func requestSnapshotData() async throws -> Data {
        try Task.checkCancellation()
        let request = EngineRequest(id: UUID().uuidString, operation: "deviceUsageSnapshot", payload: .object(["stream": .bool(true)]))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingSnapshots[request.id] = SnapshotRequest(continuation: continuation)
                do { try send(request) }
                catch { pendingSnapshots.removeValue(forKey: request.id)?.continuation.resume(throwing: error) }
            }
        } onCancel: {
            Task { await self.cancelSnapshot(request.id) }
        }
    }

    private func send(_ request: EngineRequest) throws {
        guard process?.isRunning == true, let input else { throw EngineError(code: "stopped", message: L("error.stopped")) }
        var data = try JSONEncoder().encode(request)
        data.append(10)
        try input.write(contentsOf: data)
        let id = request.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            await self?.expire(id)
        }
    }

    func stop() async {
        guard let child = process else { return }
        try? input?.close(); input = nil
        // EOF is the shutdown contract. Waiting is asynchronous and bounded.
        for _ in 0..<20 {
            if !child.isRunning { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if child.isRunning { child.terminate() }
    }

    func restore(from file: URL) async throws {
        await stop()
        guard process?.isRunning != true else { throw EngineError(code: "busy", message: L("error.busy")) }
        let child = Process(); let stderr = Pipe(); let stdout = Pipe()
        child.executableURL = helper
        child.arguments = ["--data-dir", directory.path, "restore", file.path]
        child.standardOutput = stdout; child.standardError = stderr
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            child.terminationHandler = { process in
                let diagnostic = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.terminationHandler = nil
                if process.terminationStatus == 0 { continuation.resume() }
                else { continuation.resume(throwing: EngineError(code: "restore", message: diagnostic)) }
            }
            do { try child.run() } catch { child.terminationHandler = nil; continuation.resume(throwing: error) }
        }
    }

    private func receive(_ data: Data, generation token: UUID) {
        guard token == generation else { return }
        do {
            let message = try JSONDecoder().decode(EngineEnvelope.self, from: data)
            guard message.version == 1 else { throw EngineError(code: "version", message: L("error.version")) }
            if let id = message.id, pendingSnapshots[id] != nil {
                try receiveSnapshot(message, id: id)
            } else if let id = message.id, let continuation = pending.removeValue(forKey: id) {
                if let error = message.error { continuation.resume(throwing: error) }
                else if let result = message.result { continuation.resume(returning: result) }
                else { continuation.resume(throwing: EngineError(code: "protocol", message: L("error.protocol"))) }
            } else if message.event != nil { eventSink.yield(message) }
        } catch { protocolFailed(error.localizedDescription, generation: token) }
    }

    private func receiveSnapshot(_ message: EngineEnvelope, id: String) throws {
        let malformed = EngineError(code: "protocol", message: L("error.protocol"))
        guard message.event == nil else { throw malformed }
        if let chunk = message.snapshotChunk {
            guard message.result == nil, message.error == nil, pendingSnapshots[id]?.nextIndex == chunk.index,
                  !chunk.json.isEmpty, chunk.json.utf8.count <= 1024 * 1024 else { throw malformed }
            pendingSnapshots[id]?.data.append(contentsOf: chunk.json.utf8)
            pendingSnapshots[id]?.nextIndex += 1
        } else if let error = message.error, message.result == nil {
            pendingSnapshots.removeValue(forKey: id)?.continuation.resume(throwing: error)
        } else {
            guard let transfer = pendingSnapshots[id], transfer.nextIndex > 0, message.error == nil,
                  message.result?["chunks"].int == Int64(transfer.nextIndex) else { throw malformed }
            pendingSnapshots.removeValue(forKey: id)
            transfer.continuation.resume(returning: transfer.data)
        }
    }

    private func diagnostic(_ data: Data, generation token: UUID) {
        guard token == generation else { return }
        lastDiagnostic = String((lastDiagnostic + String(decoding: data, as: UTF8.self)).suffix(3000))
    }
    private func cancelSnapshot(_ id: String) {
        pendingSnapshots.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
    private func expire(_ id: String) {
        let error = EngineError(code: "timeout", message: L("error.timeout"))
        pending.removeValue(forKey: id)?.resume(throwing: error)
        pendingSnapshots.removeValue(forKey: id)?.continuation.resume(throwing: error)
    }
    private func failPending(_ error: EngineError) {
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending.removeAll()
        for request in pendingSnapshots.values { request.continuation.resume(throwing: error) }
        pendingSnapshots.removeAll()
    }
    private func protocolFailed(_ reason: String, generation token: UUID) {
        guard token == generation else { return }
        failPending(EngineError(code: "protocol", message: reason))
        eventSink.yield(EngineEnvelope(version: 1, id: nil, result: nil, error: nil, event: "stopped", payload: nil, message: reason, revision: nil))
        process?.terminate()
    }
    private func terminated(status: Int32, generation token: UUID) {
        guard token == generation else { return }
        input = nil; outputPipe?.fileHandleForReading.readabilityHandler = nil; errorPipe?.fileHandleForReading.readabilityHandler = nil
        let reason = status == 0 ? L("status.stopped") : LF("error.exit", status, lastDiagnostic)
        failPending(EngineError(code: "stopped", message: reason))
        eventSink.yield(EngineEnvelope(version: 1, id: nil, result: nil, error: nil, event: "stopped", payload: nil, message: reason, revision: nil))
    }
}
