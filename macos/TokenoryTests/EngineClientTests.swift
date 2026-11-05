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
    func testErrorEnvelopeDoesNotDecodeAsReport() throws {
        let data = Data(#"{"version":1,"id":"bad","error":{"code":"invalidRequest","message":"invalid date"}}"#.utf8)
        let message = try JSONDecoder().decode(EngineEnvelope.self, from: data)
        XCTAssertNil(message.result)
        XCTAssertEqual(message.error?.message, "invalid date")
    }
    func testRealProtocolSummaryDecodesInt64AndUnknownCost() throws {
        let data = Data(#"{"revision":1,"summary":{"tokens":8694071481,"tokenBreakdown":{"input":10003733,"output":44047254,"cacheRead":8434857502,"cacheWrite":205162992,"reasoning":0},"knownEstimatedCostUsd":null,"unpricedTokens":8694071481,"costStatus":"unknown","recordCount":165,"activeDays":96,"requests":40573},"daily":[],"clients":[],"providers":[],"models":[],"details":[]}"#.utf8)
        let report = try JSONDecoder().decode(UsageReport.self, from: data)
        XCTAssertEqual(report.summary.tokens, 8_694_071_481)
        XCTAssertNil(report.summary.knownEstimatedCostUsd)
    }
}
