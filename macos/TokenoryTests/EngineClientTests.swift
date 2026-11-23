// [INPUT]: 使用 IPC 消息、报告、分行器和 worker 管道。
// [OUTPUT]: 验证碎片消息、完整大目录、分块快照和协议错误。
// [POS]: 原生解析边界的行为测试。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import XCTest
@testable import Tokenory

final class EngineClientTests: XCTestCase {
    func testFramingHandlesSplitUTF8AndSeveralMessages() throws {
        var framer = JSONLineFramer()
        let bytes = Data("{\"label\":\"今日\"}\n{\"value\":12}\n".utf8)
        var lines: [Data] = []
        for byte in bytes { lines += try framer.append(Data([byte])) }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: lines[0])["label"].string, "今日")
    }
    func testLargeCatalogFramesAcrossChunksWithoutLosingFollowingMessages() throws {
        var framer = JSONLineFramer()
        let chunk = Data(repeating: 65, count: 4096)
        for _ in 0..<512 { XCTAssertTrue(try framer.append(chunk).isEmpty) }
        let lines = try framer.append(Data("\nnext\npart".utf8))
        XCTAssertEqual(lines.map(\.count), [2 * 1024 * 1024, 4])
        XCTAssertEqual(try framer.append(Data("ial\n".utf8)), [Data("partial".utf8)])
    }
    func testErrorEnvelopeDoesNotDecodeAsReport() throws {
        let data = Data(#"{"version":1,"id":"bad","error":{"code":"invalidRequest","message":"invalid date"}}"#.utf8)
        let message = try JSONDecoder().decode(EngineEnvelope.self, from: data)
        XCTAssertNil(message.result)
        XCTAssertEqual(message.error?.message, "invalid date")
    }
    func testSnapshotRequestErrorsLeaveWorkerAvailableForCompleteSnapshots() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let helper = directory.appendingPathComponent("worker")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #"""
        #!/bin/sh
        sent_error=false
        while IFS= read -r line; do
            id=${line#*'"id":"'}
            id=${id%%'"'*}
            case "$line" in
                *'"stream":true'*)
                    printf '{"version":1,"id":"%s","snapshotChunk":{"index":0,"json":%s}}\n' "$id" '"{\"schemaVersion\":1,\"revision\":7,"'
                    if [ "$sent_error" = false ]; then
                        printf '{"version":1,"id":"%s","error":{"code":"snapshotTooLarge","message":"Too large"}}\n' "$id"
                        sent_error=true
                    else
                        printf '{"version":1,"id":"%s","snapshotChunk":{"index":1,"json":%s}}\n' "$id" '"\"timezone\":\"Asia/Shanghai\",\"buckets\":[],\"subagentStarts\":[]}"'
                        printf '{"version":1,"id":"%s","result":{"chunks":2}}\n' "$id"
                    fi
                    ;;
                *) printf '{"version":1,"id":"%s","result":{"revision":7}}\n' "$id" ;;
            esac
        done
        """#.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let engine = EngineClient(helper: helper, directory: directory)
        addTeardownBlock {
            await engine.stop()
            try FileManager.default.removeItem(at: directory)
        }
        try await engine.start()
        do {
            _ = try await engine.deviceUsageSnapshot()
            XCTFail("A worker error must fail the snapshot request")
        } catch let error as EngineError {
            XCTAssertEqual(error.code, "snapshotTooLarge")
        }
        let status = try await engine.request("status")
        XCTAssertEqual(status["revision"].int, 7)
        let snapshot = try await engine.deviceUsageSnapshot()
        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.revision, 7)
        XCTAssertEqual(snapshot.timezone, "Asia/Shanghai")
        XCTAssertTrue(snapshot.buckets.isEmpty)
        XCTAssertTrue(snapshot.subagentStarts.isEmpty)
    }
    func testRealProtocolSummaryDecodesInt64AndUnknownCost() throws {
        let data = Data(#"{"revision":1,"summary":{"tokens":8694071481,"tokenBreakdown":{"input":10003733,"output":44047254,"cacheRead":8434857502,"cacheWrite":205162992,"reasoning":0},"knownEstimatedCostUsd":null,"unpricedTokens":8694071481,"costStatus":"unknown","recordCount":165,"activeDays":96,"requests":40573},"daily":[],"clients":[],"providers":[],"models":[],"details":[]}"#.utf8)
        let report = try JSONDecoder().decode(UsageReport.self, from: data)
        XCTAssertEqual(report.summary.tokens, 8_694_071_481)
        XCTAssertNil(report.summary.knownEstimatedCostUsd)
    }
}
