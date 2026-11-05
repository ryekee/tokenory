import Foundation

actor EngineClient {
    let events: AsyncStream<EngineEnvelope>
    private let eventSink: AsyncStream<EngineEnvelope>.Continuation
    private var process: Process?
    private var input: FileHandle?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
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
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw EngineError(code: "missingHelper", message: "应用内缺少用量引擎，请重新构建 Tokenory。") }
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
        guard process?.isRunning == true, let input else { throw EngineError(code: "stopped", message: "用量引擎已停止，请重试连接。") }
        let id = UUID().uuidString
        var data = try JSONEncoder().encode(EngineRequest(id: id, operation: operation, payload: payload)); data.append(10)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try input.write(contentsOf: data) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(180))
                await self?.expire(id)
            }
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
        guard process?.isRunning != true else { throw EngineError(code: "busy", message: "引擎尚未停止，请稍后重试。") }
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
            guard message.version == 1 else { throw EngineError(code: "version", message: "应用和用量引擎版本不兼容") }
            if let id = message.id, let continuation = pending.removeValue(forKey: id) {
                if let error = message.error { continuation.resume(throwing: error) }
                else if let result = message.result { continuation.resume(returning: result) }
                else { continuation.resume(throwing: EngineError(code: "protocol", message: "引擎响应缺少结果")) }
            } else if message.event != nil { eventSink.yield(message) }
        } catch { protocolFailed(error.localizedDescription, generation: token) }
    }
    private func diagnostic(_ data: Data, generation token: UUID) {
        guard token == generation else { return }
        lastDiagnostic = String((lastDiagnostic + String(decoding: data, as: UTF8.self)).suffix(3000))
    }
    private func expire(_ id: String) { pending.removeValue(forKey: id)?.resume(throwing: EngineError(code: "timeout", message: "引擎操作超时，请检查采集状态。")) }
    private func protocolFailed(_ reason: String, generation token: UUID) {
        guard token == generation else { return }
        for continuation in pending.values { continuation.resume(throwing: EngineError(code: "protocol", message: reason)) }; pending.removeAll()
        eventSink.yield(EngineEnvelope(version: 1, id: nil, result: nil, error: nil, event: "stopped", payload: nil, message: reason, revision: nil))
        process?.terminate()
    }
    private func terminated(status: Int32, generation token: UUID) {
        guard token == generation else { return }
        input = nil; outputPipe?.fileHandleForReading.readabilityHandler = nil; errorPipe?.fileHandleForReading.readabilityHandler = nil
        let reason = status == 0 ? "用量引擎已停止" : "用量引擎退出（\(status)）\n\(lastDiagnostic)"
        for continuation in pending.values { continuation.resume(throwing: EngineError(code: "stopped", message: reason)) }; pending.removeAll()
        eventSink.yield(EngineEnvelope(version: 1, id: nil, result: nil, error: nil, event: "stopped", payload: nil, message: reason, revision: nil))
    }
}
