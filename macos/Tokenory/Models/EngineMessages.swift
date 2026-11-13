// [INPUT]: 接收 worker 的 JSON 数据流和协议字段。
// [OUTPUT]: 提供类型化消息、报告和增量分行器。
// [POS]: 原生 IPC 的解析边界；已扫描的数据不重复遍历。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import Foundation

enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), integer(Int64), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> JSONValue { if case .object(let v) = self { v[key] ?? .null } else { .null } }
    var string: String? { if case .string(let v) = self { v } else { nil } }
    var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    var int: Int64? { if case .integer(let v) = self { v } else { nil } }
    var double: Double? { switch self { case .number(let v): v; case .integer(let v): Double(v); default: nil } }
    var array: [JSONValue] { if case .array(let v) = self { v } else { [] } }
    static func encode<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value)) }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: JSONEncoder().encode(self)) }
}

struct EngineEnvelope: Decodable, Sendable {
    let version: Int
    let id: String?
    let result: JSONValue?
    let error: EngineError?
    let event: String?
    let payload: JSONValue?
    let message: String?
    let revision: Int64?
}
struct EngineError: Decodable, Error, LocalizedError, Sendable {
    let code: String
    let message: String
    var errorDescription: String? { message }
}
struct EngineRequest: Encodable { let version = 1; let id: String; let operation: String; let payload: JSONValue }
struct UsageFilter: Codable, Sendable, Equatable {
    var from: String?; var to: String?; var client: String?; var provider: String?; var model: String?; var source: String?
    var offset = 0; var limit = 50
}
struct TokenBreakdown: Codable, Sendable { let input: Int64; let output: Int64; let cacheRead: Int64; let cacheWrite: Int64; let reasoning: Int64 }
struct UsageSummary: Decodable, Sendable {
    let tokens: Int64; let tokenBreakdown: TokenBreakdown; let knownEstimatedCostUsd: Double?; let unpricedTokens: Int64
    let costStatus: String; let recordCount: Int64; let activeDays: Int64; let partialDays: Int64?; let requests: Int64?
}
struct UsageGroup: Decodable, Identifiable, Sendable { let key: String; let summary: UsageSummary; var id: String { key } }
struct UsageDetail: Decodable, Identifiable, Sendable {
    let source: String; let batchId: String; let key: String; let client: String; let provider: String; let model: String; let date: String
    let timezone: String?; let sessionId: String?; let timestampMs: Int64?; let tokens: TokenBreakdown; let requests: Int64?
    let sourceCostUsd: Double?; let estimatedCostUsd: Double?; let costBasis: String?; let priceSnapshotId: String?; let metadata: JSONValue
    var id: String { "\(source)|\(batchId)|\(key)" }
    var total: Int64 { tokens.input + tokens.output + tokens.cacheRead + tokens.cacheWrite + tokens.reasoning }
}
struct UsageReport: Decodable, Sendable {
    let revision: Int64; let summary: UsageSummary; let daily: [UsageGroup]; let clients: [UsageGroup]; let providers: [UsageGroup]; let models: [UsageGroup]; let details: [UsageDetail]
    let hourly: HourlyUsage?
}
struct HourlyUsage: Decodable, Sendable { let buckets: [UsageGroup]; let unallocated: UsageSummary }
struct ActivityReport: Decodable, Sendable {
    let revision: Int64
    let from: String
    let to: String
    let daily: [UsageGroup]
    let modelDays: [ModelDay]
    var hourly: HourlyUsage? = nil
}
struct ModelDay: Decodable, Sendable {
    let date: String
    let client: String
    let model: String
    let summary: UsageSummary
}
struct SourceStatus: Decodable, Sendable { let client: String; let status: String; let files: Int; let records: Int; let errors: [String] }
struct ScanResult: Decodable, Sendable { let startedAt: String; let durationMs: Int; let changed: Int; let revision: Int64; let sources: [SourceStatus] }
struct EngineStatus: Decodable, Sendable { let scanning: Bool; let lastScan: ScanResult?; let dataDirectory: String; let revision: Int64; let refreshingPrices: Bool }
struct EngineSettings: Codable, Sendable { var homeDir: String; var intervalSeconds: Int; var timezone: String; var extraScanPaths: [String: [String]] }
struct ImportConflict: Decodable, Identifiable, Sendable { let id: String; let date: String; let client: String; let existingSource: String; let existingTokens: Int64; let incomingTokens: Int64 }
struct ImportPreview: Decodable, Sendable {
    let id: String; let source: String; let contentHash: String; let start: String; let end: String; let rowCount: Int; let dayCount: Int; let tokens: Int64; let unpricedTokens: Int64; let sourceTimezone: String?; let conflicts: [ImportConflict]; let partialDates: [String]
}
struct RepricePreview: Decodable, Sendable { let id: String; let snapshotId: String; let records: Int; let before: Double?; let after: Double?; let unpricedTokens: Int64 }

struct JSONLineFramer: Sendable {
    private var buffer = Data()
    private var scannedBytes = 0
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        guard buffer.count <= 64 * 1024 * 1024 else { throw EngineError(code: "protocol", message: L("error.too_large")) }
        var lines: [Data] = []
        while let end = buffer[buffer.index(buffer.startIndex, offsetBy: scannedBytes)...].firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            scannedBytes = 0
            if !line.isEmpty { lines.append(line) }
        }
        scannedBytes = buffer.count
        return lines
    }
}

struct ClientInfo: Decodable, Identifiable, Sendable { let id: String; let name: String; let supportsExtraPaths: Bool; let collectsAs: [String] }
